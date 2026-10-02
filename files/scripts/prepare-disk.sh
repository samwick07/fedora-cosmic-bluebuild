#!/usr/bin/env bash
#
# prepare-disk.sh — turn a blank (or explicitly wiped) disk into the layout
# install-atomic.sh expects. For a new or replacement NVMe.
#
#   sudo prepare-disk.sh /dev/disk/by-id/nvme-<model>_<serial>   # real disk (by-id: never a guessed letter)
#   sudo prepare-disk.sh --dry-run /dev/disk/by-id/...           # print every command, change nothing
#   sudo prepare-disk.sh --selftest                              # whole run on a throwaway loop device
#
# Layout (GPT), same as the Anaconda layout the other scripts were built for:
#   p1  600 MiB    vfat  "EFI"        EFI system partition
#   p2  2 GiB      ext4  "boot"       /boot (BLS entries, kernels)
#   p3  SWAP_GB    LUKS2 -> swap      hibernation target (>= RAM)
#   p4  rest       LUKS2              root (install-atomic.sh puts btrfs in it)
# One passphrase for both containers (asked twice, once to confirm).
#
# Then:  sudo make-target-env.sh <disk> > new-disk.env  &&  sudo install-atomic.sh new-disk.env
#
# Guards: refuses the disk the running system is on and any disk holding a
# PROTECTED_LUKS_UUIDS container (site.env); a disk with ANY partition or
# signature is only wiped after you type "WIPE <name>".
#
set -euo pipefail

DRY=0; SELFTEST=0
case "${1:-}" in
    --dry-run)  DRY=1; shift ;;
    --selftest) SELFTEST=1; shift ;;
