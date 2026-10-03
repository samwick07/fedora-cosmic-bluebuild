#!/usr/bin/env bash
#
# inventory-workstation.sh — READ-ONLY inventory of what the current machine
# actually has and uses, as evidence for docs/end-state.md. Changes nothing,
# installs nothing, needs no root (a few sections say "(skipped)" without it).
#
#   scripts/inventory-workstation.sh            # -> ~/migration-prep/logs/inventory-<host>-<date>.txt
#
# The output is PRIVATE (package names, connection names, history): attach it
# to the chat or the private journal, never commit it to this public repo.
# Lives in scripts/ — never shipped in the image.
#
set -uo pipefail
dir="${INVENTORY_DIR:-$HOME/migration-prep/logs}"; mkdir -p "$dir"
out="$dir/inventory-$(hostname)-$(date +%Y%m%d-%H%M).txt"

sec() { printf '\n===== %s =====\n' "$1"; shift; "$@" 2>&1 | head -"${MAX:-200}"; }
has() { command -v "$1" >/dev/null 2>&1; }

{
echo "inventory $(date -Is) on $(hostname)"
sec "os"                 bash -c '. /etc/os-release; echo "$PRETTY_NAME"; uname -r; echo "desktop: ${XDG_CURRENT_DESKTOP:-?}"'
sec "hardware"           bash -c 'free -g | head -2; cat /sys/class/dmi/id/product_name 2>/dev/null; cat /sys/power/mem_sleep /sys/power/disk; cat /sys/kernel/security/lockdown 2>/dev/null; swapon --show'

# ── Packages you installed (not the Fedora defaults) ──
MAX=2000 sec "dnf: user-installed packages" bash -c 'dnf repoquery --userinstalled --queryformat "%{name}\n" 2>/dev/null | sort -u || dnf history userinstalled 2>/dev/null'
# What you asked dnf for (the list above also holds everything the installer put down)
MAX=400 sec "dnf: install commands from history" bash -c 'dnf history list 2>/dev/null | grep -iE "install|swap"'
sec "dnf: enabled repos"  dnf repolist --enabled
sec "flatpak apps"        flatpak list --app --columns=application,origin,installation
sec "flatpak overrides"   bash -c 'ls ~/.local/share/flatpak/overrides /var/lib/flatpak/overrides 2>/dev/null'
sec "homebrew"            bash -c 'command -v brew >/dev/null && brew leaves || echo "(no brew)"'
sec "language-level installs" bash -c '
  command -v pipx  >/dev/null && { echo "-- pipx:"; pipx list --short; }
  command -v uv    >/dev/null && { echo "-- uv tools:"; uv tool list; }
  command -v npm   >/dev/null && { echo "-- npm -g:"; npm ls -g --depth=0 2>/dev/null; }
  command -v cargo >/dev/null && { echo "-- cargo:"; cargo install --list; }
  echo "-- pip --user:"; python3 -m pip list --user 2>/dev/null | tail -n +3'
sec "binaries outside packages" bash -c 'ls -la ~/.local/bin ~/bin /usr/local/bin /opt ~/Applications ~/AppImages 2>/dev/null'

# ── Containers and VMs ──
sec "toolbox / distrobox"  bash -c 'toolbox list 2>/dev/null; distrobox list --no-color 2>/dev/null'
sec "podman"               bash -c 'podman ps -a --format "{{.Names}}  {{.Image}}  {{.Status}}"; podman volume ls'
sec "docker"               bash -c 'command -v docker >/dev/null && { docker ps -a --format "{{.Names}}  {{.Image}}  {{.Status}}"; docker volume ls; } || echo "(no docker)"'
sec "libvirt VMs"          bash -c 'virsh -c qemu:///system list --all 2>/dev/null || echo "(no access)"'

# ── What runs ──
sec "enabled system units (non-vendor-preset)" bash -c 'systemctl list-unit-files --state=enabled --no-legend | awk "{print \$1}" | sort'
sec "enabled user units"   systemctl --user list-unit-files --state=enabled --no-legend
sec "user timers / cron"   bash -c 'systemctl --user list-timers --no-pager; crontab -l 2>/dev/null'
sec "autostart"            bash -c 'ls ~/.config/autostart /etc/xdg/autostart 2>/dev/null'
sec "GNOME extensions (features COSMIC must replace)" bash -c 'command -v gnome-extensions >/dev/null && gnome-extensions list --enabled || echo "(none)"'

# ── How it is used ──
history_top() {
    { cat ~/.bash_history ~/.local/share/fish/fish_history 2>/dev/null
      sed 's/^: [0-9]*:[0-9]*;//' ~/.zsh_history 2>/dev/null; } \
    | sed 's/^- cmd: //' \
    | awk '{c=$1; if (c=="sudo"||c=="distrobox"||c=="toolbox"||c=="flatpak") c=c" "$2; print c}' \
    | sort | uniq -c | sort -rn | head -120
}
sec "most-used commands (shell history)" history_top
sec "default apps"         bash -c 'for t in x-scheme-handler/https text/html application/pdf inode/directory; do printf "%s: %s\n" "$t" "$(xdg-mime query default $t)"; done'
sec "network profiles (types)" nmcli -t -f NAME,TYPE connection show
sec "tailscale"            bash -c 'tailscale status --self --peers=false 2>/dev/null | head -2 || echo "(no tailscale)"'
sec "syncthing folders"    bash -c 'grep -o "<folder id=\"[^\"]*\" label=\"[^\"]*\" path=\"[^\"]*\"" ~/.local/state/syncthing/config.xml ~/.config/syncthing/config.xml 2>/dev/null'
sec "USB devices (readers, docks)" lsusb
sec "CAC"                  bash -c 'opensc-tool --list-readers 2>&1; ls ~/.pki/nssdb 2>/dev/null'
sec "home: top-level size" bash -c 'du -sh ~/* ~/.[!.]* 2>/dev/null | sort -rh | head -40'
} > "$out" 2>&1

echo "inventory: $out  ($(wc -l < "$out") lines)"
echo "Private — attach it to the chat; do not commit it."
