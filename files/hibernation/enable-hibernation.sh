#!/usr/bin/env bash
# enable-hibernation.sh
# Post-install script to configure hibernation on Fedora Atomic COSMIC.
#
# This script must be run ONCE after the first boot of your custom image.
# It handles the parts that CAN'T be baked into the image:
#   - Creating the encrypted swap partition
#   - Setting the resume= kernel parameter
#   - Setting the rd.luks.uuid for the swap partition
#
# PREREQUISITES:
#   - During Fedora installation, create a swap partition with LUKS encryption
#     (size: RAM x 1.5, or at least 96GB for 60GB RAM)
#   - OR: if no swap partition exists, this script can create a swapfile
#     under /var/swap (the Atomic-safe location)
#
# USAGE:
#   sudo /usr/local/bin/enable-hibernation.sh
#
set -euo pipefail

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

echo "=== Hibernation Setup for Framework 13 ==="
echo ""

# ─────────────────────────────────────────────
# STEP 1: Detect or create swap space
# ─────────────────────────────────────────────
SWAP_DEVICE=""
SWAP_UUID=""
RESUME_PARAM=""

# Check for existing swap partition
EXISTING_SWAP=$(swapon --show=NAME --noheadings 2>/dev/null | grep -v zram | head -1 || true)

if [[ -n "$EXISTING_SWAP" ]]; then
    echo "Found existing swap: $EXISTING_SWAP"
    SWAP_DEVICE="$EXISTING_SWAP"
    SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEVICE" 2>/dev/null || true)
    if [[ -z "$SWAP_UUID" ]]; then
        # Try the underlying device (for LUKS)
        SWAP_UUID=$(blkid -s UUID -o value "$(readlink -f "$SWAP_DEVICE")" 2>/dev/null || true)
    fi
    echo "Swap UUID: $SWAP_UUID"
else
    echo "No swap partition found (excluding zram)."
    echo "Creating a swapfile under /var/swap (Atomic-safe location)..."

    # Calculate swap size based on RAM
    RAM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    RAM_GB=$((RAM_KB / 1024 / 1024))
    SWAP_SIZE_GB=$((RAM_GB * 2))
    if [[ $SWAP_SIZE_GB -lt 32 ]]; then
        SWAP_SIZE_GB=32
    fi
    echo "RAM: ${RAM_GB}GB, Swap size: ${SWAP_SIZE_GB}GB"

    # Create swapfile on btrfs (Atomic's /var is writable and persists)
    mkdir -p /var/swap
    chattr +C /var/swap 2>/dev/null || true
    restorecon /var/swap 2>/dev/null || true

    SWAPFILE="/var/swap/swapfile"
    if [[ ! -f "$SWAPFILE" ]]; then
        mkswap --file -L SWAPFILE --size "${SWAP_SIZE_GB}G" "$SWAPFILE"
    fi

    # Add to fstab if not present
    if ! grep -q "$SWAPFILE" /etc/fstab 2>/dev/null; then
        echo "$SWAPFILE none swap defaults 0 0" >> /etc/fstab
    fi

    swapon "$SWAPFILE" 2>/dev/null || true
    SWAP_DEVICE="$SWAPFILE"

    # For swapfile on btrfs, we need resume_offset
    SWAP_UUID=$(findmnt -n -o UUID /)
    RESUME_OFFSET=$(btrfs inspect-internal map-swapfile -r "$SWAPFILE" 2>/dev/null || true)
    if [[ -n "$RESUME_OFFSET" ]]; then
        RESUME_PARAM="resume=UUID=${SWAP_UUID} resume_offset=${RESUME_OFFSET}"
    else
        RESUME_PARAM="resume=UUID=${SWAP_UUID}"
    fi
    echo "Swapfile created: $SWAPFILE"
    echo "Resume offset: $RESUME_OFFSET"
fi

# For swap partition (not swapfile)
if [[ -z "$RESUME_PARAM" && -n "$SWAP_UUID" ]]; then
    RESUME_PARAM="resume=UUID=${SWAP_UUID}"
fi

if [[ -z "$RESUME_PARAM" ]]; then
    echo "ERROR: Could not determine resume parameters."
    echo "Check that swap is active: swapon --show"
    exit 1
fi

echo ""
echo "Resume parameter: $RESUME_PARAM"

# ─────────────────────────────────────────────
# STEP 2: Set kernel arguments via rpm-ostree kargs
# ─────────────────────────────────────────────
echo ""
echo "=== Setting kernel arguments ==="

# Remove any existing resume= parameter
rpm-ostree kargs --delete=resume 2>/dev/null || true
rpm-ostree kargs --delete=resume_offset 2>/dev/null || true

# Add the resume parameter
rpm-ostree kargs --append-if-missing="$RESUME_PARAM"

echo "Kernel arguments updated."
echo ""
echo "Current kernel args:"
rpm-ostree kargs

# ─────────────────────────────────────────────
# STEP 3: Install SELinux policy (if not done at build time)
# ─────────────────────────────────────────────
if [[ -f /usr/local/share/selinux/systemd_hibernate.te ]]; then
    echo ""
    echo "=== Installing SELinux hibernation policy ==="
    TE_FILE="/usr/local/share/selinux/systemd_hibernate.te"

    if command -v checkmodule &>/dev/null; then
        TMPDIR=$(mktemp -d)
        checkmodule -M -m -o "$TMPDIR/systemd_hibernate.mod" "$TE_FILE"
        semodule_package -o "$TMPDIR/systemd_hibernate.pp" -m "$TMPDIR/systemd_hibernate.mod"
        semodule -i "$TMPDIR/systemd_hibernate.pp"
        rm -rf "$TMPDIR"
        echo "SELinux policy installed."
    else
        echo "WARNING: checkmodule not available. Install policycoreutils-python-utils:"
        echo "  rpm-ostree install policycoreutils-python-utils"
        echo "Then run this script again."
    fi
fi

# ─────────────────────────────────────────────
# STEP 4: Verify configuration
# ─────────────────────────────────────────────
echo ""
echo "=== Verification ==="
echo "Swap:"
swapon --show
echo ""
echo "Kernel args:"
rpm-ostree kargs
echo ""
echo "Sleep config:"
cat /etc/systemd/sleep.conf 2>/dev/null || echo "(not found)"
echo ""
echo "Logind config (active):"
grep -v '^#' /etc/systemd/logind.conf 2>/dev/null | grep -v '^$' || echo "(not found)"
echo ""

# ─────────────────────────────────────────────
# STEP 5: Instructions
# ─────────────────────────────────────────────
echo "=== SETUP COMPLETE ==="
echo ""
echo "REBOOT required to apply kernel arguments."
echo ""
echo "After reboot, test with:"
echo "  systemctl hibernate"
echo ""
echo "To test suspend-then-hibernate:"
echo "  systemctl suspend-then-hibernate"
echo ""
echo "Lid close is set to: suspend-then-hibernate"
echo "Hibernate delay: $(grep HibernateDelaySec /etc/systemd/sleep.conf 2>/dev/null || echo '300s (default)')"
echo ""
echo "IMPORTANT: Secure Boot must be DISABLED for hibernation to work."
echo "The kernel's lockdown feature blocks resume from an encrypted swap."
echo ""
echo "If hibernation fails, check:"
echo "  journalctl -b -1 | grep -iE 'hibernate|suspend|resume|swap'"
echo "  sudo audit2allow -b  (for SELinux blocks)"
