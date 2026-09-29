#!/usr/bin/env bash
# enable-vfio.sh
# Post-install script to configure VFIO PCIe passthrough for the
# 2TB NVMe drive that hosts the Windows 11 VM on the desktop.
#
# This script must be run ONCE after the first boot of the custom image.
# It handles the parts that CAN'T be baked into the image:
#   - Detecting the 2TB NVMe's vendor:device ID
#   - Setting vfio-pci.ids kernel parameter
#   - Binding the device to the vfio-pci driver
#
# USAGE:
#   sudo /usr/local/bin/enable-vfio.sh
#
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

echo "=== VFIO PCIe Passthrough Setup for Desktop ==="
echo ""

# ─────────────────────────────────────────────
# STEP 1: Find the 2TB NVMe controller
# ─────────────────────────────────────────────
echo "Scanning for NVMe controllers..."
echo ""

# List all NVMe controllers with their PCI IDs
NVME_DEVICES=$(lspci -nn | grep -i "non-volatile\|nvme" || true)

if [[ -z "$NVME_DEVICES" ]]; then
    echo "ERROR: No NVMe controllers found."
    exit 1
fi

echo "Found NVMe controllers:"
echo "$NVME_DEVICES"
echo ""

# Extract vendor:device IDs for all NVMe controllers
# Format: "02:00.0 Non-Volatile memory controller [0108]: Crucial ... [15b3:1234]"
# We want the [xxxx:xxxx] part
VFIO_IDS=""
while IFS= read -r line; do
    pci_addr=$(echo "$line" | awk '{print $1}')
    # Extract the [vendor:device] ID
    ids=$(echo "$line" | grep -oP '\[\K[a-f0-9]{4}:[a-f0-9]{4}' | tail -1)
    # Get the device description
    desc=$(echo "$line" | sed "s/^$pci_addr //; s/\[.*$//")
    echo "  $pci_addr: $desc → $ids"
done <<< "$NVME_DEVICES"

echo ""
echo "Which NVMe controller should be passed through to the Windows VM?"
echo "(This is typically the 2TB drive, usually the second NVMe slot)"
echo ""

# Auto-detect: the 2TB NVMe is usually the second controller
# On the ROG STRIX X870-I, nvme0n1 is the 4TB (slot 0) and nvme1n1 is the 2TB (slot 1)
# The PCI address of nvme1n1 can be found via sysfs
SECOND_NVME_PCI=$(cat /sys/class/nvme/nvme1n1/device/address 2>/dev/null || true)

if [[ -n "$SECOND_NVME_PCI" ]]; then
    echo "Auto-detected 2TB NVMe at PCI address: $SECOND_NVME_PCI"
    # Normalize the address format (sysfs uses 0000:02:00.0, lspci uses 02:00.0)
    SHORT_ADDR=$(echo "$SECOND_NVME_PCI" | sed 's/^0000://')
    VFIO_LINE=$(lspci -nn | grep "^${SHORT_ADDR}")
    VFIO_IDS=$(echo "$VFIO_LINE" | grep -oP '\[\K[a-f0-9]{4}:[a-f0-9]{4}' | tail -1)
    echo "Controller: $VFIO_LINE"
    echo "Vendor:Device ID: $VFIO_IDS"
else
    echo "Could not auto-detect. Enter the PCI address (e.g. 02:00.0):"
    read -r pci_addr
    VFIO_LINE=$(lspci -nn | grep "^${pci_addr}")
    VFIO_IDS=$(echo "$VFIO_LINE" | grep -oP '\[\K[a-f0-9]{4}:[a-f0-9]{4}' | tail -1)
fi

if [[ -z "$VFIO_IDS" ]]; then
    echo "ERROR: Could not determine vendor:device ID."
    exit 1
fi

echo ""
echo "Will set vfio-pci.ids=$VFIO_IDS"
echo ""

# ─────────────────────────────────────────────
# STEP 2: Set the kernel parameter
# ─────────────────────────────────────────────
echo "=== Setting kernel parameter ==="

# Remove any existing vfio-pci.ids
rpm-ostree kargs --delete=vfio-pci.ids 2>/dev/null || true

# Add the new one
rpm-ostree kargs --append-if-missing="vfio-pci.ids=$VFIO_IDS"

echo "Kernel arguments updated."

# ─────────────────────────────────────────────
# STEP 3: Ensure vfio-pci driver loads at boot
# ─────────────────────────────────────────────
# On Atomic, we can't easily modify initramfs driver loading order.
# But we can ensure the vfio modules are available.
# The amd_iommu=on and iommu=pt kargs are already in the image (via kargs module).

echo ""
echo "=== Verifying IOMMU groups ==="
echo "IOMMU groups for NVMe devices:"
for dev in /sys/class/nvme/*/device/iommu_group; do
    if [[ -L "$dev" ]]; then
        nvme=$(echo "$dev" | cut -d/ -f4)
        group=$(basename "$(readlink -f "$dev")" 2>/dev/null || echo "unknown")
        echo "  $nvme → IOMMU group $group"
    fi
done

echo ""
echo "=== VFIO Setup Complete ==="
echo ""
echo "REBOOT required to apply the vfio-pci.ids kernel parameter."
echo ""
echo "After reboot, verify the device is bound to vfio-pci:"
echo "  lspci -nnk -s $SHORT_ADDR"
echo "  (Should show 'Kernel driver in use: vfio-pci')"
echo ""
echo "Then configure your Windows VM in virt-manager:"
echo "  1. Add Hardware → PCI Host Device"
echo "  2. Select the NVMe controller at $SHORT_ADDR"
echo "  3. The VM will see it as a physical NVMe drive"
echo ""
echo "Current kernel args:"
rpm-ostree kargs
