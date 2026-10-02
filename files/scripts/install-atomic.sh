#!/usr/bin/env bash
#
# install-atomic.sh — Install the BlueBuild Fedora Cosmic Atomic image onto a
# pre-partitioned, LUKS-encrypted disk with `bootc install to-filesystem`.
#
# Usage:
#   sudo scripts/install-atomic.sh scripts/targets/<name>.env [--yes]   (repo)
#   sudo install-atomic.sh /path/<name>.env [--yes]                      (shipped in the image)
#
# The .env (generate it with scripts/make-target-env.sh) names the target by
# UUID only. Site values (user, hostname, DAS, protected disks) come from
# SITE_FILE, else site.env next to the target .env, else the running system's
# /etc/fedora-cosmic-atomic/site.env; the target .env may override any of them. Device letters (/dev/sdb, /dev/nvme1n1) are never trusted: they
# change with what is plugged in.
#
# What it does
#   1. Resolves every partition by UUID and proves all of them sit on ONE disk.
#   2. Refuses if any PROTECTED_LUKS_UUIDS (the 4TB Workstation, the DAS) or the
#      disk the running system booted from is that disk.
#   3. Unlocks the LUKS containers if needed, unmounts anything mounted from them.
#   4. Copies the image into root's podman storage if only your user has it
#      (before anything is written, so a failed copy leaves the disk untouched).
#   5. Shows a summary and waits for you to type the disk name.
#   6. Reformats the ESP (vfat) and /boot (ext4) with their SAME UUIDs and labels
#      — a previous OS's boot entries and bootupd state there break bootc —
#      and mkfs.btrfs the root container (partition table, LUKS and swap kept),
#      mounts root -> /boot -> /boot/efi in that order.
#   7. Runs bootc install to-filesystem (separate /boot, LUKS + resume kargs,
#      --bootloader none), then bootupd for the EFI files only. The firmware's
#      boot entries are never written: efivars is read-only in both containers.
#   8. Writes /etc/crypttab and the swap fstab line into the new deployment so
#      the first boot unlocks both containers and activates swap.
#   9. Creates the login user (bootc creates none) and sets its + root's password.
#
# What it does NOT do: touch the partition table, format the ESP or /boot, or
# change anything outside the target disk.
#
set -euo pipefail

# ─── Args ──────────────────────────────────────────────────────────────
ENV_FILE="${1:?usage: install-atomic.sh scripts/targets/<name>.env [--yes]}"
ASSUME_YES=0
[[ "${2:-}" == "--yes" ]] && ASSUME_YES=1

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found" >&2; exit 1; }
if [[ -z "${SITE_FILE:-}" ]]; then
    for SITE_FILE in "$(dirname "$ENV_FILE")/site.env" /etc/fedora-cosmic-atomic/site.env; do
        [[ -f "$SITE_FILE" ]] && break
    done
fi
[[ -f "$SITE_FILE" ]] || { echo "ERROR: no site.env (next to $ENV_FILE or in /etc/fedora-cosmic-atomic/); template: scripts/targets/site.example.env" >&2; exit 1; }
echo "site values: $SITE_FILE"

# shellcheck disable=SC1090
source "$SITE_FILE"
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${TARGET_NAME:?}" "${EFI_UUID:?}" "${BOOT_UUID:?}" "${ROOT_LUKS_UUID:?}" \
  "${IMAGE:?}" "${TARGET_IMGREF:?}"
SWAP_LUKS_UUID="${SWAP_LUKS_UUID:-}"
PROTECTED_LUKS_UUIDS="${PROTECTED_LUKS_UUIDS:-}"
SKIP_FINALIZE="${SKIP_FINALIZE:-1}"
MOUNT_ROOT="${MOUNT_ROOT:-/mnt/atomic-target}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

for cmd in lsblk blkid findmnt cryptsetup mkfs.btrfs podman; do
    command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

# ─── Helpers ───────────────────────────────────────────────────────────
by_uuid() {  # UUID -> /dev/xxx (fails if absent)
    local p="/dev/disk/by-uuid/$1"
    [[ -e "$p" ]] || die "no block device with UUID $1 (is the disk plugged in and, for LUKS, is it a raw partition UUID?)"
    readlink -f "$p"
}

