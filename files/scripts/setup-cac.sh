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
#   6. DoD certificates in Firefox and Zen browser NSS databases
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
OPENSC_LIB="/usr/lib64/opensc-pkcs11.so"

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

# Extract individual certs from a PKCS7 .p7b file into separate PEM files.
# certutil can't import PKCS7 bundles directly — it only takes the first cert.
extract_certs_from_p7b() {
    local p7b_file="$1"
    local output_dir="$2"

    # Convert DER PKCS7 to PEM, then split into individual certs
    openssl pkcs7 -print_certs -in "${p7b_file}" -inform DER 2>/dev/null | \
        awk -v outdir="${output_dir}" '
            BEGIN { n = 0 }
            /-----BEGIN CERTIFICATE-----/ {
                n++
                fname = outdir "/cert_" n ".pem"
            }
            { print > fname }
        '

    find "${output_dir}" -name "cert_*.pem" 2>/dev/null | wc -l
}

# Get the CN (Common Name) from a PEM cert — used as the NSS nickname
get_cert_cn() {
    local pem_file="$1"
    local default_name="$2"
    local cn
    cn=$(openssl x509 -in "${pem_file}" -noout -subject 2>/dev/null | \
        sed -n 's/.*CN=\([^,/]*\).*/\1/p')
    if [[ -z "${cn}" ]]; then
        echo "${default_name}"
    else
        echo "${cn}"
    fi
}

# Import all individual certs from a p7b into an NSS database
import_p7b_to_nss() {
    local p7b_file="$1"
    local nss_db="$2"
    local bundle_name
    bundle_name=$(basename "${p7b_file}" .der.p7b)
    local extract_dir
    extract_dir=$(mktemp -d)

    local num_certs
    num_certs=$(extract_certs_from_p7b "${p7b_file}" "${extract_dir}")

    if [[ "${num_certs}" -eq 0 ]]; then
        echo "     WARNING: No certs extracted from ${bundle_name}" >&2
        rm -rf "${extract_dir}"
        return 0
    fi

    local i=1
    local imported=0
    for cert_file in "${extract_dir}"/cert_*.pem; do
        [[ -f "${cert_file}" ]] || continue
        local cn
        cn=$(get_cert_cn "${cert_file}" "${bundle_name}_cert_${i}")
        if certutil -A -d sql:"${nss_db}" -n "${cn}" -t "CT,," -i "${cert_file}" 2>/dev/null; then
            imported=$((imported + 1))
        fi
        i=$((i + 1))
    done

    echo "     ${imported}/${num_certs} certs imported (${bundle_name})"
    rm -rf "${extract_dir}"
}

# ─── Check mode ───────────────────────────────────────────────────────
if [[ "${1:-}" == "--check" ]]; then
    echo "=== CAC/Smart Card Status ==="
    echo ""

    echo "1. pcscd service:"
    if systemctl is-active pcscd.socket >/dev/null 2>&1; then
        echo "   socket: active"
    else
        echo "   socket: INACTIVE"
    fi
    if systemctl is-enabled pcscd.socket >/dev/null 2>&1; then
        echo "   socket: enabled"
    else
        echo "   socket: disabled"
    fi
    echo ""

    echo "2. OpenSC PKCS#11 module:"
    if [[ -f /usr/share/p11-kit/modules/opensc.module ]]; then
        echo "   p11-kit module: present"
    else
        echo "   p11-kit module: MISSING"
    fi
    if [[ -f "${OPENSC_LIB}" ]]; then
        echo "   library: ${OPENSC_LIB}"
    else
        echo "   library: MISSING"
    fi
    echo ""

    echo "3. DoD certs in system trust:"
    trust_count=$(trust list 2>/dev/null | grep -ci "DoD" || true)
    echo "   DoD certs in system trust: ${trust_count}"
    echo ""

    echo "4. DoD certs in user NSS (~/.pki/nssdb):"
    nss_count=$(certutil -L -d sql:"${HOME}/.pki/nssdb" 2>/dev/null | grep -ci "DoD\|DOD" || true)
    echo "   DoD certs: ${nss_count}"
    echo ""

    echo "5. OpenSC module in Firefox:"
    ff_profile=$(find "${HOME}/.mozilla/firefox" -name "pkcs11.txt" 2>/dev/null | head -1)
    if [[ -n "${ff_profile}" ]]; then
        if modutil -dbdir sql:"$(dirname "${ff_profile}")" -list 2>/dev/null | grep -qi "opensc\|CAC"; then
            echo "   Firefox: OpenSC module loaded"
        else
            echo "   Firefox: OpenSC module NOT loaded"
        fi
    else
        echo "   Firefox: no profile found"
    fi
    echo ""

    echo "6. OpenSC module in Zen browser:"
    zen_profile=$(find "${HOME}/.var/app/app.zen_browser.zen/.zen" -name "pkcs11.txt" 2>/dev/null | head -1)
    if [[ -n "${zen_profile}" ]]; then
        if modutil -dbdir sql:"$(dirname "${zen_profile}")" -list 2>/dev/null | grep -qi "opensc\|CAC"; then
            echo "   Zen: OpenSC module loaded"
        else
            echo "   Zen: OpenSC module NOT loaded"
        fi
    else
        echo "   Zen: no profile found (not installed?)"
    fi
    echo ""

    echo "7. Card reader check:"
    if command -v opensc-tool &>/dev/null; then
        if opensc-tool --list-readers 2>&1 | grep -q "Reader"; then
            opensc-tool --list-readers 2>&1 | head -5
        else
            echo "   No reader detected (is the CAC reader plugged in?)"
        fi
    else
        echo "   opensc-tool not available"
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
if [[ -f "${OPENSC_LIB}" ]]; then
    echo "   OpenSC library: ${OPENSC_LIB}"
