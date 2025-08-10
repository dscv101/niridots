#!/usr/bin/env bash
# Void Linux automated install with:
# - systemd-boot (UEFI) instead of GRUB
# - LUKS2 full-disk encryption (ESP unencrypted as required)
# - Btrfs with persistence-friendly subvolumes
# - 64GB swapfile on Btrfs (NOCOW-safe)
# - Optional: build & install the latest XanMod kernel from source
# - NVIDIA GTX 970 (Maxwell) setup with DRM KMS and DKMS support
#
# Target hardware (as provided):
#   CPU: AMD Ryzen 7 5800X
#   NVMe: Seagate FireCuda 1TB (generic NVMe assumptions)
#   GPU: NVIDIA GTX 970
#
# Usage:
#   1) Boot the Void Linux live ISO (UEFI mode) with network access.
#   2) Save this script and run as root:  bash void-xanmod-install.sh
#   3) Review variables below and confirm when prompted.
#
# Notes:
#   - This script is opinionated but safe; it will prompt before destructive steps.
#   - Building XanMod from source takes time and CPU; you can skip it if desired.
#   - systemd-boot requires UEFI; this script will abort on legacy BIOS.
#   - The ESP (/boot) remains unencrypted by design (required for systemd-boot).
#   - TRIM is enabled via Btrfs 'discard=async' and LUKS 'discard' in /etc/crypttab.
#   - If something fails, rerun with DEBUG=1 for bash tracing: DEBUG=1 bash void-xanmod-install.sh
#
set -Eeuo pipefail
# Debug tracing with line numbers when DEBUG=1
PS4='+ [${LINENO}] '
if [ "${DEBUG:-0}" != "0" ]; then set -x; fi
ulimit -c unlimited || true
trap 'echo "ERROR on line $LINENO: $BASH_COMMAND"; (dmesg | tail -n 50) 2>/dev/null || true' ERR

### ────────────────────────────── User Variables ──────────────────────────────
: "${DISK:=/dev/nvme0n1}"          # Target disk (DESTROYED!)
: "${ESP_SIZE:=1GiB}"              # EFI System Partition size
: "${HOSTNAME:=blazar}"
: "${USERNAME:=dscv}"
: "${REALNAME:=Derek Vitrano}"
: "${TIMEZONE:=America/Chicago}"
: "${LOCALE:=en_US.UTF-8}"
: "${KEYMAP:=us}"
: "${SWAP_SIZE:=64G}"              # Swapfile size (e.g., 64G)
: "${MIRROR:=https://mirrors.servercentral.com/voidlinux/current}"        # Main repo
: "${MIRROR_NONFREE:=https://mirrors.servercentral.com/voidlinux/current/nonfree}"

# LUKS parameters (balanced for performance & security on Ryzen 7 5800X)
: "${LUKS_PASSPHRASE:=}"           # If empty, you'll be prompted
: "${LUKS_CIPHER:=aes-xts-plain64}"
: "${LUKS_KEY_SIZE:=512}"          # 2x256-bit for XTS
: "${LUKS_HASH:=sha512}"
: "${LUKS_PBKDF:=argon2id}"
: "${LUKS_PBKDF_MEM:=1048576}"     # 1 GiB (KiB units)
: "${LUKS_PBKDF_PARALLEL:=4}"
: "${LUKS_ITER_TIME:=3000}"        # ~3 seconds

# Build the latest XanMod kernel from source? (true/false). Accept 0/false to disable.
: "${BUILD_XANMOD:=true}"; if [ "${BUILD_XANMOD}" = "0" ] || [ "${BUILD_XANMOD}" = "false" ]; then BUILD_XANMOD=false; fi

# Install NVIDIA DKMS driver package (preferred) or fallback to binary?
: "${INSTALL_NVIDIA_DKMS:=true}"

### ────────────────────────────── Helpers ─────────────────────────────────────
log() { printf "\n\033[1;34m[STEP]\033[0m %s\n" "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1"; exit 1; }; }

# Safer partition table re-read (no hard dependency on partprobe)
rereadpt() {
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$DISK" || true
  elif command -v blockdev >/dev/null 2>&1; then
    blockdev --rereadpt "$DISK" || true
  elif command -v partx >/dev/null 2>&1; then
    partx -u "$DISK" || true
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle || true
  fi
}