esac

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
run()  { if [[ "$DRY" == 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi; }

[[ $EUID -eq 0 ]] || die "run with sudo"
for c in sgdisk wipefs cryptsetup mkfs.vfat mkfs.ext4 mkswap lsblk blkid partprobe udevadm; do
    command -v "$c" >/dev/null || die "missing command: $c"
done

# shellcheck disable=SC1090
for f in "${SITE_FILE:-}" "$(dirname "$0")/targets/site.env" /etc/fedora-cosmic-atomic/site.env; do
    [[ -n "$f" && -f "$f" ]] && { source "$f"; break; }
done
SWAP_GB="${SWAP_GB:-$(awk '/MemTotal/ {printf "%d", ($2/1048576)+1}' /proc/meminfo)}"
PROTECTED_LUKS_UUIDS="${PROTECTED_LUKS_UUIDS:-}"

disk_of() {  # same as install-atomic.sh: any block device -> its one whole disk
    local disks
    disks=$(lsblk -snro NAME,TYPE "$(readlink -f "$1")" | awk '$2=="disk"||$2=="loop"{print $1}' | sort -u)
    [[ $(wc -l <<<"$disks") -eq 1 && -n "$disks" ]] || die "cannot resolve the disk of $1"
    echo "$disks"
}
part() { [[ "$1" =~ [0-9]$ ]] && echo "${1}p$2" || echo "${1}$2"; }   # nvme0n1p1 / sdb1 / loop0p1

# ─── Self-test: everything on a sparse file, then check make-target-env's view ──
if [[ "$SELFTEST" == 1 ]]; then
    img=$(mktemp /var/tmp/prepare-disk-selftest.XXXXXX); truncate -s 20G "$img"
    loop=$(losetup -fP --show "$img")
    trap 'cryptsetup close selftest-check 2>/dev/null || true; losetup -d "$loop" 2>/dev/null; rm -f "$img"' EXIT
    log "Self-test on $loop (20 GiB sparse file, swap 2 GiB, passphrase 'selftest')"
    SELFTEST_PASS=selftest SWAP_GB=2 PREPARE_DISK_ASSUME_YES=1 ALLOW_LOOP=1 "$0" "$loop"
    log "Checking the result"
    env_out=$(ALLOW_LOOP=1 "$(dirname "$0")/make-target-env.sh" "$loop")
    echo "$env_out" | grep -E '^(EFI|BOOT|ROOT_LUKS|SWAP_LUKS)_UUID=' | sed 's/^/    /'
    # shellcheck disable=SC1090
    source <(echo "$env_out" | grep -E '^(EFI|BOOT|ROOT_LUKS|SWAP_LUKS)_UUID=')
    [[ $(blkid -s TYPE -o value "/dev/disk/by-uuid/$EFI_UUID") == vfat ]]          || die "ESP is not vfat"
    [[ $(blkid -s TYPE -o value "/dev/disk/by-uuid/$BOOT_UUID") == ext4 ]]         || die "/boot is not ext4"
    [[ $(blkid -s TYPE -o value "/dev/disk/by-uuid/$ROOT_LUKS_UUID") == crypto_LUKS ]] || die "root is not LUKS"
    printf 'selftest' | cryptsetup open --key-file=- "/dev/disk/by-uuid/$SWAP_LUKS_UUID" selftest-check
    [[ $(blkid -s TYPE -o value /dev/mapper/selftest-check) == swap ]] || die "swap container holds no swap"
    cryptsetup close selftest-check
    [[ $(lsblk -bdno SIZE "/dev/disk/by-uuid/$SWAP_LUKS_UUID") -lt $(lsblk -bdno SIZE "/dev/disk/by-uuid/$ROOT_LUKS_UUID") ]] \
        || die "swap is not the smaller LUKS (make-target-env.sh would swap them)"
    log "SELF-TEST PASSED — prepare-disk.sh + make-target-env.sh agree on the layout"
    exit 0
fi

# ─── Target ────────────────────────────────────────────────────────────
target="${1:?usage: prepare-disk.sh [--dry-run|--selftest] /dev/disk/by-id/<disk>}"
disk=$(readlink -f "$target")
[[ -b "$disk" ]] || die "$target is not a block device"
type=$(lsblk -dno TYPE "$disk")
[[ "$type" == disk || ( "$type" == loop && "${ALLOW_LOOP:-0}" == 1 ) ]] || die "$disk is a $type, not a whole disk"
name=$(basename "$disk")
model=$(lsblk -dno MODEL,SERIAL,SIZE "$disk" | tr -s ' ')

log "Target: $disk ($model)"
size_gib=$(( $(lsblk -bdno SIZE "$disk") / 1073741824 ))
(( size_gib >= SWAP_GB + 3 + 16 )) || die "$disk is ${size_gib} GiB — too small for ${SWAP_GB} GiB swap + boot + a root"
info "swap ${SWAP_GB} GiB, root ~$(( size_gib - SWAP_GB - 3 )) GiB"

# ─── Guards ────────────────────────────────────────────────────────────
log "Safety checks"
running=$(disk_of "$(findmnt -no SOURCE / | sed 's/\[.*\]//')")
[[ "$running" != "$name" ]] || die "$disk is the disk this system is running from — refusing"
info "running system is on /dev/$running (ok)"
for u in $PROTECTED_LUKS_UUIDS; do
    [[ -e "/dev/disk/by-uuid/$u" ]] || continue
    [[ $(disk_of "/dev/disk/by-uuid/$u") != "$name" ]] || die "protected LUKS $u is on $disk — refusing"
done
info "no protected container on $disk (ok)"
# Mountpoints of the disk, its partitions and anything stacked on them (LUKS).
if lsblk -nro MOUNTPOINTS "$disk" | grep -q .; then
    die "something on $disk is mounted or in use as swap — unmount/close it first"
fi

existing=$(lsblk -no NAME,FSTYPE,SIZE,LABEL "$disk")
sigs=$(wipefs -n "$disk" 2>/dev/null | tail -n +2 || true)
if [[ $(lsblk -nro NAME "$disk" | wc -l) -gt 1 || -n "$sigs" ]]; then
    log "$disk is NOT blank:"
    echo "$existing" | sed 's/^/    /'
    if [[ "${PREPARE_DISK_ASSUME_YES:-0}" != 1 ]]; then
        printf '\nEverything above will be destroyed. Type "WIPE %s" to continue: ' "$name"
        read -r answer
        [[ "$answer" == "WIPE $name" ]] || die "aborted"
    fi
else
    info "disk is blank"
    if [[ "${PREPARE_DISK_ASSUME_YES:-0}" != 1 ]]; then
        printf '\nPartition and encrypt %s? Type "%s" to continue: ' "$disk" "$name"
        read -r answer
        [[ "$answer" == "$name" ]] || die "aborted"
    fi
fi

# ─── Passphrase (once, used for both containers) ───────────────────────
if [[ -n "${SELFTEST_PASS:-}" ]]; then pass="$SELFTEST_PASS"
elif [[ "$DRY" == 1 ]]; then pass=dry-run
else
    while :; do
        read -rsp "LUKS passphrase for root + swap: " pass; echo
        read -rsp "Repeat: " pass2; echo
        [[ "$pass" == "$pass2" && ${#pass} -ge 8 ]] && break
        echo "  mismatch or shorter than 8 characters, try again"
    done
    unset pass2
fi

# ─── Partition ─────────────────────────────────────────────────────────
log "Wiping signatures and writing the GPT"
for p in $(lsblk -nrpo NAME "$disk" | tail -n +2 | sort -r); do run wipefs -aq "$p"; done
run wipefs -aq "$disk"
run sgdisk --zap-all "$disk" >/dev/null
run sgdisk -n1:0:+600M      -t1:EF00 -c1:"EFI System" \
           -n2:0:+2G        -t2:8300 -c2:"boot" \
           -n3:0:+"${SWAP_GB}G" -t3:8309 -c3:"swap (LUKS)" \
           -n4:0:0          -t4:8309 -c4:"root (LUKS)" "$disk" >/dev/null
run partprobe "$disk"; run udevadm settle
P1=$(part "$disk" 1); P2=$(part "$disk" 2); P3=$(part "$disk" 3); P4=$(part "$disk" 4)
[[ "$DRY" == 1 ]] || for p in "$P1" "$P2" "$P3" "$P4"; do [[ -b "$p" ]] || die "partition $p did not appear"; done

log "Filesystems and LUKS"
run mkfs.vfat -F32 -n EFI "$P1" >/dev/null
run mkfs.ext4 -q -L boot "$P2"
for p in "$P3" "$P4"; do
    if [[ "$DRY" == 1 ]]; then info "[dry-run] cryptsetup luksFormat --type luks2 $p"
    else printf '%s' "$pass" | cryptsetup luksFormat -q --type luks2 --key-file=- "$p"; fi
done
# Swap signature inside the swap container. With KEEP_OPEN=1 (install-to-disk.sh)
# both containers stay open as luks-<UUID>, the names install-atomic.sh uses,
# so the passphrase is not asked again.
if [[ "$DRY" == 1 ]]; then info "[dry-run] open $P3, mkswap -L fedora_swap${KEEP_OPEN:+, keep open}"
else
    run udevadm settle
    swap_uuid=$(cryptsetup luksUUID "$P3"); root_uuid=$(cryptsetup luksUUID "$P4")
    printf '%s' "$pass" | cryptsetup open --key-file=- "$P3" "luks-$swap_uuid"
    mkswap -q -L fedora_swap "/dev/mapper/luks-$swap_uuid"
    if [[ "${KEEP_OPEN:-0}" == 1 ]]; then
        printf '%s' "$pass" | cryptsetup open --key-file=- "$P4" "luks-$root_uuid"
        info "containers left open for install-atomic.sh"
    else
        cryptsetup close "luks-$swap_uuid"
    fi
fi
unset pass
run udevadm settle

log "Done"
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$disk" | sed 's/^/    /'
cat <<EOF

Next:
  sudo make-target-env.sh $target > new-disk.env     # review it; set TEST_INSTALL / SKIP_FINALIZE
  sudo install-atomic.sh new-disk.env
EOF
