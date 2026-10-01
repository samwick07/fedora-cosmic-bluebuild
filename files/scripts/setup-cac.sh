#!/usr/bin/env bash
#
# setup-cac.sh — Configure CAC/smart card reader with DoD PKI certificates
#
# Shipped in the image at /usr/bin/setup-cac.sh.
#
# Modes:
#   setup-cac.sh --system   (root)  pcscd socket, DoD roots into the system trust store
#   setup-cac.sh --user     (user)  DoD certs + OpenSC module into ~/.pki/nssdb and
#                                   browser profiles, pcsc socket for flatpak browsers
#   setup-cac.sh            (user)  both — uses sudo for the system half
#   setup-cac.sh --check    (user)  report status
#   setup-cac.sh --fetch    (any)   download + verify the DoD bundle only, print its dir
#   --refresh (first argument) re-downloads the DoD bundle
#
# Prerequisites:
#   - opensc, pcsc-lite, pcsc-lite-ccid, nss-tools (in the image)
#   - Network on first run: the public DoD PKI bundle is downloaded from
#     public.cyber.mil (DOD_PKI_URL), verified (CMS signature chaining to a
#     PINNED DoD root + every file's sha256) and cached in
#     /var/lib/fedora-cosmic-atomic/dod-pki (root) or ~/.cache/dod-pki (user).
#     --refresh re-downloads. Offline: DOD_PKI_ZIP=/path/to/the.zip.
#
# Browser notes:
#   - Native Firefox/Chrome on Fedora load OpenSC through p11-kit automatically;
#     the modutil step below is belt-and-braces.
#   - Flatpak browsers (Firefox, Chrome) run in a sandbox where the host's
#     /usr/lib64/opensc-pkcs11.so does not exist. This script imports the DoD
#     certificates into their profiles and grants --socket=pcsc; whether the
#     runtime's own PKCS#11 stack sees the card must be tested. If it does not,
#     the Fedora-built Firefox flatpak (registry.fedoraproject.org) bundles
#     OpenSC and is the fallback.
#
set -euo pipefail

# shellcheck disable=SC1091
[[ -r /etc/fedora-cosmic-atomic/site.env ]] && source /etc/fedora-cosmic-atomic/site.env
if [[ $EUID -eq 0 ]]; then
    TARGET_USER="${SUDO_USER:-${SITE_USER:-}}"
    [[ -n "${TARGET_USER}" && "${TARGET_USER}" != root ]] || TARGET_USER="${SITE_USER:-}"
else
    TARGET_USER=$(id -un)
fi
USER_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6 || true)
OPENSC_LIB="/usr/lib64/opensc-pkcs11.so"
FLATPAK_BROWSERS=(org.mozilla.firefox com.google.Chrome)

DOD_PKI_URL="${DOD_PKI_URL:-https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip}"
SYSTEM_PKI_CACHE=/var/lib/fedora-cosmic-atomic/dod-pki
# SHA-256 fingerprints of the DoD roots allowed to sign the bundle's checksum
# file. Root CA 6 was cross-checked 2026-10-01 against crl.disa.mil (same key
# as DISA's cross-certificates; it verifies all 21 CAs DISA lists under it);
# Root CA 3 against an independent 2024 bundle. A new root = edit this list
# after checking it at https://crl.disa.mil (README.txt in the bundle says how).
DOD_ROOT_PINS=(
    "2A:5E:41:AC:A9:3D:F7:CC:49:6D:23:69:B7:A0:A0:37:04:5D:50:2F:1A:BA:AF:76:97:5F:C0:7C:66:60:CF:93"  # DoD Root CA 6
    "B1:07:B3:3F:45:3E:55:10:F6:8E:51:31:10:C6:F6:94:4B:AC:C2:63:DF:01:37:F8:21:C1:B3:C2:F8:F8:63:D2"  # DoD Root CA 3
)
REFRESH=0

