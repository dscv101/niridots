#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Void (glibc) — Rocket Theme Desktop v1.1
# Niri • Ghostty • Waybar • swww • mako • wofi • zsh/oh-my-zsh • starship
# GTK: adw-gtk3 + Papirus icons + Bibata-Modern-Amber cursor
# Extras: lxqt-policykit (polkit agent), JetBrains Mono (optional)
# OKLCH-inspired palette applied across components
# Usage: sudo bash install_rocket_theme.sh [/absolute/path/wallpaper.png]
# ─────────────────────────────────────────────────────────────────────────────

TARGET_USER="${SUDO_USER:-${USER}}"
if [[ "$TARGET_USER" == "root" ]]; then
  echo "Refusing to install user configs for root. Run via: sudo bash $0"; exit 1
fi
HOME_DIR="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d "$HOME_DIR" ]] || { echo "Could not resolve home for $TARGET_USER"; exit 1; }

WALLPAPER_SRC="${1:-}"
WALLPAPER_DIR="$HOME_DIR/Pictures/wallpapers"
WALLPAPER_DEST="$WALLPAPER_DIR/rocket-theme.png"

# OKLCH-inspired palette (hex for apps)
BASE_BG="#A6A584"     # L≈0.85  calm sage
PRIMARY_FG="#2E4B4B"  # text
ACCENT1="#E9C17B"     # highlight
ACCENT2="#C87C5C"     # active/warn
NEUTRAL="#E8E3D1"     # surface
HILITE="#5E7E7E"      # hover/focus

echo "→ Target user: $TARGET_USER   Home: $HOME_DIR"
echo "→ Wallpaper: ${WALLPAPER_SRC:-'(none provided)'}"

# ── Sanity ───────────────────────────────────────────────────────────────────
command -v xbps-install >/dev/null 2>&1 || { echo "This script is for Void Linux."; exit 1; }

# ── Packages ─────────────────────────────────────────────────────────────────
echo "→ Installing packages (minimal, modern)…"
xbps-install -Syu -y
# Core stack (fail if these fail)
xbps-install -y \
  git curl gcc make pkgconf \
  python3 python3-devel libffi-devel openssl-devel sqlite-devel zlib-devel \
  niri ghostty waybar swww mako wofi wl-clipboard \
  xdg-desktop-portal xdg-desktop-portal-wlr \
  seatd greetd tuigreet \
  pipewire wireplumber pipewire-alsa pipewire-pulse \
  zsh starship zsh-autosuggestions zsh-syntax-highlighting \
  noto-fonts-ttf fastfetch ripgrep fd \
  dconf gtk4 gtk-engine-murrine lxqt-policykit

# Optional (don’t fail if missing on your mirror)
xbps-install -y adw-gtk3 papirus-icon-theme bibata-cursor-theme font-jetbrains-mono || true

# ── GPU drivers ──────────────────────────────────────────────────────────────
GPU_LINE="$(lspci | grep -iE 'vga|3d|display' || true)"
if echo "$GPU_LINE" | grep -qi nvidia; then
  echo "→ NVIDIA detected: installing proprietary driver and enabling DRM KMS"
  xbps-install -y nvidia nvidia-libs || true
  echo 'options nvidia_drm modeset=1' >/etc/modprobe.d/nvidia-kms.conf || true
  # Rebuild initramfs so KMS is available early
  xbps-reconfigure -fa || true
elif echo "$GPU_LINE" | grep -qi amd; then
  echo "→ AMD detected: installing Mesa stack"
  xbps-install -y mesa mesa-dri vulkan-loader || true
else
  echo "→ Intel/Other detected: installing Mesa stack"
  xbps-install -y mesa mesa-dri vulkan-loader || true
fi

# ── Services ─────────────────────────────────────────────────────────────────
echo "→ Enabling seatd and greetd…"
ln -sf /etc/sv/seatd  /var/service/seatd
ln -sf /etc/sv/greetd /var/service/greetd

# ── greetd → Niri session (with DBus) ────────────────────────────────────────
echo "→ Configuring greetd → Niri (via dbus-run-session)…"
install -Dm644 /dev/stdin /etc/greetd/config.toml <<'EOF'
[terminal]
vt = 1

[default_session]
# Ensure a user DBus (required for portals, mako, wireplumber, etc.)
command = "tuigreet --time --remember --cmd 'dbus-run-session -- niri-session'"
user = "_greetd"
EOF

install -Dm755 /dev/stdin /usr/local/bin/niri-session <<'EOF'
#!/bin/sh
exec niri
EOF

# ── User dirs ────────────────────────────────────────────────────────────────
mkdir -p "$HOME_DIR"/.config/{niri,waybar,mako,wofi} "$HOME_DIR"/.config \
         "$HOME_DIR/.icons/default" "$WALLPAPER_DIR" "$HOME_DIR/Pictures/Screenshots"