disk_of() {  # any block device (partition, LUKS/dm, …) -> its one whole disk, e.g. nvme0n1
    local dev disks
    dev=$(readlink -f "$1")
    # -s walks the inverse tree (device -> its parents). PKNAME is empty for
    # dm devices (an unlocked LUKS root), so it cannot be used to climb.
    disks=$(lsblk -snro NAME,TYPE "$dev" | awk '$2=="disk"{print $1}' | sort -u)
    [[ -n "$disks" ]] || die "cannot find parent disk of $dev"
    [[ $(wc -l <<<"$disks") -eq 1 ]] || die "$dev spans several disks ($(tr '\n' ' ' <<<"$disks")) — refusing"
    echo "$disks"
}

unmount_all_from() {  # unmount every mountpoint whose source is this device
    local dev="$1" m
    while read -r m; do
        [[ -n "$m" ]] || continue
        info "umount $m"
        umount -R "$m"
    done < <(findmnt -rn -S "$dev" -o TARGET 2>/dev/null || true)
}

# ─── 1. Resolve the target by UUID ─────────────────────────────────────
log "Resolving target '$TARGET_NAME' by UUID"
EFI_PART=$(by_uuid "$EFI_UUID")
BOOT_PART=$(by_uuid "$BOOT_UUID")
ROOT_LUKS_PART=$(by_uuid "$ROOT_LUKS_UUID")
SWAP_LUKS_PART=""
[[ -n "$SWAP_LUKS_UUID" ]] && SWAP_LUKS_PART=$(by_uuid "$SWAP_LUKS_UUID")

[[ $(blkid -s TYPE -o value "$EFI_PART") == vfat ]]        || die "$EFI_PART is not vfat"
[[ $(blkid -s TYPE -o value "$BOOT_PART") == ext4 ]]       || die "$BOOT_PART is not ext4"
[[ $(blkid -s TYPE -o value "$ROOT_LUKS_PART") == crypto_LUKS ]] || die "$ROOT_LUKS_PART is not LUKS"
[[ -z "$SWAP_LUKS_PART" || $(blkid -s TYPE -o value "$SWAP_LUKS_PART") == crypto_LUKS ]] || die "$SWAP_LUKS_PART is not LUKS"

TARGET_DISK=$(disk_of "$ROOT_LUKS_PART")
for p in "$EFI_PART" "$BOOT_PART" ${SWAP_LUKS_PART:+"$SWAP_LUKS_PART"}; do
    [[ $(disk_of "$p") == "$TARGET_DISK" ]] || die "$p is on $(disk_of "$p"), not on $TARGET_DISK — refusing"
done
info "target disk: /dev/$TARGET_DISK  ($(lsblk -dno MODEL,SIZE "/dev/$TARGET_DISK" | tr -s ' '))"

# ─── 2. Safety: protected disks ────────────────────────────────────────
log "Safety checks"
RUNNING_ROOT_SRC=$(findmnt -no SOURCE / | sed 's/\[.*\]//')
RUNNING_DISK=$(disk_of "$RUNNING_ROOT_SRC")
[[ "$RUNNING_DISK" != "$TARGET_DISK" ]] || die "target /dev/$TARGET_DISK is the disk this system is running from — refusing"
info "running system is on /dev/$RUNNING_DISK (ok)"

for u in $PROTECTED_LUKS_UUIDS; do
    p="/dev/disk/by-uuid/$u"
    if [[ -e "$p" ]]; then
        d=$(disk_of "$p")
        [[ "$d" != "$TARGET_DISK" ]] || die "protected LUKS $u lives on /dev/$TARGET_DISK — refusing"
        info "protected $u is on /dev/$d (ok)"
    else
        info "protected $u not present (ok)"
    fi
done

# ─── 3. Unlock and unmount ─────────────────────────────────────────────
log "Unlocking LUKS containers"
ROOT_DM="/dev/mapper/luks-$ROOT_LUKS_UUID"
SWAP_DM=""
[[ -n "$SWAP_LUKS_UUID" ]] && SWAP_DM="/dev/mapper/luks-$SWAP_LUKS_UUID"

if [[ ! -e "$ROOT_DM" ]]; then
    info "opening root container (passphrase prompt)"
    cryptsetup open "$ROOT_LUKS_PART" "luks-$ROOT_LUKS_UUID"