# Prepare chroot (bind /dev, /proc, /sys, /run and mount efivars)
prepare_chroot() {
  for d in dev proc sys run; do
    mkdir -p /mnt/$d
    mountpoint -q /mnt/$d || mount --rbind /$d /mnt/$d
    mount --make-rslave /mnt/$d || true
  done
  # Ensure efivars is available inside chroot for bootctl/efibootmgr
  mkdir -p /mnt/sys/firmware/efi/efivars
  if ! mountpoint -q /mnt/sys/firmware/efi/efivars; then
    mount -t efivarfs efivarfs /mnt/sys/firmware/efi/efivars 2>/dev/null || true
  fi
}

### ────────────────────────────── Sanity checks ───────────────────────────────
for bin in sgdisk cryptsetup mkfs.vfat btrfs xbps-install chroot dracut blkid lsblk efibootmgr chattr dd; do
  require "$bin"
done

if [ ! -d /sys/firmware/efi/efivars ]; then
  echo "ERROR: Not booted in UEFI mode. systemd-boot requires UEFI."
  exit 1
fi

if [ ! -b "$DISK" ]; then
  echo "ERROR: Disk $DISK not found."
  lsblk
  exit 1
fi

echo ">>> Target disk: $DISK"
echo ">>> This WILL ERASE all data on $DISK."
read -rp "Type 'YES' to continue: " CONFIRM
[ "${CONFIRM:-}" = "YES" ] || { echo "Aborted."; exit 1; }

### ───────────────────────────── Partition the disk ───────────────────────────
log "Wiping partition table on $DISK"
sgdisk --zap-all "$DISK"

log "Creating GPT + LUKS partitions"
# Note: If you ever see \"failed to get device path for 259:2\", it usually means the kernel hasn't created the p2 node yet; the wait above handles it.
sgdisk -n1:0:+"$ESP_SIZE" -t1:ef00 -c1:"EFI System Partition" "$DISK"
sgdisk -n2:0:0              -t2:8309 -c2:"cryptroot" "$DISK"  # 8309 = Linux LUKS

rereadpt


# Compute correct partition device names across {sdX, nvmeXnY, mmcblkZ}
case "$DISK" in
  *nvme*|*mmcblk*|*loop*) P="p" ;;
  *)                      P=""  ;;
esac
ESP="${DISK}${P}1"
LUKS_DEV="${DISK}${P}2"

# Wait for partition device nodes to appear
wait_for_part_nodes() {
  for _ in $(seq 1 50); do
    if [ -b "$ESP" ] && [ -b "$LUKS_DEV" ]; then
      return 0
    fi
    sleep 0.2
  done
  # One last settle before failing
  command -v udevadm >/dev/null 2>&1 && udevadm settle || true
  lsblk -o NAME,PATH,MAJ:MIN,SIZE,TYPE || true
  echo "ERROR: Partition device nodes not found for $DISK ($ESP / $LUKS_DEV)"
  exit 1
}
wait_for_part_nodes

lsblk -o NAME,PATH,MAJ:MIN,SIZE,TYPE
echo "==> Formatting ESP ($ESP)"
mkfs.vfat -F32 -n EFI "$ESP"

### ───────────────────────────── LUKS2 encryption ────────────────────────────
if [ -z "$LUKS_PASSPHRASE" ]; then
  echo "Enter LUKS passphrase (will not echo):"
  read -rs LUKS_PASSPHRASE
  echo
fi

log "Setting up LUKS2 on $LUKS_DEV"
echo -n "$LUKS_PASSPHRASE" | cryptsetup luksFormat \
  --type luks2 \
  --cipher "$LUKS_CIPHER" \
  --key-size "$LUKS_KEY_SIZE" \
  --hash "$LUKS_HASH" \
  --pbkdf "$LUKS_PBKDF" \
  --pbkdf-memory "$LUKS_PBKDF_MEM" \
  --pbkdf-parallel "$LUKS_PBKDF_PARALLEL" \
  --iter-time "$LUKS_ITER_TIME" \
  "$LUKS_DEV" -

echo -n "$LUKS_PASSPHRASE" | cryptsetup open --allow-discards "$LUKS_DEV" cryptroot -

CRYPTROOT="/dev/mapper/cryptroot"

### ─────────────────────────────── Btrfs setup ───────────────────────────────
log "Creating Btrfs filesystem on $CRYPTROOT"
mkfs.btrfs -L VOIDROOT "$CRYPTROOT"

echo "==> Creating subvolumes"
mount "$CRYPTROOT" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@var
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@var_cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@swap
btrfs subvolume create /mnt/@snapshots
umount /mnt