# ── Wallpaper ────────────────────────────────────────────────────────────────
if [[ -n "${WALLPAPER_SRC}" && -f "${WALLPAPER_SRC}" ]]; then
  echo "→ Copying wallpaper to $WALLPAPER_DEST"
  cp -f -- "${WALLPAPER_SRC}" "${WALLPAPER_DEST}"
else
  echo "→ No wallpaper provided. Place your image at: $WALLPAPER_DEST"
fi

# ── Niri ─────────────────────────────────────────────────────────────────────
echo "→ Writing Niri config…"
install -Dm644 /dev/stdin "$HOME_DIR/.config/niri/config.kdl" <<EOF
// Rocket Theme — Niri (Void + runit, NVIDIA-friendly)
// Screenshot target for built-in UI:
screenshot-path "$HOME_DIR/Pictures/Screenshots/Screenshot %Y-%m-%d %H-%M-%S.png"

// Cursor cohesive with GTK
cursor {
  xcursor-theme "Bibata-Modern-Amber"
  xcursor-size 24
  hide-when-typing
}

// Wayland + portals + NVIDIA hints; also make portals pick the right backend
environment {
  XDG_CURRENT_DESKTOP "niri"
  XDG_SESSION_DESKTOP "niri"
  GDK_BACKEND "wayland,x11"
  QT_QPA_PLATFORM "wayland;xcb"
  SDL_VIDEODRIVER "wayland"
  MOZ_ENABLE_WAYLAND "1"
  ELECTRON_OZONE_PLATFORM_HINT "auto"

  __GLX_VENDOR_LIBRARY_NAME "nvidia"
  GBM_BACKEND "nvidia-drm"
  WLR_NO_HARDWARE_CURSORS "1"
}

// Autostart (Void has no user systemd: start user daemons here)
spawn-at-startup "pipewire"
spawn-at-startup "wireplumber"
spawn-at-startup "pipewire-pulse"

spawn-at-startup "mako"
spawn-at-startup "lxqt-policykit-agent"

spawn-at-startup "sh" "-c" "swww-daemon --status >/dev/null 2>&1 || swww init"
spawn-at-startup "sh" "-c" "test -f '$WALLPAPER_DEST' && swww img '$WALLPAPER_DEST' --transition-type any --transition-duration 1"

spawn-at-startup "waybar"

// Launchers & binds
binds {
  mod = "SUPER"
  "Return" => spawn "sh" "-c" "command -v ghostty >/dev/null && ghostty || command -v footclient >/dev/null && footclient || command -v foot >/dev/null && foot || xterm"
  "D" => spawn "wofi" "--show" "drun"

  // Screenshots (niri UI)
  "Print" => screenshot
  "Ctrl+Print" => screenshot-screen
  "Alt+Print" => screenshot-window

  // Basics
  "Q" => close-window
  "Shift+F" => fullscreen-window
  "V" => toggle-window-floating

  "H" => focus-column-left
  "L" => focus-column-right
  "J" => focus-window-down
  "K" => focus-window-up

  "U" => focus-workspace-down
  "I" => focus-workspace-up

  "Ctrl+H" => move-column-left
  "Ctrl+L" => move-column-right
  "Ctrl+U" => move-column-to-workspace-down
  "Ctrl+I" => move-column-to-workspace-up

  "Shift+E" => quit
}

background { color 0x${BASE_BG#\#} }

// Layers: Waybar polish
layer-rule {
  match namespace="waybar"
  opacity 0.96
  shadow { on softness 24 spread 6 offset x=0 y=4 color "#00000060" draw-behind-window true }
  geometry-corner-radius 12
}

// NVIDIA screencast reliability with PipeWire
debug { wait-for-frame-completion-in-pipewire }
// If VRR causes cursor glitches, you can try:
// debug { disable-cursor-plane }
EOF

# ── Waybar ───────────────────────────────────────────────────────────────────
echo "→ Writing Waybar config + style…"
install -Dm644 /dev/stdin "$HOME_DIR/.config/waybar/config.jsonc" <<'EOF'
{
  "layer": "top",
  "position": "top",
  "height": 28,
  "margin-top": 6,
  "margin-left": 12,
  "margin-right": 12,
  "spacing": 6,
  "modules-left": ["niri/workspaces", "clock"],
  "modules-center": [],
  "modules-right": ["cpu", "memory", "pulseaudio", "network", "battery", "tray"],
  "clock": { "format": "{:%a %b %d  %H:%M}" },
  "pulseaudio": { "scroll-step": 5, "format": "{volume}% {icon}" },
  "network": { "format-wifi": "{essid} ", "format-ethernet": "ETH", "format-disconnected": "󰖪" },
  "cpu": { "format": "CPU {usage}%" },
  "memory": { "format": "RAM {percentage}%" },
  "battery": { "format": "{capacity}% {icon}" }
}
EOF

install -Dm644 /dev/stdin "$HOME_DIR/.config/waybar/style.css" <<EOF
@define-color base_bg   ${BASE_BG};
@define-color primary_fg ${PRIMARY_FG};
@define-color accent1    ${ACCENT1};
@define-color accent2    ${ACCENT2};
@define-color neutral    ${NEUTRAL};
@define-color highlight  ${HILITE};

* { font-family: "JetBrains Mono","Noto Sans","Noto Sans Mono",monospace; font-size: 13px; }

window#waybar {
  background: @base_bg;
  color: @primary_fg;
  border-radius: 12px;
  padding: 4px 8px;
  border: 1px solid @neutral;
  box-shadow: 0 10px 24px rgba(0,0,0,0.10);
}

#clock, #cpu, #memory, #pulseaudio, #network, #battery, #tray {
  padding: 0 10px; margin: 0 2px;
  border-radius: 8px; background: transparent;
}

