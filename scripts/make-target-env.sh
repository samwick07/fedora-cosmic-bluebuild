#!/usr/bin/env bash
#
# make-target-env.sh — Generate a target .env for install-atomic.sh from a disk.
#
# Reads the partition table of ONE disk and writes the UUIDs install-atomic.sh
# needs. It never writes to the disk. Review the output before using it.
#
# Expected layout on the disk (what Anaconda produces, and what both the 2TB
# test drive and the 4TB primary already have):
#   p1  vfat         EFI system partition        -> EFI_UUID
#   p2  ext4         /boot                       -> BOOT_UUID
#   p3  crypto_LUKS  swap (smaller LUKS)         -> SWAP_LUKS_UUID
#   p4  crypto_LUKS  btrfs root (larger LUKS)    -> ROOT_LUKS_UUID
#
# Usage:
#   sudo scripts/make-target-env.sh /dev/sdb  > scripts/targets/2tb-test.env
#   sudo scripts/make-target-env.sh /dev/nvme0n1 > scripts/targets/4tb-primary.env
#
set -euo pipefail

# Site values (protected disks, user) from scripts/targets/site.env.
site="${SITE_FILE:-$(dirname "$(readlink -f "$0")")/targets/site.env}"
[[ -f "$site" ]] || { echo "missing $site (copy scripts/targets/site.example.env)" >&2; exit 1; }
# shellcheck disable=SC1090
source "$site"

disk="${1:?usage: make-target-env.sh /dev/DISK}"
disk=$(readlink -f "$disk")
[[ -b "$disk" ]] || { echo "not a block device: $disk" >&2; exit 1; }
[[ $(lsblk -dno TYPE "$disk") == disk ]] || { echo "$disk is not a whole disk" >&2; exit 1; }

model=$(lsblk -dno MODEL,SIZE "$disk" | tr -s ' ')
name=$(basename "$disk")

efi=""; boot=""; luks=()
while IFS=' ' read -r path fstype size; do
    case "$fstype" in
        vfat)        efi="$path" ;;
        ext4)        boot="$path" ;;
        crypto_LUKS) luks+=("$size $path") ;;
    esac
done < <(lsblk -pnro PATH,FSTYPE,SIZE "$disk" | awk 'NF==3')

[[ -n "$efi" ]]  || { echo "no vfat (EFI) partition on $disk" >&2; exit 1; }
[[ -n "$boot" ]] || { echo "no ext4 (/boot) partition on $disk" >&2; exit 1; }
(( ${#luks[@]} >= 1 )) || { echo "no LUKS partition on $disk" >&2; exit 1; }

# Larger LUKS container = root, smaller = swap (absent if only one LUKS partition)
mapfile -t sorted < <(printf '%s\n' "${luks[@]}" | sort -h)
root_part=${sorted[-1]#* }
swap_part=""
(( ${#sorted[@]} >= 2 )) && swap_part=${sorted[0]#* }

uuid() { blkid -s UUID -o value "$1"; }

cat <<EOF
# install-atomic.sh target — generated $(date -Iseconds) from $disk ($model)
# Check every line against \`lsblk -o NAME,SIZE,FSTYPE,UUID $disk\` before use.
TARGET_NAME="$name"

EFI_UUID="$(uuid "$efi")"                # $efi  $(lsblk -dno SIZE "$efi")  vfat
BOOT_UUID="$(uuid "$boot")"              # $boot  $(lsblk -dno SIZE "$boot")  ext4
ROOT_LUKS_UUID="$(uuid "$root_part")"    # $root_part  $(lsblk -dno SIZE "$root_part")  LUKS -> btrfs /
SWAP_LUKS_UUID="${swap_part:+$(uuid "$swap_part")}"    # ${swap_part:-none}  ${swap_part:+$(lsblk -dno SIZE "$swap_part")}  LUKS -> swap (empty = no swap/hibernation)

# Image to install (must exist in root podman storage, or in \$SUDO_USER's — the
# script copies it across) and the registry ref the installed system pulls
# updates from.
IMAGE="ghcr.io/samwick07/fedora-cosmic-frmwrk:latest"   # the pushed, signed build (also in local podman storage)
TARGET_IMGREF="ghcr.io/samwick07/fedora-cosmic-frmwrk:latest"

# LUKS UUIDs that must NEVER be on the target disk (from site.env: the current
# OS root + swap, and the DAS). install-atomic.sh refuses to run if any of them
# lives on the target disk. For the final run onto the current OS disk you must
# therefore edit this line by hand and remove that disk's UUIDs — that friction
# is the point. Add the test drive's ROOT_LUKS_UUID here at the same time.
PROTECTED_LUKS_UUIDS="$PROTECTED_LUKS_UUIDS"

# Login user to create in the new system (bootc install creates none).
CREATE_USER="$SITE_USER"
CREATE_USER_UID=${SITE_UID:-1000}

# 1 = this is a TEST install (the 2TB drive): Syncthing is never enabled
# automatically; scripts/test/syncthing-2tb-check.sh does a paused-only
# connection test instead. Set 0 for the real 4TB install.
TEST_INSTALL=1

# 1 = skip fstrim/readonly-remount (needed on USB/DAS-attached disks that
# reject TRIM). 0 for the internal NVMe.
SKIP_FINALIZE=1
EOF