BTRFS_OPTS="noatime,compress=zstd:3,space_cache=v2,discard=async,ssd"

echo "==> Mounting subvolumes"
mount -o "${BTRFS_OPTS},subvol=@" "$CRYPTROOT" /mnt
mkdir -p /mnt/{boot,home,var,swap,tmp,.snapshots}
mount -o "${BTRFS_OPTS},subvol=@home" "$CRYPTROOT" /mnt/home
mount -o "${BTRFS_OPTS},subvol=@var"  "$CRYPTROOT" /mnt/var
# create child mount points inside /var before mounting them
mkdir -p /mnt/var/log /mnt/var/cache
mount -o "${BTRFS_OPTS},subvol=@var_log" "$CRYPTROOT" /mnt/var/log
mount -o "${BTRFS_OPTS},subvol=@var_cache" "$CRYPTROOT" /mnt/var/cache
mount -o "${BTRFS_OPTS},subvol=@tmp"  "$CRYPTROOT" /mnt/tmp
mount -o "${BTRFS_OPTS},subvol=@snapshots" "$CRYPTROOT" /mnt/.snapshots

echo "==> Mounting ESP to /mnt/boot"
mount "$ESP" /mnt/boot
# Sanity: show mount type
findmnt -no SOURCE,FSTYPE,TARGET /mnt/boot || true

### ─────────────────────────────── Swapfile (64G) ────────────────────────────
echo "==> Creating NOCOW Btrfs swapfile at /mnt/swap/swapfile (${SWAP_SIZE})"
mkdir -p /mnt/swap
# Disable COW on the directory so the file inherits NOCOW (must be BEFORE creation)
chattr +C /mnt/swap
# Ensure no compression is applied
(btrfs property set -ts d /mnt/swap compression none >/dev/null 2>&1 || true)
# Preallocate a contiguous file (dd is safest for Btrfs swapfile)
SWAP_GB=${SWAP_SIZE%G}
dd if=/dev/zero of=/mnt/swap/swapfile bs=1M count=$(( SWAP_GB * 1024 )) status=progress
chmod 600 /mnt/swap/swapfile
mkswap /mnt/swap/swapfile
# Best-effort: ensure compression property on the file as well (older btrfs-progs may lack it)
(btrfs property set -ts f /mnt/swap/swapfile compression none >/dev/null 2>&1 || true)
# Do not swapon in the live env; the target system will handle it on boot.

### ───────────────────────────── Base system install ─────────────────────────
log "Installing base system to /mnt"
xbps-install -Sy -y -y -R "$MIRROR" -r /mnt \
  base-system btrfs-progs cryptsetup dracut dkms \
  curl wget git gcc make pkg-config ncurses-libs ncurses-devel \
  linux-firmware linux-firmware-amd \
  efibootmgr dosfstools nano vim sudo glibc-locales

# Optional NVIDIA userspace + DKMS (module gets built after kernel is ready)
if $INSTALL_NVIDIA_DKMS; then
  xbps-install -Sy -y -y -R "$MIRROR_NONFREE" -r /mnt -y nvidia-dkms || true
  xbps-install -Sy -y -y -R "$MIRROR_NONFREE" -r /mnt -y nvidia-libs-32bit || true
else
  xbps-install -Sy -y -y -R "$MIRROR_NONFREE" -r /mnt -y nvidia || true
  xbps-install -Sy -y -y -R "$MIRROR_NONFREE" -r /mnt -y nvidia-libs-32bit || true
fi

### ───────────────────────────── System configuration ────────────────────────
echo "==> Generating fstab and basic config"
if ! mountpoint -q /mnt; then
  echo "ERROR: /mnt is not mounted; earlier mount step failed." >&2
  exit 1
fi

LUKS_UUID=$(blkid -s UUID -o value "$LUKS_DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP")

cat > /mnt/etc/fstab <<EOF
# <file system>                              <mount point>  <type>  <options>                                        <dump> <pass>
UUID=$ESP_UUID                                /boot          vfat    umask=0077,shortname=winnt                      0      2
/dev/mapper/cryptroot                         /              btrfs   ${BTRFS_OPTS},subvol=@                          0      0
/dev/mapper/cryptroot                         /home          btrfs   ${BTRFS_OPTS},subvol=@home                      0      0
/dev/mapper/cryptroot                         /var           btrfs   ${BTRFS_OPTS},subvol=@var                       0      0
/dev/mapper/cryptroot                         /var/log       btrfs   ${BTRFS_OPTS},subvol=@var_log                   0      0
/dev/mapper/cryptroot                         /var/cache     btrfs   ${BTRFS_OPTS},subvol=@var_cache                 0      0
/dev/mapper/cryptroot                         /tmp           btrfs   ${BTRFS_OPTS},subvol=@tmp                       0      0
/dev/mapper/cryptroot                         /.snapshots    btrfs   ${BTRFS_OPTS},subvol=@snapshots                 0      0
/swap/swapfile                                none           swap    defaults                                        0      0
EOF

