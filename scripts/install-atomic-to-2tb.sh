#!/bin/bash
#
# install-atomic-to-2tb.sh — Install Fedora Cosmic Atomic to the 2TB test disk
#
# Target: /dev/sdb (2TB USB SSD, model "PCIE")
# Existing layout (preserved):
#   sdb1  600M  vfat        (EFI system partition)
#   sdb2  2G    ext4        (/boot)
#   sdb3  96G   crypto_LUKS (swap for hibernation)
#   sdb4  1.7T  crypto_LUKS (btrfs root)
#
# The LUKS containers are already unlocked:
#   luks-xxxxxxxx... = swap
#   luks-xxxxxxxx... = btrfs root (currently mounted at /run/media/<user>/fedora_fedora)
#
# This script uses bootc install to-filesystem to write the ostree deployment
# onto the existing btrfs root, preserving the LUKS encryption and swap.
#
# Run with: sudo bash install-atomic-to-2tb.sh
#
set -euo pipefail

# Use the locally-built image (already in podman storage — no download needed)
IMAGE="local-build:framework"
# For future updates, the machine pulls from GHCR:
REGISTRY_IMGREF="ghcr.io/samwick07/fedora-cosmic-framework:latest"
TARGET="/mnt/atomic-target"

# LUKS device mapper names (from lsblk)
ROOT_DM="/dev/mapper/luks-00000000-0000-0000-0000-000000000000"
EFI_PART="/dev/sdb1"
BOOT_PART="/dev/sdb2"

echo "=== Installing Fedora Cosmic Atomic to 2TB test disk ==="
echo "Image:  ${IMAGE} (local, no download)"
echo "Update: ${REGISTRY_IMGREF} (for future rpm-ostree upgrades)"
echo "Target: /dev/sdb (2TB USB SSD)"
echo "Root:   ${ROOT_DM} (LUKS btrfs)"
echo "EFI:    ${EFI_PART}"
echo "Boot:   ${BOOT_PART}"
echo ""

# Safety check — make sure we're NOT targeting the primary disk
if lsblk -o PKNAME "${ROOT_DM}" 2>/dev/null | grep -q "nvme"; then
    echo "ERROR: Target appears to be on the primary NVMe — aborting!"
    echo "This would overwrite your running system."
    exit 1
fi

# 1. Unmount the target if it's currently mounted
echo "[1/6] Unmounting target..."
umount -R /run/media/<user>/fedora_fedora 2>/dev/null || true
umount -R "${TARGET}" 2>/dev/null || true

# 2. Mount the target filesystem (reformatted to clear stale ostree files)
echo "[2/6] Reformatting and mounting target..."
mkdir -p "${TARGET}"
# Reformat btrfs to clear any previous partial installs — ostree deployment
# files are immutable and can't be rm'd even as root. Fresh filesystem avoids
# all permission/SELinux/immutable issues.
mkfs.btrfs -f "${ROOT_DM}"
mount "${ROOT_DM}" "${TARGET}"

# 3. Mount boot/EFI partitions (bootc expects them pre-mounted)
echo "[3/6] Mounting boot partitions..."
mkdir -p "${TARGET}/boot/efi"
mount "${EFI_PART}" "${TARGET}/boot/efi"
mkdir -p "${TARGET}/boot"
mount "${BOOT_PART}" "${TARGET}/boot"

# 4. Verify the local image is available (transfer from user storage if needed)
echo "[4/6] Verifying local image..."
if ! podman image inspect "${IMAGE}" >/dev/null 2>&1; then
    echo "  Not in root podman — transferring from user storage (no download)..."
    sudo -u <user> podman save local-build:framework --format oci-archive | podman load
fi
echo "  Image ready: $(podman image inspect "${IMAGE}" --format '{{.Id}}')"

# 5. Install with bootc
echo "[5/6] Running bootc install to-filesystem..."
echo "  This writes the ostree deployment to the target..."
echo "  --target-imgref sets future update source to the signed GHCR image"
echo "  --bootloader systemd uses systemd-boot (BLS-native for ostree)"
echo "  --skip-finalize skips fstrim (USB-attached disk may not support TRIM)"
podman run --privileged --pid=host --security-opt label=disable --rm \
    -v "${TARGET}:/target" \
    -v /dev:/dev \
    "${IMAGE}" \
    bootc install to-filesystem \
        --target-imgref "${REGISTRY_IMGREF}" \
        --bootloader systemd \
        --skip-finalize \
        /target

# 6. Unmount
echo "[6/6] Unmounting target..."
umount -R "${TARGET}"
echo ""
echo "=== Installation complete ==="
echo ""
echo "The 2TB disk now has Fedora Cosmic Atomic installed."
echo "To boot from it:"
echo "  1. Reboot"
echo "  2. Enter BIOS/UEFI boot menu (F12 or F2)"
echo "  3. Select the 2TB USB disk"
echo ""
echo "After first boot:"
echo "  - Run: sudo /usr/local/bin/enable-hibernation.sh"
echo "  - Run: distrobox-setup.sh"
echo "  - Restore dotfiles: yadm clone https://github.com/samwick07/dotfiles.git"
echo "  - Restore data: sudo restic -r <repo> restore latest --target / --include /home/<user>/"