# ─── Helpers ─────────────────────────────────────────────────────────
# Verify an extracted bundle dir: the signer's root (first cert of
# DoD_PKE_CA_chain.pem) must be self-signed and pinned, the CMS signature on
# *.sha256 must verify against it, and every listed file must match.
verify_bundle() {
    local dir="$1" sumfile root fp pin ok=0 tmp
    sumfile=$(find "${dir}" -maxdepth 1 -name '*.sha256' | head -1)
    [[ -f "${sumfile}" && -f "${dir}/DoD_PKE_CA_chain.pem" ]] || { echo "ERROR: ${dir}: no signed checksum file / CA chain" >&2; return 1; }
    tmp=$(mktemp -d); root="${tmp}/root.pem"
    openssl x509 -in "${dir}/DoD_PKE_CA_chain.pem" -out "${root}"
    [[ "$(openssl x509 -in "${root}" -noout -subject | cut -d= -f2-)" == "$(openssl x509 -in "${root}" -noout -issuer | cut -d= -f2-)" ]] \
        || { echo "ERROR: bundle signer root is not self-signed" >&2; rm -rf "${tmp}"; return 1; }
    fp=$(openssl x509 -in "${root}" -noout -fingerprint -sha256 | cut -d= -f2)
    for pin in "${DOD_ROOT_PINS[@]}"; do [[ "${fp}" == "${pin}" ]] && ok=1; done
    [[ "${ok}" == 1 ]] || { echo "ERROR: bundle root ${fp} is not a pinned DoD root" >&2; rm -rf "${tmp}"; return 1; }
    # DoD signs the checksum file with SHA-1, which Fedora's OpenSSL refuses by
    # default; allow it for this one verification only (the root is pinned, the
    # download is HTTPS, and the per-file sums it carries are SHA-256).
    printf 'openssl_conf = openssl_init\n[openssl_init]\nalg_section = evp_properties\n[evp_properties]\nrh-allow-sha1-signatures = yes\n' > "${tmp}/sha1.cnf"
    OPENSSL_CONF="${tmp}/sha1.cnf" openssl cms -verify -inform DER -in "${sumfile}" -CAfile "${root}" -certfile "${dir}/DoD_PKE_CA_chain.pem" \
        -purpose any -out "${tmp}/sums" 2>/dev/null || { echo "ERROR: checksum file signature does not verify" >&2; rm -rf "${tmp}"; return 1; }
    (cd "${dir}" && sed 's/\r$//' "${tmp}/sums" | sha256sum --quiet -c -) || { echo "ERROR: bundle files do not match the signed checksums" >&2; rm -rf "${tmp}"; return 1; }
    rm -rf "${tmp}"
}

# Prints the verified bundle directory; downloads into the cache when needed.
find_cert_bundle() {
    local cache dir tmp
    if [[ $EUID -eq 0 ]]; then cache="${SYSTEM_PKI_CACHE}"
    elif [[ "${REFRESH}" == 0 && -d "${SYSTEM_PKI_CACHE}/current" ]]; then cache="${SYSTEM_PKI_CACHE}"
    else cache="${XDG_CACHE_HOME:-${HOME}/.cache}/dod-pki"; fi
    dir="${cache}/current"
    if [[ "${REFRESH}" == 1 || ! -d "${dir}" ]]; then
        tmp=$(mktemp -d)
        if [[ -n "${DOD_PKI_ZIP:-}" ]]; then cp "${DOD_PKI_ZIP}" "${tmp}/dod.zip"
        else echo "   downloading ${DOD_PKI_URL}" >&2
             curl -fsSL --retry 3 --max-time 120 -o "${tmp}/dod.zip" "${DOD_PKI_URL}" || { echo "ERROR: download failed (offline? set DOD_PKI_ZIP)" >&2; rm -rf "${tmp}"; return 1; }
        fi
        unzip -q -o "${tmp}/dod.zip" -d "${tmp}/x"
        local new; new=$(find "${tmp}/x" -mindepth 1 -maxdepth 1 -type d -name 'Certificates_PKCS7_*' | sort -V | tail -1)
        [[ -n "${new}" ]] || { echo "ERROR: unexpected zip layout" >&2; rm -rf "${tmp}"; return 1; }
        verify_bundle "${new}" || { rm -rf "${tmp}"; return 1; }
        mkdir -p "${cache}"; rm -rf "${dir}"; mv "${new}" "${dir}"; chmod -R a+rX "${cache}"
        rm -rf "${tmp}"
        echo "   verified $(basename "$(find "${dir}" -maxdepth 1 -name '*.sha256')" .sha256) -> ${dir}" >&2
    else
        verify_bundle "${dir}" || { echo "   cached bundle failed verification — rerun with --refresh" >&2; return 1; }
    fi
    echo "${dir}"
}

# Split a DER PKCS7 bundle into cert_N.pem files; prints the count.
extract_certs_from_p7b() {
    local p7b_file="$1" output_dir="$2"
    openssl pkcs7 -print_certs -in "${p7b_file}" -inform DER 2>/dev/null | \
        awk -v outdir="${output_dir}" '
            /-----BEGIN CERTIFICATE-----/ { n++; fname = outdir "/cert_" n ".pem"; p = 1 }
            p { print > fname }
            /-----END CERTIFICATE-----/ { p = 0 }'
    find "${output_dir}" -name "cert_*.pem" 2>/dev/null | wc -l
}

