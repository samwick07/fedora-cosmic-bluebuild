#!/usr/bin/env bash
# enable-hibernation.sh — HOST: verify or complete the per-installation half of
# hibernation. Shipped at /usr/bin/enable-hibernation.sh.
#
# (retired bootc installer path): resume=, rd.luks.uuid=, crypttab and
#             the swap fstab line are already written -> this script only checks.
# Anaconda path: Anaconda writes crypttab/fstab and rd.luks.uuid but NOT resume=
#             -> this script adds resume= via rpm-ostree kargs.
#
# It refuses to invent a swapfile. The design is a dedicated 96 GB LUKS swap
# partition; if none is active something upstream went wrong and you want to
# know, not paper over it.
#
# Usage: sudo enable-hibernation.sh [--check]
# Runs at every boot as cosmic-hibernation.service (frmwrk image); by hand only to look.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo" >&2; exit 1; }
CHECK_ONLY=0; [[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

ok()   { echo "  ✓ $*"; }
bad()  { echo "  ✗ $*"; STATUS=1; }
STATUS=0

echo "=== Hibernation: Framework 13 ==="

# 1. Swap partition (not zram, not a file)
SWAP_DEV=$(swapon --show=NAME,TYPE --noheadings | awk '$2=="partition"{print $1; exit}')
if [[ -z "$SWAP_DEV" ]]; then
    bad "no swap PARTITION active (swapon --show). Check /etc/crypttab and /etc/fstab for the LUKS swap entry."
    echo "     crypttab:"; sed 's/^/       /' /etc/crypttab 2>/dev/null || echo "       (missing)"
    echo "     fstab swap:"; grep -i swap /etc/fstab 2>/dev/null | sed 's/^/       /' || echo "       (none)"
    exit 1
fi
SWAP_UUID=$(blkid -s UUID -o value "$SWAP_DEV")
ok "swap partition $SWAP_DEV (UUID $SWAP_UUID, $(swapon --show=SIZE --noheadings "$SWAP_DEV" 2>/dev/null || true))"

# 2. LUKS underneath the swap must be unlocked in the initramfs
SWAP_LUKS_UUID=""
# The swap is a dm-crypt mapping; its LUKS partition is the "part" it sits on. (lsblk's
# PKNAME is empty for dm devices, so walk the dependencies with -s instead.)
parent=$(lsblk -lnso NAME,TYPE "$SWAP_DEV" | awk '$2=="part"{print $1; exit}')
if [[ -n "$parent" && $(blkid -s TYPE -o value "/dev/$parent") == crypto_LUKS ]]; then
    SWAP_LUKS_UUID=$(blkid -s UUID -o value "/dev/$parent")
    if grep -q "rd.luks.uuid=$SWAP_LUKS_UUID\|rd.luks.uuid=luks-$SWAP_LUKS_UUID" /proc/cmdline; then
        ok "rd.luks.uuid for swap on cmdline"
    else
        bad "rd.luks.uuid=$SWAP_LUKS_UUID missing from the kernel cmdline (initramfs cannot unlock swap for resume)"
        (( CHECK_ONLY )) || { rpm-ostree kargs --append-if-missing="rd.luks.uuid=$SWAP_LUKS_UUID"; echo "     -> added (reboot required)"; }
    fi
fi

# 3. resume=
if grep -q "resume=UUID=$SWAP_UUID" /proc/cmdline; then
    ok "resume=UUID=$SWAP_UUID on cmdline"
elif grep -q 'resume=' /proc/cmdline; then
    bad "resume= points at a different UUID than the active swap"
    (( CHECK_ONLY )) || { rpm-ostree kargs --delete-if-present="$(grep -o 'resume=[^ ]*' /proc/cmdline)" --append-if-missing="resume=UUID=$SWAP_UUID"; echo "     -> fixed (reboot required)"; }
else
    bad "no resume= karg"
    (( CHECK_ONLY )) || { rpm-ostree kargs --append-if-missing="resume=UUID=$SWAP_UUID"; echo "     -> added (reboot required)"; }
fi

# 4. SELinux module
if semodule -l 2>/dev/null | grep -q '^systemd_hibernate'; then
    ok "SELinux systemd_hibernate module loaded"
else
    bad "SELinux systemd_hibernate module not loaded"
    pp=/usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.pp
    te=/usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.te
    if (( ! CHECK_ONLY )); then
        if [[ -f "$pp" ]]; then
            semodule -i "$pp" && ok "installed from $pp"
        elif [[ -f "$te" ]] && command -v checkmodule >/dev/null; then
            t=$(mktemp -d); checkmodule -M -m -o "$t/m.mod" "$te"; semodule_package -o "$t/m.pp" -m "$t/m.mod"; semodule -i "$t/m.pp"; rm -rf "$t"
            ok "compiled and installed from $te"
        else
            echo "     no .pp/.te found in the image — rebuild the image (configure-hibernation.sh)"
        fi
    fi
fi

# 5. systemd config + lockdown
[[ -f /usr/lib/systemd/sleep.conf.d/10-hibernate.conf || -f /etc/systemd/sleep.conf.d/10-hibernate.conf ]] && ok "sleep.conf.d drop-in present" || bad "sleep.conf.d/10-hibernate.conf missing (image build issue)"
[[ -f /usr/lib/systemd/logind.conf.d/10-lid.conf || -f /etc/systemd/logind.conf.d/10-lid.conf ]] && ok "logind.conf.d drop-in present"  || bad "logind.conf.d/10-lid.conf missing (image build issue)"
if [[ -r /sys/kernel/security/lockdown ]] && grep -q '\[integrity\]\|\[confidentiality\]' /sys/kernel/security/lockdown; then
    bad "kernel lockdown active (Secure Boot ON) — hibernation is blocked. Disable Secure Boot in firmware."
else
    ok "kernel lockdown off"
fi
if [[ $(cat /sys/power/disk 2>/dev/null) == *"[disabled]"* ]]; then
    bad "/sys/power/disk reports hibernation disabled"
fi
mem=$(awk '/MemTotal/{print $2}' /proc/meminfo); swp=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
(( swp >= mem )) && ok "swap ($((swp/1024/1024)) GiB) >= RAM ($((mem/1024/1024)) GiB)" || bad "swap smaller than RAM — hibernation may fail under load"

echo ""
if (( STATUS == 0 )); then
    echo "All good. Test:  systemctl hibernate     then     systemctl suspend-then-hibernate"
else
    echo "Fixes applied where possible. If kargs changed: REBOOT, then run:  sudo enable-hibernation.sh --check"
    echo "Debug a failed hibernate with:  journalctl -b -1 -u systemd-suspend-then-hibernate -u systemd-hibernate -u systemd-logind"
fi
exit $STATUS