# Persist crypt setup (enables TRIM)
cat > /mnt/etc/crypttab <<EOF
cryptroot UUID=$LUKS_UUID none luks,discard
EOF

# Hostname, locale, timezone
echo "$HOSTNAME" > /mnt/etc/hostname
echo "LANG=$LOCALE" > /mnt/etc/locale.conf
echo "KEYMAP=$KEYMAP" > /mnt/etc/vconsole.conf
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /mnt/etc/localtime

# /etc/hosts
cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
EOF

# Generate locale on Void (glibc-locales)
echo "$LOCALE UTF-8" > /mnt/etc/default/libc-locales
chroot /mnt xbps-reconfigure -f glibc-locales

# Minimal resolv.conf
echo "nameserver 1.1.1.1" > /mnt/etc/resolv.conf

# Dracut config: include microcode early and needed modules
mkdir -p /mnt/etc/dracut.conf.d
cat > /mnt/etc/dracut.conf.d/10-crypto-btrfs.conf <<'EOF'
hostonly="yes"
use_fstab="yes"
add_dracutmodules+=" crypt btrfs "
compress="zstd"
early_microcode="yes"
EOF

# NVIDIA KMS for Wayland & smooth console
mkdir -p /mnt/etc/modprobe.d
# Blacklist nouveau to prevent conflicts
cat > /mnt/etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
cat > /mnt/etc/modprobe.d/nvidia-drm.conf <<'EOF'
options nvidia-drm modeset=1
EOF

### ───────────────────────────── systemd-boot setup ──────────────────────────
log "Installing systemd-boot to ESP"
# On Void, systemd-boot tooling is provided by the 'systemd-boot' package.
prepare_chroot
if ! chroot /mnt sh -c 'command -v bootctl >/dev/null 2>&1'; then
  xbps-install -Sy -y -y -R "$MIRROR" -r /mnt systemd-boot || {
    echo "ERROR: 'systemd-boot' package not found in repos. Aborting."
    exit 1
  }
fi
chroot /mnt bootctl --esp-path=/boot install --no-variables || true
# Fallback bootloader path in case NVRAM updates are blocked
mkdir -p /mnt/boot/EFI/Boot
if [ -f /mnt/usr/lib/systemd/boot/efi/systemd-bootx64.efi ]; then
  cp -f /mnt/usr/lib/systemd/boot/efi/systemd-bootx64.efi /mnt/boot/EFI/Boot/BOOTX64.EFI
fi
mkdir -p /mnt/boot/loader/entries
# loader.conf will be written after kernel decision

### ─────────────────────── Root & user accounts (in chroot) ──────────────────
echo "==> Setting root password and creating user '$USERNAME'"
prepare_chroot
chroot /mnt /bin/sh -c "
  echo 'Set root password:'
  passwd
  useradd -m -G wheel,video,audio,storage,input -s /bin/bash -c '${REALNAME}' ${USERNAME}
  echo 'Set password for ${USERNAME}:'
  passwd ${USERNAME}
"
# Enable sudo for wheel
if [ -f /mnt/etc/sudoers ]; then
  sed -i 's/^# \(%wheel ALL=(ALL:ALL) ALL\)$/\1/' /mnt/etc/sudoers || true
fi

### ─────────────────────── Build & install XanMod kernel ─────────────────────
KERNEL_ENTRY_TITLE="Void Linux (XanMod)"
ENTRY_FILE="void-xanmod.conf"
KERNEL_IMAGE_NAME="vmlinuz-linux-xanmod"
INITRAMFS_NAME="initramfs-linux-xanmod.img"

if $BUILD_XANMOD; then
  log "Building latest XanMod kernel (can take a while)"
  chroot /mnt /bin/sh -e -c "
    # Ensure toolchain and headers are present
    xbps-install -Syu -y -R $MIRROR base-devel linux-headers || exit 20
    command -v make >/dev/null 2>&1 || exit 21
    command -v gcc >/dev/null 2>&1 || exit 22