fi
if [[ -n "$SWAP_DM" && ! -e "$SWAP_DM" ]]; then
    info "opening swap container (passphrase prompt)"
    cryptsetup open "$SWAP_LUKS_PART" "luks-$SWAP_LUKS_UUID"
fi

log "Unmounting anything mounted from the target"
unmount_all_from "$ROOT_DM"
unmount_all_from "$BOOT_PART"
unmount_all_from "$EFI_PART"
[[ -n "$SWAP_DM" ]] && { swapoff "$SWAP_DM" 2>/dev/null || true; }
umount -R "$MOUNT_ROOT" 2>/dev/null || true

# Swap filesystem UUID (inside the LUKS container) for resume=
SWAP_FS_UUID=""
if [[ -n "$SWAP_DM" ]]; then
    SWAP_FS_UUID=$(blkid -s UUID -o value "$SWAP_DM" || true)
    if [[ -z "$SWAP_FS_UUID" || $(blkid -s TYPE -o value "$SWAP_DM") != swap ]]; then
        info "swap container has no swap signature — creating one"
        mkswap -L fedora_swap "$SWAP_DM" >/dev/null
        SWAP_FS_UUID=$(blkid -s UUID -o value "$SWAP_DM")
    fi
fi

# ─── 4. Image in root podman storage (before anything is written) ─────
log "Checking image $IMAGE"
# The user's copy is the one that was pulled + verified; root's may be stale
# from an earlier run. Use the user's whenever the two differ.
root_id=$(podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
user_id=""
[[ -n "${SUDO_USER:-}" ]] && user_id=$(sudo -u "$SUDO_USER" podman image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null || true)
if [[ -n "$user_id" && "$user_id" != "$root_id" ]]; then
    [[ -n "$root_id" ]] && info "root's copy (${root_id:0:12}) differs from $SUDO_USER's (${user_id:0:12}) — replacing it"
    info "copying from $SUDO_USER's podman storage (no download)"
    sudo -u "$SUDO_USER" podman save "$IMAGE" --format oci-archive | podman load
    [[ $(podman image inspect "$IMAGE" --format '{{.Id}}') == "$user_id" ]] || die "copy failed: root's $IMAGE is not ${user_id:0:12}"
elif [[ -z "$root_id" ]]; then
    die "image $IMAGE not found in root's or ${SUDO_USER:-the user}'s podman storage — podman pull it (and cosign verify) first"
fi
podman run --rm "$IMAGE" test -x /usr/bin/bootc || die "$IMAGE has no /usr/bin/bootc"
info "image id $(podman image inspect "$IMAGE" --format '{{.Id}}' | cut -c1-12)"

# ─── 5. Confirm ────────────────────────────────────────────────────────
log "About to install"
cat <<EOF
    Disk            /dev/$TARGET_DISK  (will NOT be repartitioned)
    ESP             $EFI_PART   UUID=$EFI_UUID        *** REFORMATTED (same UUID) ***
    /boot           $BOOT_PART   UUID=$BOOT_UUID       *** REFORMATTED (same UUID) ***
    root LUKS       $ROOT_LUKS_PART  -> $ROOT_DM     *** btrfs WILL BE REFORMATTED ***
    swap LUKS       ${SWAP_LUKS_PART:-none}  ${SWAP_DM:+-> $SWAP_DM (swap UUID $SWAP_FS_UUID)}
    Image           $IMAGE  (id $(podman image inspect "$IMAGE" --format '{{.Id}}' | cut -c1-12))
    Updates from    $TARGET_IMGREF
    Bootloader      grub (BLS entries on /boot, shim+grub on the ESP)
    Firmware        never written (efivars read-only; bootupd without --update-firmware); boots via ESP fallback
    Test install    $([[ "${TEST_INSTALL:-0}" == 1 ]] && echo "yes (Syncthing stays off; use scripts/test/syncthing-2tb-check.sh)" || echo "no (real install)")
    Hostname        $(if [[ -z "${SITE_HOSTNAME:-}" ]]; then echo "(not set — add SITE_HOSTNAME to site.env)"; elif [[ "${TEST_INSTALL:-0}" == 1 ]]; then echo "$SITE_HOSTNAME-test"; else echo "$SITE_HOSTNAME"; fi)
    Finalize        $([[ "$SKIP_FINALIZE" == 1 ]] && echo "skipped (no fstrim — USB/DAS disk)" || echo "yes")
EOF
if [[ "$ASSUME_YES" != 1 ]]; then
    printf '\nType the disk name (%s) to continue: ' "$TARGET_DISK"
    read -r answer
    [[ "$answer" == "$TARGET_DISK" ]] || die "aborted"
fi

# ─── 6. Format ESP, /boot, root; mount in order ─────────────────────────
# ESP and /boot are reformatted too, keeping UUID + label (fstab, kargs and the
# ESP's grub stub find them by UUID; firmware entries use the PARTUUID, which
# mkfs does not touch). Kept, they carry the previous OS's BLS entries and
# bootupd-state.json, and bootc aborts parsing deployments that no longer exist.
log "Formatting ESP, /boot and root, then mounting"
umount "$EFI_PART" 2>/dev/null || true; umount "$BOOT_PART" 2>/dev/null || true
efi_label=$(blkid -s LABEL -o value "$EFI_PART" || true)
boot_label=$(blkid -s LABEL -o value "$BOOT_PART" || true)
mkfs.vfat -F32 -i "${EFI_UUID//-/}" -n "${efi_label:-EFI}" "$EFI_PART" >/dev/null
mkfs.ext4 -q -F -U "$BOOT_UUID" -L "${boot_label:-boot}" "$BOOT_PART"
udevadm settle
[[ $(blkid -s UUID -o value "$EFI_PART") == "$EFI_UUID" ]]   || die "ESP UUID changed after mkfs — check $EFI_PART"
[[ $(blkid -s UUID -o value "$BOOT_PART") == "$BOOT_UUID" ]] || die "/boot UUID changed after mkfs — check $BOOT_PART"
mkfs.btrfs -f -L fedora_root "$ROOT_DM" >/dev/null
mkdir -p "$MOUNT_ROOT"
mount -o compress=zstd:1 "$ROOT_DM" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot"
mount "$BOOT_PART" "$MOUNT_ROOT/boot"
mkdir -p "$MOUNT_ROOT/boot/efi"
mount "$EFI_PART" "$MOUNT_ROOT/boot/efi"
findmnt -R "$MOUNT_ROOT" -o TARGET,SOURCE,FSTYPE


# ─── 7. bootc install ──────────────────────────────────────────────────
log "bootc install to-filesystem"
KARGS=(--karg "rd.luks.uuid=$ROOT_LUKS_UUID" --karg "rootflags=compress=zstd:1")
if [[ -n "$SWAP_LUKS_UUID" ]]; then
    KARGS+=(--karg "rd.luks.uuid=$SWAP_LUKS_UUID" --karg "resume=UUID=$SWAP_FS_UUID")
fi
FINALIZE=()
[[ "$SKIP_FINALIZE" == 1 ]] && FINALIZE=(--skip-finalize)

# The firmware's boot entries (NVRAM) are NEVER written by this script.
# bootc's own bootloader step runs bootupd with --update-firmware, which
# deletes every entry labelled "Fedora" on ANY disk — the running system's too
# — and creates one for the target (install runs 4 and 5). bootc 1.16 runs it
# inside the new deployment, so stubbing efibootmgr in the container did not
# help. Instead:
#   1. bootc installs with --bootloader none (no bootupd at all);
#   2. we run bootupd ourselves: EFI component only, WITHOUT --update-firmware
#      (it only writes files: shim, grub, the EFI/BOOT fallback, grub.cfg);
#   3. both containers see /sys/firmware/efi/efivars READ-ONLY, so any write
#      by any tool fails loudly (EROFS) instead of changing NVRAM;
#   4. the entries are compared before/after, and any change stops the script.
# The target boots through its ESP fallback (EFI/BOOT/BOOTX64.EFI -> fbx64.efi
# creates its own entry on first boot) or once via the firmware's boot menu.
EFIVARS=/sys/firmware/efi/efivars
CTR=(podman run --rm --privileged --pid=host --ipc=host
     -v /var/lib/containers:/var/lib/containers    # REQUIRED: bootc reads its own image from there
     -v /dev:/dev
     -v "$MOUNT_ROOT:/target"
     --security-opt label=type:unconfined_t)
EFI_BEFORE=""
if [[ -d "$EFIVARS" ]]; then
    CTR+=(--mount "type=bind,src=$EFIVARS,dst=$EFIVARS,ro=true")
    EFI_BEFORE=$(mktemp /var/tmp/efibootmgr-before.XXXXXX); efibootmgr -v > "$EFI_BEFORE" 2>/dev/null || true
fi
# Inside each container: refuse to start unless efivars really is read-only.
RO_GUARD='if [ -d /sys/firmware/efi/efivars ] && ! findmnt -no OPTIONS /sys/firmware/efi/efivars | tr , "\n" | grep -qx ro; then echo "efivars is writable in the installer container — refusing" >&2; exit 97; fi; exec "$@"'

log "bootc install to-filesystem (no bootloader step; firmware read-only)"
"${CTR[@]}" "$IMAGE" bash -c "$RO_GUARD" _ \
    bootc install to-filesystem \
        --target-imgref "$TARGET_IMGREF" \
        --bootloader none \
        --boot-mount-spec "UUID=$BOOT_UUID" \
        "${KARGS[@]}" \
        "${FINALIZE[@]}" \
        /target

log "Bootloader files: bootupd, EFI only, no firmware update"
"${CTR[@]}" "$IMAGE" bash -c "$RO_GUARD" _ \
    bootupctl backend install --write-uuid --component EFI --device "/dev/$TARGET_DISK" /target
for f in efi/EFI/BOOT/BOOTX64.EFI efi/EFI/BOOT/fbx64.efi efi/EFI/fedora/shimx64.efi efi/EFI/fedora/grubx64.efi \
         efi/EFI/fedora/grub.cfg grub2/grub.cfg bootupd-state.json; do
    [[ -s "$MOUNT_ROOT/boot/$f" ]] || die "bootloader incomplete: /boot/$f missing on the target"
done
info "ESP: shim + grub + EFI/BOOT fallback present; /boot/grub2/grub.cfg present"

# ─── 7b. Prove the firmware was not touched ────────────────────────────
if [[ -n "$EFI_BEFORE" ]]; then
    EFI_AFTER=$(mktemp /var/tmp/efibootmgr-after.XXXXXX); efibootmgr -v > "$EFI_AFTER" 2>/dev/null || true
    efi_entries() { grep -E '^Boot[0-9A-F]{4}\*? |^BootOrder' "$1" | sort; }
    if ! diff -q <(efi_entries "$EFI_BEFORE") <(efi_entries "$EFI_AFTER") >/dev/null; then
        diff <(efi_entries "$EFI_BEFORE") <(efi_entries "$EFI_AFTER") | sed 's/^/    /' || true
        die "the firmware boot entries CHANGED during the install — must not happen. Before-state: $EFI_BEFORE"
    fi
    rm -f "$EFI_AFTER" "$EFI_BEFORE"
    info "firmware boot entries: unchanged (verified; efivars was read-only)"
fi

# ─── 8. crypttab + swap in the new deployment ──────────────────────────
log "Writing crypttab / fstab into the deployment"
# Exactly $MOUNT_ROOT/ostree/deploy/<stateroot>/deploy/<csum>.<serial>. The old
# find -path '*/deploy/*.0' also matched ostree's root-only backing/<csum>.0
# directory, which it listed first — hence a false "no deployment found".
shopt -s nullglob; deploys=("$MOUNT_ROOT"/ostree/deploy/*/deploy/*.0); shopt -u nullglob
[[ ${#deploys[@]} -eq 1 ]] || die "expected exactly one deployment under $MOUNT_ROOT/ostree/deploy/*/deploy/, found ${#deploys[@]}: ${deploys[*]:-none}"
DEPLOY="${deploys[0]}"
[[ -d "$DEPLOY/etc" ]] || die "$DEPLOY has no etc/ — bootc did not finish"
STATEROOT=$(dirname "$(dirname "$DEPLOY")")       # its var/ is the booted system's /var
info "deployment: ${DEPLOY#"$MOUNT_ROOT"}"

{
    echo "luks-$ROOT_LUKS_UUID UUID=$ROOT_LUKS_UUID none discard"
    [[ -n "$SWAP_LUKS_UUID" ]] && echo "luks-$SWAP_LUKS_UUID UUID=$SWAP_LUKS_UUID none discard"
} > "$DEPLOY/etc/crypttab"
chmod 0600 "$DEPLOY/etc/crypttab"

touch "$DEPLOY/etc/fstab"
grep -q " /boot " "$DEPLOY/etc/fstab" || \
    echo "UUID=$BOOT_UUID /boot ext4 defaults 1 2" >> "$DEPLOY/etc/fstab"
grep -q " /boot/efi " "$DEPLOY/etc/fstab" || \
    echo "UUID=$EFI_UUID /boot/efi vfat umask=0077,shortname=winnt 0 2" >> "$DEPLOY/etc/fstab"
if [[ -n "$SWAP_DM" ]] && ! grep -q "luks-$SWAP_LUKS_UUID" "$DEPLOY/etc/fstab"; then
    echo "$SWAP_DM none swap defaults,x-systemd.device-timeout=0 0 0" >> "$DEPLOY/etc/fstab"
fi
info "crypttab:"; sed 's/^/      /' "$DEPLOY/etc/crypttab"
info "fstab:";    sed 's/^/      /' "$DEPLOY/etc/fstab"

# Keep a copy of the target definition with the OS for the next reinstall.
mkdir -p "$DEPLOY/etc/fedora-cosmic-atomic"
cp "$ENV_FILE" "$DEPLOY/etc/fedora-cosmic-atomic/install-target.env"
chmod 0644 "$DEPLOY/etc/fedora-cosmic-atomic/install-target.env"   # UUIDs only; user-level scripts read TEST_INSTALL
# Site values for post-install-setup.sh and the other shipped scripts; must
# exist before first boot (post-install runs before chezmoi brings anything).
cp "$SITE_FILE" "$DEPLOY/etc/fedora-cosmic-atomic/site.env"
chmod 0644 "$DEPLOY/etc/fedora-cosmic-atomic/site.env"

# Hostname. restic groups snapshots (parent, forget/prune) by host, so a test
# install gets "<name>-test": its backups never mix with the real machine's.
if [[ -n "${SITE_HOSTNAME:-}" ]]; then
    NEW_HOSTNAME="$SITE_HOSTNAME"
    [[ "${TEST_INSTALL:-0}" == 1 ]] && NEW_HOSTNAME="$SITE_HOSTNAME-test"
    echo "$NEW_HOSTNAME" > "$DEPLOY/etc/hostname"
    info "hostname: $NEW_HOSTNAME"
fi

# ─── 9. User account ───────────────────────────────────────────────────
# bootc install creates NO users (Anaconda would have). Create the login user
# and set root's password directly in the new deployment.
CREATE_USER="${CREATE_USER:-${SITE_USER:?SITE_USER not set in $SITE_FILE}}"
CREATE_USER_UID="${CREATE_USER_UID:-${SITE_UID:-1000}}"
if [[ -n "$CREATE_USER" ]] && ! grep -q "^$CREATE_USER:" "$DEPLOY/etc/passwd"; then
    log "Creating user $CREATE_USER (uid $CREATE_USER_UID) and setting passwords"
    groups="wheel"
    grep -q '^libvirt:' "$DEPLOY/etc/group" && groups="$groups,libvirt"
    useradd --root "$DEPLOY" --uid "$CREATE_USER_UID" --user-group --groups "$groups" \
            --shell /bin/bash --no-create-home --home-dir "/var/home/$CREATE_USER" "$CREATE_USER"
    mkdir -p "$STATEROOT/var/home/$CREATE_USER"
    cp -a "$DEPLOY/etc/skel/." "$STATEROOT/var/home/$CREATE_USER/"
    chown -R "$CREATE_USER_UID:$CREATE_USER_UID" "$STATEROOT/var/home/$CREATE_USER"
    chmod 0700 "$STATEROOT/var/home/$CREATE_USER"

    # SELinux labels for the new home (the booted system cannot relabel a home it
    # cannot log into). Best effort with the image's own file_contexts.
    fc="$DEPLOY/etc/selinux/targeted/contexts/files/file_contexts"
    if command -v setfiles >/dev/null && [[ -f "$fc" ]]; then
        setfiles -F -r "$STATEROOT" "$fc" "$STATEROOT/var/home" 2>/dev/null \
            && info "home directory labelled" || info "setfiles failed — run 'sudo restorecon -R /var/home' after first login"
    fi

    if [[ "$ASSUME_YES" == 1 && -n "${USER_PASSWORD:-}" ]]; then
        pw="$USER_PASSWORD"
    else
        while :; do
            read -rsp "Password for $CREATE_USER (also used for root): " pw; echo
            read -rsp "Repeat: " pw2; echo
            [[ "$pw" == "$pw2" && -n "$pw" ]] && break
            echo "  mismatch or empty, try again"
        done
    fi
    # Not chpasswd --root: on an SELinux host it runs as passwd_t, which may not
    # write the target's /etc (labelled etc_t until the relabel below) — install
    # run 5 died there. Hash from stdin (never in argv), then set the shadow
    # fields in place (same inode/mode); the hash travels via the environment.
    HASH_USER=$(printf '%s' "$pw" | openssl passwd -6 -stdin)   # separate salts
    HASH_ROOT=$(printf '%s' "$pw" | openssl passwd -6 -stdin)
    unset pw pw2
    [[ "$HASH_USER" == '$6$'* && "$HASH_ROOT" == '$6$'* ]] || die "could not hash the password (openssl passwd -6)"
    export HASH_USER HASH_ROOT
    tmp=$(mktemp -p /run install-shadow.XXXXXX)
    awk -F: -v OFS=: -v u="$CREATE_USER" -v d="$(( $(date +%s) / 86400 ))" '
        $1 == u      { $2 = ENVIRON["HASH_USER"]; $3 = d }
        $1 == "root" { $2 = ENVIRON["HASH_ROOT"]; $3 = d }
        { print }' "$DEPLOY/etc/shadow" > "$tmp"
    unset HASH_USER HASH_ROOT
    [[ $(awk -F: -v u="$CREATE_USER" '($1 == u || $1 == "root") && $2 ~ /^\$6\$/' "$tmp" | wc -l) -eq 2 ]] \
        || { rm -f "$tmp"; die "shadow update failed: $CREATE_USER/root not both set"; }
    cat "$tmp" > "$DEPLOY/etc/shadow"; rm -f "$tmp"
    info "user $CREATE_USER created (groups: $groups); root password set to the same value"
fi

# SELinux labels for everything written into the new /etc (passwd, shadow,
# group, crypttab, fstab, hostname, site.env …): the host's policy labelled
# them etc_t, and a booted system with /etc/shadow as etc_t cannot change
# passwords. Relabel with the IMAGE's file_contexts, then check the two that matter.
fc="$DEPLOY/etc/selinux/targeted/contexts/files/file_contexts"
if command -v setfiles >/dev/null && [[ -f "$fc" ]]; then
    setfiles -F -r "$DEPLOY" "$fc" "$DEPLOY/etc" 2>/dev/null || true
    for f in passwd:passwd_file_t shadow:shadow_t; do
        t=$(stat -c %C "$DEPLOY/etc/${f%%:*}" | cut -d: -f3)
        [[ "$t" == "${f##*:}" ]] || die "/etc/${f%%:*} in the new system is labelled $t, not ${f##*:} — after first boot run: sudo restorecon -RF /etc"
    done
    info "/etc labelled (passwd_file_t, shadow_t verified)"
else
    info "no setfiles/file_contexts — after first boot run: sudo restorecon -RF /etc"
fi

# ─── 10. Done ──────────────────────────────────────────────────────────
log "Unmounting"
sync
umount -R "$MOUNT_ROOT"

cat <<EOF

=== Installation complete on /dev/$TARGET_DISK ===
The firmware's boot entries were not changed. The new disk boots through its
ESP fallback loader (EFI/BOOT/BOOTX64.EFI); if the firmware does not list it,
pick the disk once in the boot menu (F12) — shim then creates its own entry.

Next:
  1. Target on USB (the test drive): check efibootmgr and the ESP fallback
     loader (docs/migration-guide.md Phase 3), power off, swap the disk into
     the NVMe slot, power on. F12 only if the firmware doesn't pick it up.
     Target internal: just reboot.
     Secure Boot must be OFF (hibernation needs it off; the image is not
     shim-signed for a custom key either).
  2. Enter the LUKS passphrase (once if root and swap share it).
  3. Log in as $CREATE_USER, then:  sudo post-install-setup.sh
  4. See docs/migration-guide.md for the validation checklist.

Rollback: the previous OS disk is untouched — put it back in the NVMe slot
(or boot it from USB via F12).
EOF
