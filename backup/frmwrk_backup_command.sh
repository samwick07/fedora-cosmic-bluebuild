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
# Usage: ./frmwrk_backup_command.sh            (as <user>; uses sudo for root paths)
#
set -euo pipefail

REPO="/run/media/<user>/DAS/frmwrk-restic-repo"
EXCLUDES="/run/media/<user>/DAS/frmwrk-restic-excludes"
PASSFILE="$HOME/.restic/frmwrk-repo.pass"
LOGFILE="/run/media/<user>/DAS/frmwrk-backup.log"

[[ -d "$REPO" ]]    || { echo "ERROR: restic repo not found at $REPO — is the DAS mounted?"; exit 1; }
[[ -f "$PASSFILE" ]] || { echo "ERROR: password file not found at $PASSFILE"; exit 1; }
[[ -f "$EXCLUDES" ]] || { echo "ERROR: exclude file not found at $EXCLUDES"; exit 1; }

export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSFILE"

echo "=== Framework backup started: $(date) ===" | tee -a "$LOGFILE"

# Clear a stale lock left by an interrupted run (only if no restic is running).
if ! pgrep -x restic >/dev/null && sudo restic list locks 2>/dev/null | grep -q .; then
    echo "removing stale lock" | tee -a "$LOGFILE"
    sudo restic unlock 2>&1 | tee -a "$LOGFILE"
fi

# Paths. Keep this list STABLE: changing it makes restic lose the parent
# snapshot and re-read everything (slow, not unsafe).
sudo restic backup \
    --verbose \
    --exclude-file "$EXCLUDES" \
    --tag frmwrk \
    --tag "$(hostname)" \
    "$HOME" \
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
sudo restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune 2>&1 | tee -a "$LOGFILE"

echo "=== Latest snapshots: $(date) ===" | tee -a "$LOGFILE"
sudo restic snapshots --latest 3 2>&1 | tee -a "$LOGFILE"

# Cheap integrity check every run; a deep one (--read-data-subset) monthly by hand.
echo "=== restic check: $(date) ===" | tee -a "$LOGFILE"
sudo restic check 2>&1 | tee -a "$LOGFILE"
echo "=== Backup complete: $(date) ===" | tee -a "$LOGFILE"