set -e
    # Ensure make is present
    command -v make >/dev/null 2>&1 || xbps-install -Sy -y -R $MIRROR make gcc
    command -v git >/dev/null 2>&1 || xbps-install -Sy -y -R $MIRROR git

xbps-install -Sy -y -y -R $MIRROR git gcc make bc flex bison openssl-devel libelf-devel elfutils-devel \
  zstd kmod cpio perl findutils util-linux ncurses-devel dwarves file patch diffutils python3 rsync tar xz unzip which gawk sed grep coreutils binutils bzip2 \
  linux-headers binutils
cd /usr/src
if [ ! -d linux-xanmod ]; then
  git clone --depth=1 https://github.com/xanmod/linux.git linux-xanmod
else
  cd linux-xanmod
  git fetch --depth=1 origin
  git reset --hard origin/HEAD
fi
cd /usr/src/linux-xanmod
make olddefconfig
# Build with log so we can inspect if it fails
if ! make -j$(nproc) 2>&1 | tee /root/xanmod-build.log; then
  echo "XANMOD_BUILD_FAILED" > /root/.xanmod_failed
  exit 66
fi
make modules_install || { echo "ERROR: make modules_install failed"; exit 68; }
depmod -a $(make kernelrelease)
cp -v arch/x86/boot/bzImage /boot/$KERNEL_IMAGE_NAME
cp -v System.map /boot/System.map-xanmod
KVER=$(make kernelrelease)
ln -sfn /usr/src/linux-xanmod /lib/modules/$KVER/build
echo "Using kernel release: $KVER"; dracut -f /boot/$INITRAMFS_NAME $KVER
  " || BUILD_XANMOD=false
fi

if ! $BUILD_XANMOD; then
  echo "==> Skipping XanMod build; using stock Void kernel"
  ENTRY_FILE="void.conf"
  KERNEL_ENTRY_TITLE="Void Linux"
  xbps-install -Sy -y -y -R "$MIRROR" -r /mnt linux linux-headers
  chroot /mnt sh -c '
    set -e
    KVER=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
    if [ -z "$KVER" ]; then
      echo "ERROR: No kernel modules found under /lib/modules; linux package may not have installed." >&2
      exit 65
    fi
    dracut -f /boot/initramfs-void.img "$KVER"
  '
  KERNEL_IMAGE_NAME="$(basename "$(chroot /mnt sh -c 'ls /boot/vmlinuz-* | sort -V | tail -n1')" )"
  INITRAMFS_NAME="$(basename "$(chroot /mnt sh -c 'ls /boot/initramfs-* | sort -V | tail -n1')" )"
fi
  echo "==> Skipping XanMod build; using stock Void kernel"
  ENTRY_FILE="void.conf"
  KERNEL_ENTRY_TITLE="Void Linux"
  xbps-install -Sy -y -y -R "$MIRROR" -r /mnt linux linux-headers
  chroot /mnt sh -c '
    set -e
    KVER=$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -n1 || true)
    if [ -z "$KVER" ]; then
      echo "ERROR: No kernel modules found under /lib/modules; linux package may not have installed." >&2
      exit 65
    fi
    dracut -f /boot/initramfs-void.img "$KVER"
  '
  KERNEL_IMAGE_NAME="$(basename "$(chroot /mnt sh -c 'ls /boot/vmlinuz-* | sort -V | tail -n1')" )"
  INITRAMFS_NAME="$(basename "$(chroot /mnt sh -c 'ls /boot/initramfs-* | sort -V | tail -n1')" )"
fi

### ───────────────────────── Boot entry with LUKS/Btrfs ──────────────────────
log "Creating systemd-boot entry"
# Detect AMD microcode image if present (name varies by distro)
EXTRA_INITRD_LINE=""
if [ -f /mnt/boot/amd-ucode.img ]; then
  EXTRA_INITRD_LINE="initrd  \\amd-ucode.img"
elif [ -f /mnt/boot/amd-ucode.cpio ]; then
  EXTRA_INITRD_LINE="initrd  \\amd-ucode.cpio"
fi

cat > /mnt/boot/loader/entries/${ENTRY_FILE} <<EOF
title   $KERNEL_ENTRY_TITLE
linux   \\$KERNEL_IMAGE_NAME
$EXTRA_INITRD_LINE
initrd  \\$INITRAMFS_NAME
options rd.luks.name=$LUKS_UUID=cryptroot rd.luks.options=$LUKS_UUID=discard root=/dev/mapper/cryptroot rootflags=subvol=@,compress=zstd:3 rw nvidia-drm.modeset=1 amd_pstate=active
EOF

