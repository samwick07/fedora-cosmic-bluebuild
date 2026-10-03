#!/usr/bin/env bash
#
# install-dod-roots.sh — BUILD STEP (spec V4): put the DoD PKI CA certificates into
# the image's system trust, so a fresh install trusts DoD sites in Firefox, curl and
# podman with no network and no setup script. The nightly CI build keeps them current.
#
# The public DoD bundle is downloaded and verified exactly as setup-cac.sh did at
# runtime: the signer's root must be self-signed and one of the PINNED roots below,
# the CMS signature on the checksum file must verify against it, and every file must
# match its signed SHA-256. Any failure stops the build.
#
# openssl is installed for this step only and removed again (the base image has
# only the libraries; F9 keeps the CLI out of the running system).
#
set -euo pipefail

DOD_PKI_URL="${DOD_PKI_URL:-https://dl.dod.cyber.mil/wp-content/uploads/pki-pke/zip/unclass-certificates_pkcs7_DoD.zip}"
ANCHORS=/usr/share/pki/ca-trust-source/anchors
# SHA-256 fingerprints of the DoD roots allowed to sign the bundle's checksum file.
# Root CA 6 was cross-checked 2026-10-01 against crl.disa.mil; Root CA 3 against an
# independent 2024 bundle. A new root = add it here after checking it at
# https://crl.disa.mil (README.txt in the bundle says how).
DOD_ROOT_PINS=(
    "2A:5E:41:AC:A9:3D:F7:CC:49:6D:23:69:B7:A0:A0:37:04:5D:50:2F:1A:BA:AF:76:97:5F:C0:7C:66:60:CF:93"  # DoD Root CA 6
    "B1:07:B3:3F:45:3E:55:10:F6:8E:51:31:10:C6:F6:94:4B:AC:C2:63:DF:01:37:F8:21:C1:B3:C2:F8:F8:63:D2"  # DoD Root CA 3
)

had_openssl=1
command -v openssl >/dev/null || { had_openssl=0; dnf -y -q install openssl >/dev/null; }
cleanup() { rm -rf "$work"; [[ $had_openssl == 1 ]] || dnf -y -q remove openssl >/dev/null || true; }
work=$(mktemp -d); trap cleanup EXIT

echo "downloading $DOD_PKI_URL"
curl -fsSL --retry 3 --max-time 180 -o "$work/dod.zip" "$DOD_PKI_URL"
python3 -m zipfile -e "$work/dod.zip" "$work/x"
dir=$(find "$work/x" -mindepth 1 -maxdepth 1 -type d -name 'Certificates_PKCS7_*' | sort -V | tail -1)
[[ -n "$dir" ]] || { echo "unexpected zip layout"; exit 1; }

# ── verify ──
sumfile=$(find "$dir" -maxdepth 1 -name '*.sha256' | head -1)
[[ -f "$sumfile" && -f "$dir/DoD_PKE_CA_chain.pem" ]] || { echo "no signed checksum file / CA chain"; exit 1; }
openssl x509 -in "$dir/DoD_PKE_CA_chain.pem" -out "$work/root.pem"
[[ "$(openssl x509 -in "$work/root.pem" -noout -subject | cut -d= -f2-)" == "$(openssl x509 -in "$work/root.pem" -noout -issuer | cut -d= -f2-)" ]] \
    || { echo "bundle signer root is not self-signed"; exit 1; }
fp=$(openssl x509 -in "$work/root.pem" -noout -fingerprint -sha256 | cut -d= -f2)
ok=0; for pin in "${DOD_ROOT_PINS[@]}"; do [[ "$fp" == "$pin" ]] && ok=1; done
[[ $ok == 1 ]] || { echo "bundle root $fp is not a pinned DoD root"; exit 1; }
# DoD signs the checksum file with SHA-1, which Fedora's OpenSSL refuses by default;
# allowed for this one verification (pinned root, HTTPS, SHA-256 sums inside).
printf 'openssl_conf = openssl_init\n[openssl_init]\nalg_section = evp_properties\n[evp_properties]\nrh-allow-sha1-signatures = yes\n' > "$work/sha1.cnf"
OPENSSL_CONF="$work/sha1.cnf" openssl cms -verify -inform DER -in "$sumfile" -CAfile "$work/root.pem" \
    -certfile "$dir/DoD_PKE_CA_chain.pem" -purpose any -out "$work/sums" 2>/dev/null \
    || { echo "checksum file signature does not verify"; exit 1; }
(cd "$dir" && sed 's/\r$//' "$work/sums" | sha256sum --quiet -c -) || { echo "bundle files do not match the signed checksums"; exit 1; }
echo "verified $(basename "$sumfile" .sha256) (root $fp)"

# ── install every CA certificate of every PKCS#7 file as an anchor ──
install -d "$ANCHORS"
n=0
for p7b in "$dir"/*.der.p7b; do
    [[ -f "$p7b" ]] || continue
    openssl pkcs7 -print_certs -inform DER -in "$p7b" \
        | awk -v out="$work/c" '/-----BEGIN CERTIFICATE-----/{i++; f=out"_"i".pem"; p=1} p{print > f} /-----END CERTIFICATE-----/{p=0}'
done
for c in "$work"/c_*.pem; do
    [[ -f "$c" ]] || continue
    cn=$(openssl x509 -in "$c" -noout -subject | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p')
    safe=$(printf '%s' "${cn:-cert}" | tr -c 'A-Za-z0-9._-' '_')
    install -m 0644 "$c" "$ANCHORS/dod-${safe}.crt"
    n=$((n + 1))
done
(( n > 10 )) || { echo "only $n certificates found — refusing a partial trust set"; exit 1; }
update-ca-trust extract
echo "installed $n DoD CA certificates into $ANCHORS (system trust updated)"