else
    echo "   WARNING: ${OPENSC_LIB} not found!"
fi
echo ""

# 3. Install DoD root CAs into the system trust store
echo "[3/5] Installing DoD root CAs into system trust store..."
CERT_BUNDLE=$(find_cert_bundle)

# Process all .p7b files (full bundle + per-root-CA bundles)
for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
    [[ -f "${p7b}" ]] || continue
    name=$(basename "${p7b}" .der.p7b)

    # Extract individual certs and install each as a trust anchor
    extract_dir=$(mktemp -d)
    num_certs=$(extract_certs_from_p7b "${p7b}" "${extract_dir}")

    if [[ "${num_certs}" -gt 0 ]]; then
        local_installed=0
        for cert_file in "${extract_dir}"/cert_*.pem; do
            [[ -f "${cert_file}" ]] || continue
            cn=$(get_cert_cn "${cert_file}" "${name}")
            safe_cn=$(echo "${cn}" | tr ' /' '__')
            target="/etc/pki/ca-trust/source/anchors/${safe_cn}.crt"
            sudo cp "${cert_file}" "${target}"
            local_installed=$((local_installed + 1))
        done
        echo "   ${name}: ${local_installed} certs installed to trust anchors"
    fi
    rm -rf "${extract_dir}"
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

# Import all DoD cert bundles into user NSS (extracting individual certs)
for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
    [[ -f "${p7b}" ]] || continue
    import_p7b_to_nss "${p7b}" "${HOME}/.pki/nssdb"
done

# Add OpenSC PKCS#11 module to user NSS (for CAC token access)
if ! modutil -dbdir sql:"${HOME}/.pki/nssdb" -list 2>/dev/null | grep -qi "OpenSC\|CAC Card"; then
    modutil -dbdir sql:"${HOME}/.pki/nssdb" -add "CAC Card" -libfile "${OPENSC_LIB}" -force 2>/dev/null && \
        echo "   OpenSC PKCS#11 module added to user NSS" || \
        echo "   (OpenSC module may already be loaded via p11-kit proxy)"
fi
echo ""

# 5. Add OpenSC module and DoD certs to Firefox/Zen browser profiles
echo "[5/5] Configuring browser NSS databases..."

# Helper: configure a browser profile
configure_profile() {
    local profile_path="$1"
    local profile_label="$2"

    echo "   ${profile_label}:"

    # Import DoD certs
    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        import_p7b_to_nss "${p7b}" "${profile_path}"
    done

    # Add OpenSC PKCS#11 module
    if ! modutil -dbdir sql:"${profile_path}" -list 2>/dev/null | grep -qi "OpenSC\|CAC Card"; then
        modutil -dbdir sql:"${profile_path}" -add "CAC Card" -libfile "${OPENSC_LIB}" -force 2>/dev/null && \
            echo "     OpenSC PKCS#11 module added" || true
    else
        echo "     OpenSC PKCS#11 module already loaded"
    fi
}

# Firefox native profiles
for profile in "${HOME}/.mozilla/firefox"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_dir=$(basename "${profile}")
    [[ "${profile_dir}" == "Crash Reports" || "${profile_dir}" == "Pending Pings" ]] && continue
    [[ "${profile_dir}" != *".default"* ]] && continue
    configure_profile "${profile}" "Firefox (${profile_dir})"
done

# Zen browser (flatpak) profiles
for profile in "${HOME}/.var/app/app.zen_browser.zen/.zen"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_name=$(basename "${profile}")
    [[ "${profile_name}" != *"Default"* ]] && continue
    configure_profile "${profile}" "Zen (${profile_name})"
done

# Firefox flatpak profiles (if using flatpak Firefox)
for profile in "${HOME}/.var/app/org.mozilla.firefox/.mozilla/firefox"/*/; do
    [[ -d "${profile}" ]] || continue
    profile_name=$(basename "${profile}")
    [[ "${profile_name}" != *".default"* ]] && continue
    configure_profile "${profile}" "Firefox flatpak (${profile_name})"
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
