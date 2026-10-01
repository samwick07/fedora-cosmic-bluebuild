#!/bin/bash
#
# frmwrk_backup_command.sh — Restic backup for Framework 13 AMD
# Lives on the DAS next to the repo it writes to; this copy in the repo is the
# source of truth — copy it there after editing. Every path is relative to the
# script's own location, so nothing here names the user or the mount point.
#
# Backs up: home, libvirt VMs + config + UEFI/TPM state, network + sudoers
#           config, tailscale identity, BLS entries, the BlueBuild repo.
# Repository: <DAS>/frmwrk-restic-repo/   (excludes: <DAS>/frmwrk-restic-excludes)
#
# Usage: <DAS>/frmwrk_backup_command.sh       (as your user; re-runs itself under sudo)
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
# /home/<user>, not getent's /var/home on Atomic: keeps snapshot paths (and the
# parent snapshot) identical across the Workstation and the new OS.
USER_HOME="/home/$SUDO_USER"
[[ -d "$USER_HOME" ]] || { echo "ERROR: $USER_HOME not found"; exit 1; }

DAS="$(dirname "$(readlink -f "$0")")"
REPO="$DAS/frmwrk-restic-repo"
EXCLUDES="$DAS/frmwrk-restic-excludes"
PASSFILE="$USER_HOME/.restic/frmwrk-repo.pass"
LOGFILE="$DAS/frmwrk-backup.log"

[[ -d "$REPO" ]]    || { echo "ERROR: restic repo not found at $REPO — is the DAS mounted?"; exit 1; }
[[ -f "$PASSFILE" ]] || { echo "ERROR: password file not found at $PASSFILE"; exit 1; }
[[ -f "$EXCLUDES" ]] || { echo "ERROR: exclude file not found at $EXCLUDES"; exit 1; }

export RESTIC_REPOSITORY="$REPO"
export RESTIC_PASSWORD_FILE="$PASSFILE"
# The exclude file uses $BACKUP_HOME/...; restic expands environment variables
# there. Unset, those patterns would collapse to /... — hence the check above.
export BACKUP_HOME="$USER_HOME"

# A test install (install-atomic.sh TEST_INSTALL=1, hostname <name>-test) backs
# up as its own restic host; tag it too so `restic forget --tag test --prune`
# removes the lot once the test is over.
TEST_TAG=""
grep -qs "^TEST_INSTALL=1" /etc/fedora-cosmic-atomic/install-target.env && TEST_TAG="test"

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
    ${TEST_TAG:+--tag "$TEST_TAG"} \
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