# Write loader.conf with the chosen default entry
cat > /mnt/boot/loader/loader.conf <<EOF
timeout 3
console-mode max
default ${ENTRY_FILE}
EOF

### ───────────────────────────── NVIDIA driver build ─────────────────────────
# Build DKMS against the installed kernel (XanMod or stock). Capture logs.
if $INSTALL_NVIDIA_DKMS; then
  echo "==> Building NVIDIA DKMS module"
  chroot /mnt /bin/sh -e -c '
    export IGNORE_CC_MISMATCH=1
    if ! command -v dkms >/dev/null 2>&1; then
      xbps-install -Syu -y -R '"$MIRROR"' dkms || exit 70
    fi
    # Determine kernel release
    KVER=$(ls -1 /lib/modules | sort -V | tail -n1)
    [ -n "$KVER" ] || { echo "No /lib/modules entries found"; exit 71; }
    # Find NVIDIA driver version from /usr/src
    DRVDIR=$(ls -d /usr/src/nvidia-* 2>/dev/null | head -n1 || true)
    [ -n "$DRVDIR" ] || { echo "NVIDIA dkms sources not found under /usr/src"; exit 72; }
    DRVVER=$(basename "$DRVDIR" | cut -d- -f2-)
    echo "DKMS building nvidia/$DRVVER for kernel $KVER"
    # Ensure kernel build/source symlinks exist (stock kernel should provide build dir)
    [ -e "/lib/modules/$KVER/build" ] || ln -sfn "/usr/src/linux-xanmod" "/lib/modules/$KVER/build" || true
    [ -e "/lib/modules/$KVER/source" ] || ln -sfn "/usr/src/linux-xanmod" "/lib/modules/$KVER/source" || true
    dkms remove -m nvidia -v "$DRVVER" -k "$KVER" --all >/dev/null 2>&1 || true
    if ! dkms install -m nvidia -v "$DRVVER" -k "$KVER" 2>&1 | tee "/root/dkms-nvidia-$KVER.log"; then
      echo "DKMS_INSTALL_FAILED" > /root/.nvidia_dkms_failed
      LOGDIR="/var/lib/dkms/nvidia/$DRVVER/$KVER/$(uname -m)/log"
      echo ">> Inspect DKMS log if present: $LOGDIR/make.log"
      exit 73
    fi
    echo "NVIDIA DKMS installed for $KVER"
    # Rebuild initramfs to include nvidia modules if needed
    dracut -f "/boot/$INITRAMFS_NAME" "$KVER"
  ' || true
fi

### ──────────────────────────── Performance tweaks
### ──────────────────────────── Performance tweaks ────────────────────────────
# Basic sysctl tuning for desktop + NVMe
cat > /mnt/etc/sysctl.d/99-tuning.conf <<'EOF'
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
kernel.nmi_watchdog = 0
EOF

# Ensure NVMe scheduler is 'none' (default on modern kernels)
mkdir -p /mnt/etc/udev/rules.d
cat > /mnt/etc/udev/rules.d/60-nvme-iosched.rules <<'EOF'
ACTION=="add|change", KERNEL=="nvme[0-9]n[0-9]", ATTR{queue/scheduler}="none"
EOF

### ───────────────────────────── Final touches ────────────────────────────────
log "Enabling basic services (runit)"
# Network (NetworkManager optional; use dhcpcd if preferred)
xbps-install -Sy -y -y -R "$MIRROR" -r /mnt NetworkManager dbus chrony elogind || true
ln -sf /etc/sv/NetworkManager /mnt/var/service/ || true
ln -sf /etc/sv/dbus /mnt/var/service/ || true
ln -sf /etc/sv/chronyd /mnt/var/service/ || true
ln -sf /etc/sv/elogind /mnt/var/service/ || true
# Set hardware clock
chroot /mnt hwclock --systohc || true

# Finalize system configuration
chroot /mnt xbps-reconfigure -fa || true

echo "==> Installation complete."
echo "    You can now exit the live environment and reboot."
echo "    On first boot, systemd-boot should present the '$KERNEL_ENTRY_TITLE' entry."
echo "    Root filesystem is LUKS2-encrypted with Btrfs subvolumes; swapfile at /swap/swapfile (${SWAP_SIZE})."
