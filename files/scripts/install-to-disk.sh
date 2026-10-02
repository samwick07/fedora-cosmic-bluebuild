#!/usr/bin/env bash
#
# install-to-disk.sh — one command from "a disk" to "an installed system".
# Checks the disk first, then runs prepare-disk.sh (only if needed),
# make-target-env.sh and install-atomic.sh.
#
#   install-to-disk.sh --check /dev/disk/by-id/<disk>       # verdict only: no changes, no root needed
#   sudo install-to-disk.sh [--test] /dev/disk/by-id/<disk> # --test: TEST_INSTALL=1 (hostname <name>-test,
#                                                           #   Syncthing stays off)
#
# What it does with each kind of disk:
#   new / blank            prepares it (asks the new LUKS passphrase once) and installs, no further questions
#   contains data          says what is on it, offers to erase it (type WIPE <name>), then prepares + installs
#   already configured     says so; reinstalling reformats only the root filesystem (install-atomic.sh asks)
#   running / protected    refuses
#
# Shipped in the image as /usr/bin/install-to-disk.sh; in the repo as scripts/install-to-disk.sh.
#
set -euo pipefail

CHECK=0; TEST=0
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --check) CHECK=1 ;;
        --test)  TEST=1 ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift
done
target="${1:?usage: install-to-disk.sh [--check] [--test] /dev/disk/by-id/<disk>}"
HERE="$(dirname "$0")"                 # unresolved: scripts/ in the repo, /usr/bin in the image

say()  { printf '%s\n' "$*"; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ─── Site values ───────────────────────────────────────────────────────
if [[ -z "${SITE_FILE:-}" ]]; then
    for SITE_FILE in "$HERE/targets/site.env" "$PWD/scripts/targets/site.env" /etc/fedora-cosmic-atomic/site.env; do
        [[ -f "$SITE_FILE" ]] && break
    done
fi
[[ -f "$SITE_FILE" ]] || die "no site.env (repo scripts/targets/ or /etc/fedora-cosmic-atomic/); template: site.example.env"
export SITE_FILE
# shellcheck disable=SC1090
source "$SITE_FILE"
IMAGE="${IMAGE:-ghcr.io/samwick07/fedora-cosmic-frmwrk:latest}"

# ─── The disk ──────────────────────────────────────────────────────────
disk=$(readlink -f "$target")
[[ -b "$disk" ]] || die "$target is not a block device"
[[ $(lsblk -dno TYPE "$disk") == disk ]] || die "$disk is a $(lsblk -dno TYPE "$disk"), not a whole disk — give the disk, not a partition"
name=$(basename "$disk")
tran=$(lsblk -dno TRAN "$disk" | tr -d ' '); size=$(lsblk -dno SIZE "$disk" | tr -d ' '); model=$(lsblk -dno MODEL "$disk" | sed 's/ *$//')
head1 "Disk: $disk — ${model:-unknown model}, $size, ${tran:-internal}"

disk_of() { lsblk -snro NAME,TYPE "$(readlink -f "$1")" | awk '$2=="disk"{print $1}' | sort -u; }

# ─── Verdict ───────────────────────────────────────────────────────────
verdict=""; why=()
running=$(disk_of "$(findmnt -no SOURCE / | sed 's/\[.*\]//')")
if [[ "$running" == "$name" ]]; then
    verdict=refuse; why+=("this is the disk the running system is on")
fi
for u in ${PROTECTED_LUKS_UUIDS:-}; do
    if [[ -e "/dev/disk/by-uuid/$u" && $(disk_of "/dev/disk/by-uuid/$u") == "$name" ]]; then
        verdict=refuse; why+=("it holds protected LUKS container $u (PROTECTED_LUKS_UUIDS in $SITE_FILE)")
    fi
done

# "|"-separated so empty fields (a partition without filesystem) keep their place.
parts=$(lsblk -nrpo NAME,TYPE,FSTYPE,SIZE,LABEL "$disk" | awk -F'[ ]' '$2=="part"{print $1"|"$2"|"$3"|"$4"|"$5}')
nparts=$(grep -c . <<<"$parts" || true)
count() { awk -F'|' -v t="$1" '$3==t' <<<"$parts" | grep -c . || true; }
nvfat=$(count vfat); next4=$(count ext4); nluks=$(count crypto_LUKS)
mounted=$(lsblk -nro MOUNTPOINTS "$disk" | grep . || true)
pttype=$(lsblk -dno PTTYPE "$disk")
whole_fs=$(lsblk -dno FSTYPE "$disk")

if [[ -z "$verdict" ]]; then
    if [[ "$nparts" -eq 0 && -z "$whole_fs" ]]; then
        verdict=blank
    elif [[ "$nparts" -ge 3 && "$nparts" -eq $((nvfat + next4 + nluks)) && "$nvfat" -eq 1 && "$next4" -eq 1 && "$nluks" -ge 1 && "$nluks" -le 2 ]]; then
        verdict=configured
    else
        verdict=data
    fi
fi

describe() {  # one line per partition, in words
    local n f s l what
    while IFS='|' read -r n _ f s l; do
        [[ -n "$n" ]] || continue
        case "$f" in
            ntfs)         what="NTFS — Windows or a Windows data drive" ;;
            vfat|exfat)   what="$f — an EFI partition or a USB-style data partition" ;;
            crypto_LUKS)  what="LUKS — encrypted; contents unknown without its passphrase" ;;
            btrfs|ext4|xfs|ext3|ext2) what="$f — a Linux filesystem" ;;
            swap)         what="swap" ;;
            "")           what="no recognisable filesystem (raw, unformatted or unknown)" ;;
            *)            what="$f" ;;
        esac
        printf '    %-16s %8s  %s%s\n' "$(basename "$n")" "$s" "$what" "${l:+  (label: $l)}"
    done <<<"$parts"
}

