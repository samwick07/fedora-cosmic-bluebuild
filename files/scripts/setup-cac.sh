#!/usr/bin/env bash
#
# setup-cac.sh — Configure CAC/smart card reader with DoD PKI certificates
#
# Sets up:
#   1. pcscd service (smart card daemon) — socket-activated
#   2. OpenSC PKCS#11 module in p11-kit (system-wide)
#   3. DoD root CA certificates in system trust store
#   4. DoD certificates in user NSS database (~/.pki/nssdb)
#   5. OpenSC PKCS#11 module in Firefox and Zen browser NSS databases
#   6. Firefox auto-config to use the PKCS#11 module
#
# Chrome/Chromium on Linux uses ~/.pki/nssdb automatically, so the user NSS
# setup covers both Chrome and any other NSS-using application.
#
# Prerequisites:
#   - opensc, pcsc-lite, pcsc-lite-ccid, nss-tools installed (in base image)
#   - DoD cert bundle at ~/Documents/<private>/DoD PKI/unclass-certificates_pkcs7_DoD/
#     (restored from backup)
#
# Usage:
#   setup-cac.sh              # full setup
#   setup-cac.sh --check      # verify current status
#
set -euo pipefail

CERT_DIR="${HOME}/Documents/<private>/DoD PKI/unclass-certificates_pkcs7_DoD"

# Find the latest cert bundle version
find_cert_bundle() {
    local latest
    latest=$(find "${CERT_DIR}" -maxdepth 1 -type d -name "Certificates_PKCS7_*" 2>/dev/null | sort -V | tail -1)
    if [[ -z "${latest}" ]]; then
        echo "ERROR: No DoD cert bundle found in ${CERT_DIR}" >&2
        echo "Restore from backup first:" >&2
        echo "  sudo restic -r <repo> restore latest --target / --include '/home/<user>/Documents/'" >&2
        return 1
    fi
    echo "${latest}"
}

# ─── Check mode ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    echo "=== CAC/Smart Card Status ==="
    echo ""
    echo "1. pcscd service:"
    systemctl is-active pcscd.socket 2>/dev/null && echo "   socket: active" || echo "   socket: INACTIVE"
    systemctl is-enabled pcscd.socket 2>/dev/null && echo "   socket: enabled" || echo "   socket: disabled"
    echo ""

    echo "2. OpenSC PKCS#11 module:"
    if [[ -f /usr/share/p11-kit/modules/opensc.module ]]; then
        echo "   p11-kit module: present"
    else
        echo "   p11-kit module: MISSING"
    fi
    echo ""

    echo "3. DoD certs in system trust:"
    local_count=$(trust list 2>/dev/null | grep -ci "DoD" || true)
    echo "   DoD certs in system trust: ${local_count}"
    echo ""

    echo "4. DoD certs in user NSS (~/.pki/nssdb):"
    nss_count=$(certutil -L -d sql:"${HOME}/.pki/nssdb" 2>/dev/null | grep -ci "DoD" || true)
    echo "   DoD certs: ${nss_count}"
    echo ""

    echo "5. OpenSC module in Firefox:"
    ff_profile=$(find "${HOME}/.mozilla/firefox" -name "pkcs11.txt" 2>/dev/null | head -1)
    if [[ -n "${ff_profile}" ]]; then
        if grep -q "opensc" "${ff_profile}" 2>/dev/null; then
            echo "   Firefox: OpenSC module loaded"
        else
            echo "   Firefox: OpenSC module NOT loaded"
        fi
    else
        echo "   Firefox: no profile found"
    fi
    echo ""

    echo "6. Card reader check:"
    if pcsc_scan --help >/dev/null 2>&1; then
        timeout 3 pcsc_scan 2>&1 | head -5 || echo "   (no card or reader not connected)"
    else
        echo "   pcsc_scan not installed (optional)"
    fi

    exit 0
fi

# ─── Full setup ───────────────────────────────────────────────────────
echo "=== CAC/Smart Card Setup ==="
echo ""

# 1. Enable pcscd (smart card daemon) — socket-activated
echo "[1/5] Enabling pcscd (smart card daemon)..."
sudo systemctl enable --now pcscd.socket
echo "   pcscd.socket enabled and started."
echo ""

# 2. Verify OpenSC p11-kit module (should already be installed)
echo "[2/5] Verifying OpenSC PKCS#11 module..."
if [[ -f /usr/share/p11-kit/modules/opensc.module ]]; then
    echo "   opensc.module already present at /usr/share/p11-kit/modules/"
else
    echo "   WARNING: opensc.module not found. OpenSC may not be installed."
    echo "   Install with: sudo rpm-ostree install opensc"
fi
echo ""

# 3. Install DoD root CAs into the system trust store
echo "[3/5] Installing DoD root CAs into system trust store..."
CERT_BUNDLE=$(find_cert_bundle)

