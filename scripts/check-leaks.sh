#!/usr/bin/env bash
#
# check-leaks.sh — fail if personal values crept into the repo or an image.
#
#   scripts/check-leaks.sh                 # tracked files in this repo
#   scripts/check-leaks.sh --image IMG     # files the image ships (podman)
#
# Generic patterns always apply (CI has no site.env); with
# scripts/targets/site.env present its exact values are checked too
# (SITE_USER as a word), plus every UUID in scripts/targets/*.env and its
# 8-character prefix.
# Exit 0 = clean, 1 = leak found.
#
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

# Generic: home/media paths with a real user name, any non-placeholder UUID,
# the old DoD bundle location, tailnet names, personal mail.
GENERIC='/home/[a-z_][a-z0-9_-]*|/run/media/[a-z_][a-z0-9_-]*|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|Military|ts\.net|@gmail\.com'
ALLOW='/home/linuxbrew|00000000-0000-0000-0000-000000000000'

FIXED=()
if [[ -f scripts/targets/site.env ]]; then
    # shellcheck disable=SC1091
    source scripts/targets/site.env
fi
# Every real UUID known locally (site.env + the gitignored target files), and
# its first 8 characters: docs tend to abbreviate ("1a2b3c4d-…").
KNOWN_UUIDS=$(cat scripts/targets/*.env 2>/dev/null \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\b[0-9A-F]{4}-[0-9A-F]{4}\b' \
    | grep -v '^00000000-' | sort -u || true)
for v in $KNOWN_UUIDS; do FIXED+=(-e "$v"); [[ ${#v} -gt 9 ]] && FIXED+=(-e "${v:0:8}"); done

scan_repo() {
    local hits
    hits=$(git grep -nIE "$GENERIC" -- ':!scripts/check-leaks.sh' | grep -vE "$ALLOW" || true)
    if [[ -n "${SITE_USER:-}" ]]; then
        hits+=$'\n'$(git grep -nIw -e "$SITE_USER" -- ':!scripts/check-leaks.sh' || true)
    fi
    (( ${#FIXED[@]} )) && hits+=$'\n'$(git grep -nIF "${FIXED[@]}" -- ':!scripts/check-leaks.sh' || true)
    hits=$(sed '/^$/d' <<<"$hits")
    report "$hits"
}

scan_image() {
    local img="$1" dirs="/usr/bin /usr/share/distrobox /etc/fedora-cosmic-atomic /etc/profile.d /etc/environment.d /etc/containers /etc/systemd /usr/lib/systemd/system /usr/share/fedora-cosmic-atomic"
    local pat="$GENERIC"
    [[ -n "${SITE_USER:-}" ]] && pat+="|\\b${SITE_USER}\\b"
    local v; for v in $KNOWN_UUIDS; do pat+="|$v"; [[ ${#v} -gt 9 ]] && pat+="|${v:0:8}"; done
    # Only files this repo puts into the image; base packages may legitimately
    # contain UUIDs (systemd units, policy files).
    local ours="/usr/bin/post-install-setup.sh /usr/bin/setup-cac.sh /usr/bin/enable-hibernation.sh /usr/bin/migrate-docker-to-podman.sh /usr/bin/win11-cac /usr/bin/prepare-disk.sh /usr/bin/make-target-env.sh /usr/bin/install-atomic.sh /usr/bin/cosmic-report /usr/share/distrobox/distrobox.ini /etc/fedora-cosmic-atomic /etc/profile.d/amd-common.sh /etc/environment.d/50-amd-common.conf"
    local hits
    hits=$("${CTR:-podman}" run --rm "$img" sh -c "grep -rnIE '$pat' $ours 2>/dev/null; grep -rlIE 'ts\.net|Military' $dirs 2>/dev/null" | grep -vE "$ALLOW" || true)
    report "$hits"
}

report() {
    if [[ -n "$1" ]]; then
        echo "LEAK CHECK FAILED — personal values found:"; echo "$1" | sed 's/^/  /'; exit 1
    fi
    if [[ -n "${SITE_USER:-}" ]]; then echo "leak check clean (generic + site.env values)"
    else echo "leak check clean (generic patterns only — no scripts/targets/site.env)"; fi
}

case "${1:-}" in
    --image) scan_image "${2:?--image IMG}" ;;
    "")      scan_repo ;;
    *)       echo "usage: $0 [--image IMG]" >&2; exit 2 ;;
esac
