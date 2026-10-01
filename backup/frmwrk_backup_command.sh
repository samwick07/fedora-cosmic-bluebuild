#!/bin/bash
#
# frmwrk_backup_command.sh — Restic backup for Framework 13 AMD
# Lives on the DAS at /run/media/<user>/DAS/frmwrk_backup_command.sh; this
# copy in the repo is the source of truth — copy it there after editing.
#
# Backs up: home, libvirt VMs + config + UEFI/TPM state, network + sudoers
#           config, tailscale identity, BLS entries, the BlueBuild repo.
# Repository: /run/media/<user>/DAS/frmwrk-restic-repo/
#
# Usage: ./frmwrk_backup_command.sh            (as <user>; re-runs itself under sudo)
#
# Root is needed for the libvirt/etc paths. The script asks for the sudo
# password once and then runs entirely as root, so a multi-hour run never
# outlives the sudo timestamp. No sudoers rule is needed.
#
set -euo pipefail

[[ $EUID -eq 0 ]] || exec sudo -- "$(readlink -f "$0")" "$@"

# Under sudo $HOME is /root; back up the invoking user's home.
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] \
    || { echo "ERROR: run as your normal user (the script elevates itself)"; exit 1; }
USER_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"

REPO="/run/media/<user>/DAS/frmwrk-restic-repo"
EXCLUDES="/run/media/<user>/DAS/frmwrk-restic-excludes"
PASSFILE="$USER_HOME/.restic/frmwrk-repo.pass"
LOGFILE="/run/media/<user>/DAS/frmwrk-backup.log"

[[ -d "$REPO" ]]    || { echo "ERROR: restic repo not found at $REPO — is the DAS mounted?"; exit 1; }
[[ -f "$PASSFILE" ]] || { echo "ERROR: password file not found at $PASSFILE"; exit 1; }
[[ -f "$EXCLUDES" ]] || { echo "ERROR: exclude file not found at $EXCLUDES"; exit 1; }

export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSFILE"

echo "=== Framework backup started: $(date) ===" | tee -a "$LOGFILE"

# Clear a stale lock left by an interrupted run (only if no restic is running).
if ! pgrep -x restic >/dev/null && restic list locks 2>/dev/null | grep -q .; then
    echo "removing stale lock" | tee -a "$LOGFILE"
    restic unlock 2>&1 | tee -a "$LOGFILE"
fi

# Paths. Keep this list STABLE: changing it makes restic lose the parent
# snapshot and re-read everything (slow, not unsafe).
restic backup \
    --verbose \
    --exclude-file "$EXCLUDES" \
    --tag frmwrk \
    --tag "$(hostname)" \
    "$USER_HOME" \
    /var/lib/libvirt/vm-images/ \
    /var/lib/libvirt/images/ \
    /var/lib/libvirt/qemu/nvram/ \
    /var/lib/libvirt/swtpm/ \
    /var/lib/docker/volumes/ \
    /var/lib/tailscale/ \
    /etc/libvirt/ \
    /etc/fstab \
    /etc/crypttab \
    /etc/sudoers.d/ \
    /boot/loader/entries/ \
    /etc/NetworkManager/ \
    /etc/systemd/system/ \
    2>&1 | tee -a "$LOGFILE"

echo "=== Pruning old snapshots: $(date) ===" | tee -a "$LOGFILE"
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune 2>&1 | tee -a "$LOGFILE"

echo "=== Latest snapshots: $(date) ===" | tee -a "$LOGFILE"
restic snapshots --latest 3 2>&1 | tee -a "$LOGFILE"

# Cheap integrity check every run; a deep one (--read-data-subset) monthly by hand.
echo "=== restic check: $(date) ===" | tee -a "$LOGFILE"
restic check 2>&1 | tee -a "$LOGFILE"
echo "=== Backup complete: $(date) ===" | tee -a "$LOGFILE"