#clock:hover, #cpu:hover, #memory:hover, #pulseaudio:hover, #network:hover, #battery:hover {
  background: @highlight; color: @neutral;
}

#niri-workspaces button {
  padding: 0 6px; margin: 0 2px; background: transparent; border-radius: 6px;
  color: @primary_fg;
}
#niri-workspaces button.active { background: @accent1; color: @primary_fg; }
#niri-workspaces button:hover  { background: @accent2; color: #ffffff; }
EOF

# ── Mako ─────────────────────────────────────────────────────────────────────
echo "→ Writing Mako config…"
install -Dm644 /dev/stdin "$HOME_DIR/.config/mako/config" <<EOF
anchor=top-right
background-color=${BASE_BG}
text-color=${PRIMARY_FG}
border-color=${ACCENT1}
border-size=2
default-timeout=5000
font=Noto Sans 11
max-visible=5
padding=8
border-radius=8
EOF

# ── Wofi ─────────────────────────────────────────────────────────────────────
echo "→ Writing Wofi config…"
install -Dm644 /dev/stdin "$HOME_DIR/.config/wofi/config" <<'EOF'
show=drun
prompt=Run:
no_actions=true
term=ghostty
EOF

install -Dm644 /dev/stdin "$HOME_DIR/.config/wofi/style.css" <<EOF
window { background: rgba(166,165,132,0.96); border-radius: 12px; border: 2px solid ${ACCENT1}; }
#input { margin: 8px; padding: 6px; border-radius: 8px; border: 1px solid ${NEUTRAL}; background: ${NEUTRAL}; color: ${PRIMARY_FG}; }
#entry { padding: 6px 8px; }
#entry:selected { background: ${HILITE}; color: ${NEUTRAL}; border-radius: 6px; }
EOF

# ── GTK settings (theme, icons, cursor) ──────────────────────────────────────
echo "→ Writing GTK settings + CSS overlays…"
install -Dm644 /dev/stdin "$HOME_DIR/.config/gtk-3.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=adw-gtk3
gtk-icon-theme-name=Papirus
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Bibata-Modern-Amber
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=false
EOF

install -Dm644 /dev/stdin "$HOME_DIR/.config/gtk-4.0/settings.ini" <<'EOF'
[Settings]
gtk-theme-name=Adwaita
gtk-icon-theme-name=Papirus
gtk-font-name=Noto Sans 10
gtk-cursor-theme-name=Bibata-Modern-Amber
gtk-cursor-theme-size=24
gtk-application-prefer-dark-theme=false
EOF

GTK3_CSS="$HOME_DIR/.config/gtk-3.0/gtk.css"
GTK4_CSS="$HOME_DIR/.config/gtk-4.0/gtk.css"

install -Dm644 /dev/stdin "$GTK3_CSS" <<EOF
/* Rocket theme — GTK3 */
@define-color rocket_base   ${BASE_BG};
@define-color rocket_fg     ${PRIMARY_FG};
@define-color rocket_accent ${ACCENT1};
@define-color rocket_accent2 ${ACCENT2};
@define-color rocket_neutral ${NEUTRAL};
@define-color rocket_hover   ${HILITE};

headerbar, .titlebar, .sidebar, .view, .background {
  background-color: @rocket_base;
  color: @rocket_fg;
}

button.suggested-action, .accent, .default {
  background-color: @rocket_accent;
  color: @rocket_fg;
}
button.suggested-action:hover { background-color: @rocket_hover; color: @rocket_neutral; }

