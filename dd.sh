DISK=/dev/nvme0n1

# 1) Make sure nothing is using the disk
swapoff -a
# Close any dm-crypt/LUKS mappings (adjust names if different)
for m in $(ls /dev/mapper 2>/dev/null); do
  cryptsetup status "/dev/mapper/$m" >/dev/null 2>&1 && cryptsetup close "$m" || true
done
# Deactivate LVM if you used it (harmless if none)
vgchange -an || true

# Unmount anything under it (recursively)
for mp in $(findmnt -nr -S "$DISK" -o TARGET); do umount -R "$mp" || true; done
for p in ${DISK}p*; do
  [ -b "$p" ] || continue
  for mp in $(findmnt -nr -S "$p" -o TARGET); do umount -R "$mp" || true; done
done

# 2) Flush udev
udevadm settle || true

# 3) Ask the kernel to re-read the table (try several methods)
blockdev --rereadpt "$DISK" || true
partx -u "$DISK" || true
# NVMe-specific rescan
echo 1 > "/sys/block/$(basename "$DISK")/device/rescan" 2>/dev/null || true
# If nvme-cli is available:
# nvme ns-rescan /dev/nvme0 || true

# 4) Verify the kernel sees the new partitions
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$DISK"
