#!/usr/bin/env bash
#
# cac-status — read-only CAC report for the host (spec V2–V4). Shipped as /usr/bin/cac-status.
#
#   cac-status
#
# Where CAC works on this system:
#   - Firefox (base): OpenSC through p11-kit, DoD roots from the system trust (V4).
#   - Chrome (dev distrobox): its own opensc, the host's pcscd through the socket,
#     DoD certs + OpenSC module in ~/.pki/nssdb (set up by the dotfiles).
#   - Win11 VM: `sudo win11-cac attach` hands the reader to the VM; the host loses
#     the card until `sudo win11-cac detach`.
#
set -uo pipefail
OPENSC_LIB=/usr/lib64/opensc-pkcs11.so
yesno() { if "$@" >/dev/null 2>&1; then echo yes; else echo NO; fi; }

echo "=== CAC status ($(hostname)) ==="
printf 'pcscd.socket:            %s / %s\n' "$(systemctl is-active pcscd.socket 2>/dev/null)" "$(systemctl is-enabled pcscd.socket 2>/dev/null)"
printf 'OpenSC library:          %s\n' "$(yesno test -f "$OPENSC_LIB")"
printf 'OpenSC p11-kit module:   %s\n' "$(yesno test -f /usr/share/p11-kit/modules/opensc.module)"
printf 'DoD CAs in system trust: %s\n' "$(trust list 2>/dev/null | grep -ci 'DoD' || true)"
if [[ -d "$HOME/.pki/nssdb" ]] && command -v certutil >/dev/null; then
    printf 'DoD certs in ~/.pki/nssdb (Chrome): %s\n' "$(certutil -L -d "sql:$HOME/.pki/nssdb" 2>/dev/null | grep -ci 'DoD' || true)"
else
    printf 'Chrome NSS db:           check inside dev: distrobox enter dev -- certutil -L -d sql:$HOME/.pki/nssdb\n'
fi
if command -v virsh >/dev/null; then
    printf 'Win11 VM reader:         %s\n' "$(win11-cac status 2>&1 | sed -n 's/^attached: *//p')"
fi
echo "Readers (host):"
if command -v opensc-tool >/dev/null; then opensc-tool --list-readers 2>&1 | sed 's/^/  /' | head -6
else echo "  (opensc-tool not installed on the host)"; fi