*:selected, selection {
  background-color: @rocket_hover;
  color: @rocket_neutral;
}

entry, textview, .entry {
  background-color: @rocket_neutral;
  color: @rocket_fg;
  border-radius: 8px;
}

/* Rounded CSD corners to match Waybar */
decoration, window.csd {
  border-radius: 12px;
  box-shadow: none;
}
EOF

install -Dm644 /dev/stdin "$GTK4_CSS" <<EOF
/* Rocket theme — GTK4 */
@define-color rocket_base   ${BASE_BG};
@define-color rocket_fg     ${PRIMARY_FG};
@define-color rocket_accent ${ACCENT1};
@define-color rocket_accent2 ${ACCENT2};
@define-color rocket_neutral ${NEUTRAL};
@define-color rocket_hover   ${HILITE};

window, .background { background-color: @rocket_base; color: @rocket_fg; }
.headerbar, headerbar { background-color: @rocket_base; color: @rocket_fg; }
button.suggested-action, .accent { background-color: @rocket_accent; color: @rocket_fg; }
button.suggested-action:hover    { background-color: @rocket_hover; color: @rocket_neutral; }
textview, entry { background-color: @rocket_neutral; color: @rocket_fg; border-radius: 8px; }
selection { background-color: @rocket_hover; color: @rocket_neutral; }
EOF

# XCursor env + fallback (non-GTK apps)
CURTHEME="Bibata-Modern-Amber"
grep -q 'XCURSOR_THEME=' "$HOME_DIR/.profile" 2>/dev/null || {
  echo "export XCURSOR_THEME=${CURTHEME}" >> "$HOME_DIR/.profile"
  echo "export XCURSOR_SIZE=24"           >> "$HOME_DIR/.profile"
}
install -Dm644 /dev/stdin "$HOME_DIR/.icons/default/index.theme" <<'EOF'
[Icon Theme]
Name=Default
Inherits=Bibata-Modern-Amber
EOF

# Try gsettings (non-fatal)
sudo -u "$TARGET_USER" bash -lc '
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.desktop.interface cursor-theme "Bibata-Modern-Amber" || true
  gsettings set org.gnome.desktop.interface icon-theme "Papirus" || true
  gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3" || true
  gsettings set org.gnome.desktop.interface color-scheme "default" || true
fi
' || true

# ── Zsh + oh-my-zsh + starship ───────────────────────────────────────────────
echo "→ Configuring Zsh + oh-my-zsh + starship…"
chsh -s /usr/bin/zsh "$TARGET_USER" || true
sudo -u "$TARGET_USER" env RUNZSH=no KEEP_ZSHRC=yes \
  sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || true

install -Dm644 /dev/stdin "$HOME_DIR/.zshrc" <<'EOF'
export ZDOTDIR="$HOME"
export EDITOR=vim
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
eval "$(starship init zsh)"
EOF

install -Dm644 /dev/stdin "$HOME_DIR/.config/starship.toml" <<EOF
format = "[🚀 \$directory](${PRIMARY_FG}) \$git_branch\$git_status\$python\$character"
palette = "rocket"
[palettes.rocket]
base_bg   = "${BASE_BG}"
primary_fg= "${PRIMARY_FG}"
accent1   = "${ACCENT1}"
[character]
success_symbol = "[❯](accent1)"
error_symbol   = "[❯](accent1)"
vimcmd_symbol  = "❮"
EOF

# ── Ownership & caches ───────────────────────────────────────────────────────
chown -R "$TARGET_USER":"$TARGET_USER" "$HOME_DIR/.config" "$HOME_DIR/.zshrc" \
  "$HOME_DIR/.icons" "$WALLPAPER_DIR" "$HOME_DIR/Pictures/Screenshots" 2>/dev/null || true

# Refresh font cache (for JetBrains Mono, etc.)
fc-cache -f >/dev/null 2>&1 || true

echo
echo "✔ Rocket theme installed."
echo "Reboot or log out/in. greetd → Niri will start:"
echo "  • Waybar (modern, rounded)  • Ghostty  • mako  • wofi"
echo "  • GTK: adw-gtk3 + Papirus + Bibata-Modern-Amber (cursor)"
echo "  • PipeWire/WirePlumber autostarted (runit-less user session)"
echo "  • swww wallpaper: $WALLPAPER_DEST"
echo
echo "Notes:"
echo " - If Waybar lacks the niri module, remove \"niri/workspaces\" or build Waybar with it."
echo " - NVIDIA best results: ensure kernel cmdline has nvidia_drm.modeset=1 (then xbps-reconfigure -fa)."
echo " - Change wallpaper anytime:"
echo "     swww img \"$WALLPAPER_DEST\" --transition-type any --transition-duration 1"
