#!/usr/bin/env bash
#
# cosmic-report — snapshot of this machine's state for the journal or a bug report.
# Shipped in the image at /usr/bin/cosmic-report.
#
#   cosmic-report ["what you were doing"]            # private: ~/migration-prep/logs/report-<host>-<time>.txt
#   cosmic-report --public ["what you were doing"]   # user, host, UUIDs, tailnet replaced -> safe for a GitHub issue
#   cosmic-report --offline ROOT ["note"]            # ROOT = a bootc root mounted read-only from another
#                                                    # system (e.g. the test drive over USB): reads what is
#                                                    # on disk — nightly report, journal, chezmoi,
#                                                    # containers, libvirt, CAC db — runs nothing from it.
#                                                    # Works from the repo checkout: files/scripts/cosmic-report.sh
#
# Runs as your user; uses `sudo -n` only where root adds detail (no prompt).
#
set -uo pipefail

PUBLIC=0; OFFLINE=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --public)  PUBLIC=1; shift ;;
        --offline) OFFLINE="${2:?--offline needs the mounted root}"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done
NOTE="${*:-}"
host=$(hostname)
if [[ -n "${COSMIC_REPORT_DIR:-}" ]]; then dir="$COSMIC_REPORT_DIR"
elif [[ -d "$HOME/migration-prep/logs" ]]; then dir="$HOME/migration-prep/logs"
else dir="$HOME/cosmic-reports"; fi
mkdir -p "$dir"

sec() { printf '\n===== %s =====\n' "$1"; shift; "$@" 2>&1 | head -"${LINES_MAX:-80}"; }
root() { if sudo -n true 2>/dev/null; then sudo -n "$@"; else echo "(needs root — rerun after 'sudo -v' for this section)"; fi; }

# ─── Offline: a bootc root mounted somewhere else ─────────────────────
offline_report() {
    local R="$OFFLINE" DEP VAR ETC u
    R="${R%/}"
    [[ -d "$R/ostree/deploy" ]] || { echo "ERROR: $R has no ostree/deploy — not a bootc root (mount the LUKS root, not /boot)" >&2; exit 1; }
    DEP=$(ls -d "$R"/ostree/deploy/*/deploy/*.0 2>/dev/null | head -1)
    VAR=$(ls -d "$R"/ostree/deploy/*/var 2>/dev/null | head -1)
    ETC="$DEP/etc"
    # the login user: site.env, else the one home directory that is not linuxbrew
    u=$(sed -n 's/^NIGHTLY_USER="\{0,1\}\([^"]*\)"\{0,1\}/\1/p' "$ETC/fedora-cosmic-atomic/nightly.env" 2>/dev/null | head -1)
    [[ -n "$u" ]] || u=$(ls "$VAR/home" 2>/dev/null | grep -v '^linuxbrew$' | head -1)
    local H="$VAR/home/$u"
    host=$(cat "$ETC/hostname" 2>/dev/null || echo offline)

    echo "cosmic-report --offline $(date -Is)   root=$R   deployment=${DEP#"$R"/}   user=$u"
    [[ -n "$NOTE" ]] && echo "note: $NOTE"
    sec "image"               bash -c ". '$DEP/usr/lib/os-release'; echo \"\$PRETTY_NAME (\$VARIANT_ID) \${OSTREE_VERSION:-}\"; cat '$R/ostree/repo/refs/heads/ostree/0/1/0' 2>/dev/null"
    sec "install target"      grep -E '^(TARGET_NAME|TEST_INSTALL|SKIP_FINALIZE|CREATE_USER)=' "$ETC/fedora-cosmic-atomic/install-target.env"
    sec "nightly job: last report" cat "$VAR/lib/cosmic-nightly/report.txt"
    sec "boots in the journal" journalctl -D "$VAR/log/journal" --list-boots --no-pager
    sec "errors, last boot"   journalctl -D "$VAR/log/journal" -b -p err --no-pager -q -n 80
    sec "pcscd / CAC, last boot" journalctl -D "$VAR/log/journal" -b -u pcscd.service -u pcscd.socket --no-pager -q -n 40
    sec "failed units, last boot" journalctl -D "$VAR/log/journal" -b --no-pager -q -g 'Failed to start|entered failed state' -n 40
    sec "step 2: restored"    bash -c "ls -d '$H'/.ssh '$H'/.gnupg '$H'/.restic '$H'/.config/gh '$H'/.claude '$H'/migration-prep 2>&1; ls '$H'/.ssh 2>/dev/null"
    sec "step 3: hibernation" bash -c "grep -E 'swap|resume' '$ETC/fstab'; grep -rho 'resume=[^ ]*' '$R/boot/loader/entries' '$R/ostree' 2>/dev/null | sort -u | head -3"
    sec "step 4/6: CAC"       bash -c "ls '$ETC/pki/ca-trust/source/anchors' 2>/dev/null | head; echo '--- user nssdb:'; ls -la '$H/.pki/nssdb' 2>/dev/null; certutil -L -d sql:'$H/.pki/nssdb' 2>/dev/null | grep -c 'DOD\|DoD' | sed 's/^/  DoD certs: /'; timeout 20 modutil -dbdir sql:'$H/.pki/nssdb' -list </dev/null 2>/dev/null | grep -A1 -i 'opensc\|CAC'"
    sec "step 5: libvirt"     bash -c "ls -la '$ETC/libvirt/qemu' 2>&1; ls '$VAR/lib/libvirt/qemu/nvram' '$VAR/lib/libvirt/swtpm' '$VAR/lib/libvirt/vm-images' 2>&1; grep -o '<uuid>[^<]*' '$ETC/libvirt/qemu/Win11VM.xml' 2>/dev/null"
    sec "step 6: chezmoi"     bash -c "git -C '$H/.local/share/chezmoi' log --oneline -3 2>&1; ls '$H/.config/chezmoi' 2>&1; command -v chezmoi >/dev/null && chezmoi state dump --persistent-state '$H/.config/chezmoi/chezmoistate.boltdb' 2>/dev/null | grep -o '\"[^\"]*run_once[^\"]*\"\|\"[^\"]*run_onchange[^\"]*\"' | sort -u"
    sec "step 6: homebrew"    bash -c "ls '$VAR/home/linuxbrew/.linuxbrew/Cellar' 2>&1 | tr '\n' ' '; echo; ls -la '$H/.config/homebrew/Brewfile' 2>&1"
    sec "step 6: containers"  bash -c "f='$H/.local/share/containers/storage/overlay-containers/containers.json'; [[ -f \$f ]] && grep -o '\"names\":\[\"[^\"]*\"' \"\$f\" | cut -d'\"' -f4; echo '--- exported apps:'; ls '$H/.local/share/applications' 2>&1"
    sec "step 6: syncthing"   bash -c "ls -la '$H/.local/state/syncthing' '$H/.config/syncthing' 2>&1 | grep -v '^total'; ls '$H/.config/systemd/user' 2>/dev/null"
    sec "step 7: tailscale"   bash -c "ls -la '$VAR/lib/tailscale' 2>&1"
    sec "user units"          bash -c "ls '$ETC/systemd/user' '$H/.config/systemd/user/default.target.wants' 2>&1"
}

