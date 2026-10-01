#!/usr/bin/env bash
#
# cosmic-report — snapshot of this machine's state for the journal or a bug report.
# Shipped in the image at /usr/bin/cosmic-report.
#
#   cosmic-report ["what you were doing"]            # private: ~/migration-prep/logs/report-<host>-<time>.txt
#   cosmic-report --public ["what you were doing"]   # user, host, UUIDs, tailnet replaced -> safe for a GitHub issue
#
# Runs as your user; uses `sudo -n` only where root adds detail (no prompt).
#
set -uo pipefail

PUBLIC=0
[[ "${1:-}" == --public ]] && { PUBLIC=1; shift; }
NOTE="${*:-}"
host=$(hostname)
if [[ -n "${COSMIC_REPORT_DIR:-}" ]]; then dir="$COSMIC_REPORT_DIR"
elif [[ -d "$HOME/migration-prep/logs" ]]; then dir="$HOME/migration-prep/logs"
else dir="$HOME/cosmic-reports"; fi
mkdir -p "$dir"
out="$dir/report-${host}-$(date +%Y%m%d-%H%M%S)$([[ $PUBLIC == 1 ]] && echo -public).txt"

sec() { printf '\n===== %s =====\n' "$1"; shift; "$@" 2>&1 | head -"${LINES_MAX:-80}"; }
root() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else echo "(needs root — rerun after 'sudo -v' for this section)"; fi; }

{
    echo "cosmic-report $(date -Is)"
    [[ -n "$NOTE" ]] && echo "note: $NOTE"
    sec "image"            bash -c '. /usr/lib/os-release; echo "$PRETTY_NAME ($VARIANT_ID) $OSTREE_VERSION"; rpm-ostree status -b 2>/dev/null | sed -n "1,12p"'
    sec "bootc status"     root bootc status
    sec "kernel"           bash -c 'uname -r; cat /proc/cmdline'
    sec "failed units"     systemctl --failed --no-legend
    sec "failed user units" systemctl --user --failed --no-legend
    sec "errors this boot" journalctl -b -p err --no-pager -q -n 60
    sec "post-install-setup --check" post-install-setup.sh --check
    sec "hibernation"      bash -c 'swapon --show; echo "mem_sleep: $(cat /sys/power/mem_sleep)"; echo "disk: $(cat /sys/power/disk)"; grep -o "resume=[^ ]*" /proc/cmdline'
    sec "CAC"              setup-cac.sh --check
    sec "network"          bash -c 'nmcli -t -f NAME,TYPE,DEVICE connection show --active; tailscale status --peers=false 2>/dev/null | head -3'
    sec "disks"            lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
    sec "distrobox"        distrobox list --no-color
    sec "flatpaks (system)" flatpak list --system --columns=application
} > "$out" 2>&1

if [[ "$PUBLIC" == 1 ]]; then
    sed -i -E \
        -e "s/\\b${USER}\\b/<user>/g" -e "s/\\b${host}\\b/<host>/g" \
        -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
        -e 's/\b[0-9A-F]{4}-[0-9A-F]{4}\b/<uuid>/g' \
        -e 's/[A-Za-z0-9-]+\.ts\.net/<tailnet>/g' \
        -e 's/\b100\.[0-9]+\.[0-9]+\.[0-9]+\b/<tailscale-ip>/g' "$out"
    echo "public report (check it once more before posting): $out"
else
    echo "report: $out"
fi