get_cert_cn() {
    local cn
    cn=$(openssl x509 -in "$1" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    echo "${cn:-$2}"
}

import_p7b_to_nss() {
    local p7b_file="$1" nss_db="$2" bundle_name extract_dir num_certs imported=0 i=1 cn
    bundle_name=$(basename "${p7b_file}" .der.p7b)
    extract_dir=$(mktemp -d)
    num_certs=$(extract_certs_from_p7b "${p7b_file}" "${extract_dir}")
    for cert_file in "${extract_dir}"/cert_*.pem; do
        [[ -f "${cert_file}" ]] || continue
        cn=$(get_cert_cn "${cert_file}" "${bundle_name}_cert_${i}")
        certutil -A -d sql:"${nss_db}" -n "${cn}" -t "CT,," -i "${cert_file}" 2>/dev/null && imported=$((imported + 1))
        i=$((i + 1))
    done
    echo "     ${imported}/${num_certs} certs imported (${bundle_name}) -> ${nss_db}"
    rm -rf "${extract_dir}"
}

add_opensc_module() {  # nss db dir
    if modutil -dbdir sql:"$1" -list 2>/dev/null | grep -qi "OpenSC\|CAC Card"; then
        echo "     OpenSC module already loaded"
    elif modutil -dbdir sql:"$1" -add "CAC Card" -libfile "${OPENSC_LIB}" -force >/dev/null 2>&1; then
        echo "     OpenSC PKCS#11 module added"
    else
        echo "     (could not add OpenSC module — p11-kit proxy may already provide it)"
    fi
}

configure_profile() {  # profile dir, label, flatpak?(1/0)
    local profile_path="$1" label="$2" is_flatpak="${3:-0}" p7b
    echo "   ${label}:"
    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        import_p7b_to_nss "${p7b}" "${profile_path}"
    done
    if [[ "${is_flatpak}" == 1 ]]; then
        echo "     (flatpak: OpenSC module path differs inside the sandbox — relying on --socket=pcsc)"
    else
        add_opensc_module "${profile_path}"
    fi
}

# ─── Check ───────────────────────────────────────────────────────────
do_check() {
    echo "=== CAC/Smart Card Status ==="
    printf '1. pcscd.socket: %s / %s\n' "$(systemctl is-active pcscd.socket 2>/dev/null)" "$(systemctl is-enabled pcscd.socket 2>/dev/null)"
    printf '2. OpenSC p11-kit module: %s, library: %s\n' \
        "$([[ -f /usr/share/p11-kit/modules/opensc.module ]] && echo present || echo MISSING)" \
        "$([[ -f "${OPENSC_LIB}" ]] && echo present || echo MISSING)"
    printf '3. DoD certs in system trust: %s\n' "$(trust list 2>/dev/null | grep -ci 'DoD' || true)"
    printf '4. DoD certs in ~/.pki/nssdb: %s\n' "$(certutil -L -d sql:"${USER_HOME}/.pki/nssdb" 2>/dev/null | grep -ci 'DoD' || true)"
    local db
    for db in "${USER_HOME}"/.mozilla/firefox/*.default*/ \
              "${USER_HOME}"/.var/app/org.mozilla.firefox/.mozilla/firefox/*.default*/ \
              "${USER_HOME}"/.var/app/com.google.Chrome/.pki/nssdb/ ; do
        [[ -f "${db}/cert9.db" ]] || continue
        printf '5. %s: %s DoD certs, OpenSC module %s\n' "${db}" \
            "$(certutil -L -d sql:"${db}" 2>/dev/null | grep -ci 'DoD' || true)" \
            "$(modutil -dbdir sql:"${db}" -list 2>/dev/null | grep -qi 'opensc\|CAC' && echo loaded || echo 'not loaded')"
    done
    echo "6. Flatpak pcsc overrides:"
    for app in "${FLATPAK_BROWSERS[@]}"; do
        printf '   %s: %s\n' "${app}" "$( (flatpak override --show --system "${app}" 2>/dev/null; flatpak override --show --user "${app}" 2>/dev/null) | grep -q pcsc && echo granted || echo none)"
    done
    echo "7. Reader:"; opensc-tool --list-readers 2>&1 | sed 's/^/   /' | head -5
}

# ─── System half (root) ──────────────────────────────────────────────
do_system() {
    [[ $EUID -eq 0 ]] || { echo "ERROR: --system needs root" >&2; exit 1; }
    echo "[system] enabling pcscd.socket"
    systemctl enable --now pcscd.socket
    [[ -f /usr/share/p11-kit/modules/opensc.module ]] || echo "   WARNING: opensc.module missing — is opensc installed?"
    [[ -f "${OPENSC_LIB}" ]] || echo "   WARNING: ${OPENSC_LIB} missing"

    echo "[system] installing DoD roots into the system trust store"
    CERT_BUNDLE=$(find_cert_bundle)
    local p7b name extract_dir num_certs installed cert_file cn safe_cn
    for p7b in "${CERT_BUNDLE}"/*.der.p7b; do
        [[ -f "${p7b}" ]] || continue
        name=$(basename "${p7b}" .der.p7b)
        extract_dir=$(mktemp -d); installed=0
        num_certs=$(extract_certs_from_p7b "${p7b}" "${extract_dir}")
        for cert_file in "${extract_dir}"/cert_*.pem; do
            [[ -f "${cert_file}" ]] || continue
            cn=$(get_cert_cn "${cert_file}" "${name}")
            safe_cn=$(echo "${cn}" | tr ' /' '__')
            install -m 0644 "${cert_file}" "/etc/pki/ca-trust/source/anchors/${safe_cn}.crt"
            installed=$((installed + 1))
        done
        echo "   ${name}: ${installed}/${num_certs} certs -> /etc/pki/ca-trust/source/anchors/"
        rm -rf "${extract_dir}"
    done
    update-ca-trust extract
    echo "   system trust store updated"
}

# ─── User half ───────────────────────────────────────────────────────
do_user() {
    [[ $EUID -ne 0 ]] || { echo "ERROR: --user must run as ${TARGET_USER}, not root" >&2; exit 1; }
    CERT_BUNDLE=$(find_cert_bundle)

    echo "[user] ~/.pki/nssdb (Chrome and other NSS apps)"
    mkdir -p "${USER_HOME}/.pki/nssdb"
    [[ -f "${USER_HOME}/.pki/nssdb/cert9.db" ]] || certutil -N -d sql:"${USER_HOME}/.pki/nssdb" --empty-password
    configure_profile "${USER_HOME}/.pki/nssdb" "user NSS db" 0

    echo "[user] browser profiles"
    local profile
    for profile in "${USER_HOME}"/.mozilla/firefox/*.default*/; do
        [[ -d "${profile}" ]] && configure_profile "${profile}" "Firefox native ($(basename "${profile}"))" 0
    done
    for profile in "${USER_HOME}"/.var/app/org.mozilla.firefox/.mozilla/firefox/*.default*/; do
        [[ -d "${profile}" ]] && configure_profile "${profile}" "Firefox flatpak ($(basename "${profile}"))" 1
    done
    # Flatpak Chrome keeps its own NSS db inside the sandbox home.
    local chrome_db="${USER_HOME}/.var/app/com.google.Chrome/.pki/nssdb"
    if [[ -d "${USER_HOME}/.var/app/com.google.Chrome" ]]; then
        mkdir -p "${chrome_db}"
        [[ -f "${chrome_db}/cert9.db" ]] || certutil -N -d sql:"${chrome_db}" --empty-password
        configure_profile "${chrome_db}" "Chrome flatpak NSS db" 1
    fi

    echo "[user] pcsc socket for flatpak browsers"
    local app
    for app in "${FLATPAK_BROWSERS[@]}"; do
        flatpak override --user --socket=pcsc "${app}" 2>/dev/null && echo "   ${app}: granted" || echo "   ${app}: override failed"
    done
}

# ─── Main ────────────────────────────────────────────────────────────
[[ "${1:-}" == --refresh ]] && { REFRESH=1; shift; }
[[ "${1:-}" == --fetch ]] && { find_cert_bundle; exit; }
[[ -n "${USER_HOME}" ]] || { echo "ERROR: cannot determine the target user (run as your user, or set SITE_USER in /etc/fedora-cosmic-atomic/site.env)" >&2; exit 1; }
case "${1:-}" in
    --check)  do_check ;;
    --system) do_system ;;
    --user)   do_user ;;
    "")
        if [[ $EUID -eq 0 ]]; then
            echo "Run without arguments as your user; it will sudo for the system half." >&2; exit 1
        fi
        sudo "$0" --system
        do_user   # reuses the bundle --system just verified
        echo ""
        echo "=== CAC setup complete === Insert the card and run: setup-cac.sh --check"
        echo "Restart browsers. Test: pkcs11-tool --list-objects --type cert"
        ;;
    *) echo "Usage: setup-cac.sh [--refresh] [--system|--user|--check|--fetch]"; exit 1 ;;
esac
