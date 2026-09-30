#!/usr/bin/env bash
#
# install-atomic.sh — Install the BlueBuild Fedora Cosmic Atomic image onto a
# pre-partitioned, LUKS-encrypted disk with `bootc install to-filesystem`.
#
# Usage:
#   sudo scripts/install-atomic.sh scripts/targets/<name>.env [--yes]
#
# The .env (generate it with scripts/make-target-env.sh) names the target by
# UUID only. Device letters (/dev/sdb, /dev/nvme1n1) are never trusted: they
# change with what is plugged in.
#
# What it does
#   1. Resolves every partition by UUID and proves all of them sit on ONE disk.
#   2. Refuses if any PROTECTED_LUKS_UUIDS (the 4TB Workstation, the DAS) or the
#      disk the running system booted from is that disk.
#   3. Unlocks the LUKS containers if needed, unmounts anything mounted from them.
#   4. Shows a summary and waits for you to type the disk name.
#   5. mkfs.btrfs the root container (the ESP, /boot and swap are kept as-is),
#      mounts root -> /boot -> /boot/efi in that order.
#   6. Copies the image into root's podman storage if only your user has it.
#   7. Runs bootc install to-filesystem with GRUB, the separate /boot, and the
#      LUKS + resume kernel arguments.
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

disk_of() {  # any block device (partition or dm) -> its whole-disk name, e.g. nvme0n1
    local dev="$1" type pk
    dev=$(readlink -f "$dev")
    while :; do
        type=$(lsblk -dno TYPE "$dev")
        [[ "$type" == "disk" ]] && { basename "$dev"; return; }
        pk=$(lsblk -dno PKNAME "$dev" | head -1)
        [[ -n "$pk" ]] || die "cannot find parent disk of $dev"
        dev="/dev/$pk"
    done
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

# ─── 4. Confirm ────────────────────────────────────────────────────────
log "About to install"
cat <<EOF
    Disk            /dev/$TARGET_DISK  (will NOT be repartitioned)
    ESP             $EFI_PART   UUID=$EFI_UUID        kept
    /boot           $BOOT_PART   UUID=$BOOT_UUID       kept (bootc writes kernels + grub.cfg here)
    root LUKS       $ROOT_LUKS_PART  -> $ROOT_DM     *** btrfs WILL BE REFORMATTED ***
    swap LUKS       ${SWAP_LUKS_PART:-none}  ${SWAP_DM:+-> $SWAP_DM (swap UUID $SWAP_FS_UUID)}
    Image           $IMAGE
    Updates from    $TARGET_IMGREF
    Bootloader      grub (BLS entries on /boot, shim+grub on the ESP)
    Finalize        $([[ "$SKIP_FINALIZE" == 1 ]] && echo "skipped (no fstrim — USB/DAS disk)" || echo "yes")
EOF
if [[ "$ASSUME_YES" != 1 ]]; then
    printf '\nType the disk name (%s) to continue: ' "$TARGET_DISK"
    read -r answer
    [[ "$answer" == "$TARGET_DISK" ]] || die "aborted"
fi

# ─── 5. Format root, mount in order ────────────────────────────────────
log "Formatting root and mounting"
mkfs.btrfs -f -L fedora_root "$ROOT_DM" >/dev/null
mkdir -p "$MOUNT_ROOT"
mount -o compress=zstd:1 "$ROOT_DM" "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT/boot"
mount "$BOOT_PART" "$MOUNT_ROOT/boot"
mkdir -p "$MOUNT_ROOT/boot/efi"
mount "$EFI_PART" "$MOUNT_ROOT/boot/efi"
findmnt -R "$MOUNT_ROOT" -o TARGET,SOURCE,FSTYPE

# ─── 6. Image in root podman storage ───────────────────────────────────
log "Checking image $IMAGE"
if ! podman image exists "$IMAGE"; then
    if [[ -n "${SUDO_USER:-}" ]] && sudo -u "$SUDO_USER" podman image exists "$IMAGE"; then
        info "copying from $SUDO_USER's podman storage (no download)"
        sudo -u "$SUDO_USER" podman save "$IMAGE" --format oci-archive | podman load
    else
        die "image $IMAGE not found. Build it: bluebuild build -B podman recipes/recipe-framework.yml"
    fi
fi
podman run --rm "$IMAGE" test -x /usr/bin/bootc || die "$IMAGE has no /usr/bin/bootc"
info "image id $(podman image inspect "$IMAGE" --format '{{.Id}}' | cut -c1-12)"

# ─── 7. bootc install ──────────────────────────────────────────────────
log "bootc install to-filesystem"
KARGS=(--karg "rd.luks.uuid=$ROOT_LUKS_UUID" --karg "rootflags=compress=zstd:1")
if [[ -n "$SWAP_LUKS_UUID" ]]; then
    KARGS+=(--karg "rd.luks.uuid=$SWAP_LUKS_UUID" --karg "resume=UUID=$SWAP_FS_UUID")
fi
FINALIZE=()
[[ "$SKIP_FINALIZE" == 1 ]] && FINALIZE=(--skip-finalize)

# -v /var/lib/containers is REQUIRED: bootc reads its own image from there.
podman run --rm --privileged --pid=host --ipc=host \
    -v /var/lib/containers:/var/lib/containers \
    -v /dev:/dev \
    -v "$MOUNT_ROOT:/target" \
    --security-opt label=type:unconfined_t \
    "$IMAGE" \
    bootc install to-filesystem \
        --target-imgref "$TARGET_IMGREF" \
        --bootloader grub \
        --boot-mount-spec "UUID=$BOOT_UUID" \
        "${KARGS[@]}" \
        "${FINALIZE[@]}" \
        /target

# ─── 8. crypttab + swap in the new deployment ──────────────────────────
log "Writing crypttab / fstab into the deployment"
DEPLOY=$(find "$MOUNT_ROOT/ostree/deploy" -maxdepth 4 -type d -path '*/deploy/*.0' | head -1)
[[ -n "$DEPLOY" && -d "$DEPLOY/etc" ]] || die "no deployment found under $MOUNT_ROOT/ostree/deploy — bootc did not finish"
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

# ─── 9. User account ───────────────────────────────────────────────────
# bootc install creates NO users (Anaconda would have). Create the login user
# and set root's password directly in the new deployment.
CREATE_USER="${CREATE_USER:-<user>}"
CREATE_USER_UID="${CREATE_USER_UID:-1000}"
STATEROOT="$MOUNT_ROOT/ostree/deploy/default"       # its var/ is the booted system's /var
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
    printf '%s:%s\n%s:%s\n' "$CREATE_USER" "$pw" root "$pw" | chpasswd --root "$DEPLOY"
    unset pw pw2
    info "user $CREATE_USER created (groups: $groups); root password set to the same value"
fi

# ─── 10. Done ──────────────────────────────────────────────────────────
log "Unmounting"
sync
umount -R "$MOUNT_ROOT"

cat <<EOF

=== Installation complete on /dev/$TARGET_DISK ===

Next:
  1. Reboot, open the firmware boot menu (Framework: F12), pick the target disk.
     Secure Boot must be OFF (hibernation needs it off; the image is not
     shim-signed for a custom key either).
  2. Enter the LUKS passphrase (once if root and swap share it).
  3. Log in as $CREATE_USER, then:  sudo post-install-setup.sh
  4. See docs/migration-guide.md for the validation checklist.

Rollback: the previous OS disk is untouched — pick it in the firmware menu.
EOF
