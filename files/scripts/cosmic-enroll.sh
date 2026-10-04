#!/usr/bin/bash
# cosmic-enroll — the enrolments that need a person (spec P6, P9), in one command.
#
#   sudo cosmic-enroll            fingerprint for the user who ran sudo, then TPM2 + PIN on
#                                 every LUKS device in /etc/crypttab (root and swap)
#   sudo cosmic-enroll --check    show what is enrolled, change nothing
#
# You type: your finger on the reader, the LUKS passphrase, a new PIN (twice). Each part is
# skipped when it is already done. TPM2 binds to PCR 7 (systemd's default); with Secure
# Boot off that measures little, so the PIN is what protects the disk.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo" >&2; exit 2; }
CHECK=0; [[ "${1:-}" == --check ]] && CHECK=1
U="${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}"

# P6: fingerprint
if fprintd-list "$U" 2>/dev/null | grep -q " - #"; then
    echo "fingerprint: enrolled for $U"
elif [[ $CHECK == 1 ]]; then
    echo "fingerprint: NOT enrolled for $U"
else
    echo "fingerprint: place your finger on the reader when asked"
    fprintd-enroll "$U"
fi
# ...and PAM must ask for it (sudo, the greeter, the lock screen): authselect's feature.
if authselect current 2>/dev/null | grep -q with-fingerprint; then
    echo "fingerprint: PAM uses it (authselect with-fingerprint)"
elif [[ $CHECK == 1 ]]; then
    echo "fingerprint: PAM does NOT use it (authselect with-fingerprint missing)"
else
    authselect enable-feature with-fingerprint && authselect apply-changes && echo "fingerprint: PAM enabled (authselect with-fingerprint)"
fi

# P9: TPM2 + PIN on each LUKS device of /etc/crypttab
mapfile -t devs < <(awk '!/^#/ && NF>=2 {print $2}' /etc/crypttab)
for spec in "${devs[@]}"; do
    case "$spec" in
        UUID=*) dev="/dev/disk/by-uuid/${spec#UUID=}" ;;
        /dev/*) dev="$spec" ;;
        *) echo "skip $spec (not a device path)"; continue ;;
    esac
    [[ -b "$dev" ]] || { echo "skip $spec (no such device)"; continue; }
    if cryptsetup luksDump "$dev" | grep -q "systemd-tpm2"; then
        echo "TPM2: enrolled on $dev"
    elif [[ $CHECK == 1 ]]; then
        echo "TPM2: NOT enrolled on $dev"
    else
        echo "TPM2 + PIN on $dev: the LUKS passphrase, then a new PIN twice"
        systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes "$dev"
    fi
done

# The initramfs unlocks root and swap from rd.luks.uuid=; tell it to try the TPM first.
if grep -qw "rd.luks.options=tpm2-device=auto" /proc/cmdline; then
    echo "kernel: rd.luks.options=tpm2-device=auto present"
elif [[ $CHECK == 1 ]]; then
    echo "kernel: rd.luks.options=tpm2-device=auto missing"
else
    rpm-ostree kargs --append-if-missing=rd.luks.options=tpm2-device=auto
    echo "kernel argument added (staged): reboot, then the PIN unlocks the disk"
fi