case "$verdict" in
    refuse)
        say "REFUSED:"; printf '  - %s\n' "${why[@]}"
        say "Reinstalling a protected disk on purpose (e.g. the final 4TB run) is a manual step:"
        say "docs/migration-guide.md Phase 5 — make-target-env.sh, remove its UUIDs from PROTECTED_LUKS_UUIDS, install-atomic.sh."
        exit 1 ;;
    blank)
        say "New / blank: ${pttype:+an empty $pttype partition table, }no partitions, nothing to lose."
        say "Plan: prepare it (ESP, /boot, LUKS swap ${SWAP_GB:-?} GiB, LUKS root), then install." ;;
    configured)
        say "Already configured for this system (EFI + /boot + $nluks LUKS container(s)):"
        describe
        say "Plan: install into it. The ESP, /boot and the LUKS containers (and their passphrase) are kept;"
        say "      the root filesystem inside the LUKS root is REFORMATTED — anything on it is lost."
        say "      install-atomic.sh shows a summary and asks you to type the disk name." ;;
    data)
        say "This disk CONTAINS DATA and does not match the expected layout:"
        if [[ -n "$whole_fs" ]]; then say "    whole disk: $whole_fs filesystem directly on the disk (no partition table)"; fi
        describe
        if [[ -n "$mounted" ]]; then say "  Mounted right now: $(tr '\n' ' ' <<<"$mounted")— unmount it first."; fi
        say "Option: erase EVERYTHING on it and prepare it for this system (you will be asked to type WIPE $name)."
        say "If any of it matters, copy it off first and run this again." ;;
esac
if [[ "$CHECK" == 1 ]]; then exit 0; fi

# ─── From here on: changes ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "run with sudo (or use --check)"
if [[ "$verdict" == data && -n "$mounted" ]]; then die "unmount everything on $disk first"; fi

# The image must be available BEFORE anything is erased.
if ! podman image exists "$IMAGE" && ! { [[ -n "${SUDO_USER:-}" ]] && sudo -u "$SUDO_USER" podman image exists "$IMAGE"; }; then
    die "image $IMAGE is not in root's or ${SUDO_USER:-your} podman storage — 'podman pull $IMAGE' (and cosign verify) first"
fi

install_opts=()
case "$verdict" in
    blank)
        KEEP_OPEN=1 PREPARE_DISK_ASSUME_YES=1 "$HERE/prepare-disk.sh" "$target"
        install_opts=(--yes) ;;              # nothing existed on the disk: no second confirmation
    data)
        printf '\nType "WIPE %s" to erase it and continue (anything else aborts): ' "$name"
        read -r answer
        [[ "$answer" == "WIPE $name" ]] || die "aborted — nothing was changed"
        KEEP_OPEN=1 PREPARE_DISK_ASSUME_YES=1 "$HERE/prepare-disk.sh" "$target"
        install_opts=(--yes) ;;              # already confirmed above
    configured) ;;                           # install-atomic.sh asks before reformatting root
esac

# ─── Target file ───────────────────────────────────────────────────────
targets_dir="$(dirname "$SITE_FILE")"
if [[ "$targets_dir" == /etc/* ]]; then targets_dir=/var/lib/fedora-cosmic-atomic/targets; fi
mkdir -p "$targets_dir"
envfile="$targets_dir/auto-$name.env"
"$HERE/make-target-env.sh" "$target" > "$envfile"
{
    echo "TEST_INSTALL=$TEST"
    if [[ "$tran" == usb ]]; then echo "SKIP_FINALIZE=1"; else echo "SKIP_FINALIZE=0"; fi
    echo "IMAGE=\"$IMAGE\""
} >> "$envfile"                               # later lines override the generated defaults
head1 "Target file: $envfile"
grep -E '^(TARGET_NAME|EFI_UUID|BOOT_UUID|ROOT_LUKS_UUID|SWAP_LUKS_UUID|TEST_INSTALL|SKIP_FINALIZE|IMAGE)=' "$envfile" | sed 's/^/    /'

exec "$HERE/install-atomic.sh" "$envfile" "${install_opts[@]}"