# Install each root CA .p7b into the system trust anchors
for p7b in "${CERT_BUNDLE}"/*DoD_Root_CA_*.der.p7b; do
    [[ -f "${p7b}" ]] || continue
    name=$(basename "${p7b}" .der.p7b)
    target="/etc/pki/ca-trust/source/anchors/${name}.crt"

    # Convert DER PKCS7 to PEM and install as trust anchor
    openssl pkcs7 -print_certs -in "${p7b}" -inform DER -out "${target}" 2>/dev/null
    echo "   Installed: ${name}"
done

# Also install the full bundle
for p7b in "${CERT_BUNDLE}"/Certificates_PKCS7_*_DoD.der.p7b; do
    [[ -f "${p7b}" ]] || continue
    name=$(basename "${p7b}" .der.p7b)
    target="/etc/pki/ca-trust/source/anchors/${name}.crt"
    openssl pkcs7 -print_certs -in "${p7b}" -inform DER -out "${target}" 2>/dev/null
    echo "   Installed: ${name}"
done

# Update the system trust store
sudo update-ca-trust extract
echo "   System trust store updated."
echo ""

# 4. Install DoD certs into user NSS database (used by Chrome)
echo "[4/5] Installing DoD certs into user NSS database..."
mkdir -p "${HOME}/.pki/nssdb"

# Initialize NSS db if it doesn't exist
if [[ ! -f "${HOME}/.pki/nssdb/cert9.db" ]]; then
    certutil -N -d sql:"${HOME}/.pki/nssdb" --empty-password 2>/dev/null || true
fi

# Import all DoD cert bundles into user NSS
for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
    [[ -f "${p7b}" ]] || continue
    name=$(basename "${p7b}")
    # certutil uses -A to add, -t "CT,," for SSL trust
    certutil -A -d sql:"${HOME}/.pki/nssdb" -n "${name}" -t "CT,," -i "${p7b}" 2>/dev/null && \
        echo "   Imported: ${name}" || \
        echo "   Already exists: ${name}"
done

# Add OpenSC PKCS#11 module to user NSS (for CAC token access)
certutil -d sql:"${HOME}/.pki/nssdb" -U 2>/dev/null | grep -q "CAC" || true
# Use modutil to add the OpenSC module if not already present
if ! modutil -dbdir sql:"${HOME}/.pki/nssdb" -list 2>/dev/null | grep -q "OpenSC"; then
    modutil -dbdir sql:"${HOME}/.pki/nssdb" -add "CAC Card" -libfile /usr/lib64/opensc-pkcs11.so -force 2>/dev/null && \
        echo "   OpenSC PKCS#11 module added to user NSS" || \
        echo "   (OpenSC module may already be loaded via p11-kit)"
fi
echo ""

# 5. Add OpenSC module and DoD certs to Firefox/Zen browser profiles
echo "[5/5] Configuring browser NSS databases..."

# Firefox profiles
for profile in "${HOME}/.mozilla/firefox"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_dir=$(basename "${profile}")

    # Skip non-profile dirs
    [[ "${profile_dir}" == "Crash Reports" || "${profile_dir}" == "Pending Pings" ]] && continue
    [[ "${profile_dir}" != *".default"* ]] && continue

    echo "   Firefox profile: ${profile_dir}"

    # Import DoD certs
    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        name=$(basename "${p7b}")
        certutil -A -d sql:"${profile}" -n "${name}" -t "CT,," -i "${p7b}" 2>/dev/null && \
            echo "     Imported: ${name}" || true
    done

    # Add OpenSC PKCS#11 module
    if ! modutil -dbdir sql:"${profile}" -list 2>/dev/null | grep -q "OpenSC\|CAC"; then
        modutil -dbdir sql:"${profile}" -add "CAC Card" -libfile /usr/lib64/opensc-pkcs11.so -force 2>/dev/null && \
            echo "     OpenSC PKCS#11 module added" || true
    fi
done

# Zen browser (flatpak) profiles
for profile in "${HOME}/.var/app/app.zen_browser.zen/.zen"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_name=$(basename "${profile}")
    [[ "${profile_name}" != *"Default"* ]] && continue

    echo "   Zen profile: ${profile_name}"

    # Import DoD certs
    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        name=$(basename "${p7b}")
        certutil -A -d sql:"${profile}" -n "${name}" -t "CT,," -i "${p7b}" 2>/dev/null && \
            echo "     Imported: ${name}" || true
    done

    # Add OpenSC PKCS#11 module
    if ! modutil -dbdir sql:"${profile}" -list 2>/dev/null | grep -q "OpenSC\|CAC"; then
        modutil -dbdir sql:"${profile}" -add "CAC Card" -libfile /usr/lib64/opensc-pkcs11.so -force 2>/dev/null && \
            echo "     OpenSC PKCS#11 module added" || true
    fi
done

# Firefox flatpak profiles (if using flatpak Firefox)
for profile in "${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_name=$(basename "${profile}")
    [[ "${profile_name}" != *".default"* ]] && continue

    echo "   Firefox (flatpak) profile: ${profile_name}"

    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        name=$(basename "${p7b}")
        certutil -A -d sql:"${profile}" -n "${name}" -t "CT,," -i "${p7b}" 2>/dev/null && \
            echo "     Imported: ${name}" || true
    done

    if ! modutil -dbdir sql:"${profile}" -list 2>/dev/null | grep -q "OpenSC\|CAC"; then
        modutil -dbdir sql:"${profile}" -add "CAC Card" -libfile /usr/lib64/opensc-pkcs11.so -force 2>/dev/null && \
            echo "     OpenSC PKCS#11 module added" || true
    fi
done

echo ""
echo "=== CAC Setup Complete ==="
echo ""
echo "To verify, insert your CAC card and run:"
echo "  setup-cac.sh --check"
echo ""
echo "Or test with:"
echo "  pkcs11-tool --list-objects --type cert"
echo "  opensc-tool --list-readers"
echo ""
echo "Browsers: restart Firefox/Chrome/Zen for changes to take effect."