if [[ -n "$OFFLINE" ]]; then
    tmp=$(mktemp "$dir/.report.XXXXXX")
    offline_report > "$tmp" 2>&1        # sets $host from the mounted root's /etc/hostname
    out="$dir/report-${host}-offline-$(date +%Y%m%d-%H%M%S)$([[ $PUBLIC == 1 ]] && echo -public).txt"
    mv "$tmp" "$out"
else
out="$dir/report-${host}-$(date +%Y%m%d-%H%M%S)$([[ $PUBLIC == 1 ]] && echo -public).txt"
{
    echo "cosmic-report $(date -Is)"
    [[ -n "$NOTE" ]] && echo "note: $NOTE"
    sec "image"            bash -c '. /usr/lib/os-release; echo "$PRETTY_NAME ($VARIANT_ID) $OSTREE_VERSION"; rpm-ostree status -b 2>/dev/null | sed -n "1,12p"'
    sec "bootc status"     root bootc status
    sec "kernel"           bash -c 'uname -r; cat /proc/cmdline'
    sec "failed units"     systemctl --failed --no-legend
    sec "failed user units" systemctl --user --failed --no-legend
    sec "errors this boot" journalctl -b -p err --no-pager -q -n 60
    sec "nightly job: last report" cat /var/lib/cosmic-nightly/report.txt
    sec "nightly timer"    systemctl list-timers cosmic-nightly.timer --no-pager
    sec "hibernation"      bash -c 'swapon --show; echo "mem_sleep: $(cat /sys/power/mem_sleep)"; echo "disk: $(cat /sys/power/disk)"; grep -o "resume=[^ ]*" /proc/cmdline'
    sec "CAC"              cac-status
    sec "network"          bash -c 'nmcli -t -f NAME,TYPE,DEVICE connection show --active; tailscale status --peers=false 2>/dev/null | head -3'
    sec "disks"            lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS
    sec "distrobox"        distrobox list --no-color
    sec "flatpaks (system)" flatpak list --system --columns=application
} > "$out" 2>&1
fi

if [[ "$PUBLIC" == 1 ]]; then
    u="${USER}"; [[ -n "$OFFLINE" ]] && u=$(sed -n 's/^.*user=\([^ ]*\).*/\1/p' "$out" | head -1)
    sed -i -E \
        -e "s/\\b${u}\\b/<user>/g" -e "s/\\b${host}\\b/<host>/g" \
        -e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/<uuid>/g' \
        -e 's/\b[0-9A-F]{4}-[0-9A-F]{4}\b/<uuid>/g' \
        -e 's/[A-Za-z0-9-]+\.ts\.net/<tailnet>/g' \
        -e 's/\b100\.[0-9]+\.[0-9]+\.[0-9]+\b/<tailscale-ip>/g' "$out"
    echo "public report (check it once more before posting): $out"
else
    echo "report: $out"
fi
