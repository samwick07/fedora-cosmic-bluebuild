#!/usr/bin/env bash
#
# smoke-test.sh — checks a built image before it is installed or pushed.
# Used by hand (docs/local-build.md) and by the CI workflow, which only pushes
# when this passes.
#
#   scripts/smoke-test.sh IMAGE        e.g. ghcr.io/samwick07/fedora-cosmic-frmwrk:latest_linux_amd64
#
# CTR=docker to use docker instead of podman. Needs network (DoD PKI fetch).
#
set -uo pipefail
cd "$(dirname "$(readlink -f "$0")")/.." || exit 2

IMG="${1:?usage: smoke-test.sh IMAGE}"
CTR="${CTR:-podman}"
NAME="${IMG##*/}"; NAME="${NAME%%:*}"            # fedora-cosmic-frmwrk
FAILED=0

run() { "$CTR" run --rm "$IMG" "$@"; }
check() {  # description, command...
    local desc="$1"; shift
    if out=$("$@" 2>&1); then printf 'ok    %s\n' "$desc"
    else printf 'FAIL  %s\n%s\n' "$desc" "$(sed 's/^/      /' <<<"$out")"; FAILED=1; fi
}

variant=$(run sh -c '. /usr/lib/os-release; echo "$VARIANT_ID"')
echo "== $IMG (VARIANT_ID=$variant)"

check "bootc present"            run bootc --version
check "shipped scripts executable" run sh -c 'for f in /usr/bin/post-install-setup.sh /usr/bin/setup-cac.sh /usr/bin/enable-hibernation.sh /usr/bin/win11-cac /usr/bin/migrate-docker-to-podman.sh /usr/bin/install-to-disk.sh /usr/bin/prepare-disk.sh /usr/bin/make-target-env.sh /usr/bin/install-atomic.sh /usr/bin/cosmic-report; do test -x "$f" || { echo "not executable: $f"; exit 1; }; done'
check "shipped data readable (644)" run sh -c 'for f in /usr/share/distrobox/distrobox.ini /etc/profile.d/amd-common.sh /etc/environment.d/50-amd-common.conf /etc/fedora-cosmic-atomic/restore-allowlist.txt; do [ "$(stat -c %a "$f")" = 644 ] || { stat -c "%a %n" "$f"; exit 1; }; done'
check "packages installed"       run rpm -q tailscale restic syncthing chezmoi age ghostty starship swtpm edk2-ovmf NetworkManager-openvpn openssl nss-tools distrobox
check "base fallbacks kept"      run rpm -q firefox toolbox
check "no stray top-level dirs"  run bash -c 'x=$(ls / | grep -vE "^(afs|bin|boot|dev|etc|home|lib|lib64|media|mnt|opt|ostree|proc|root|run|sbin|srv|sys|sysroot|tmp|usr|var)$"); [ -z "$x" ] || { echo "$x"; exit 1; }'
check "shell scripts parse"      run sh -c 'for f in /usr/bin/post-install-setup.sh /usr/bin/setup-cac.sh /usr/bin/enable-hibernation.sh /usr/bin/win11-cac /usr/bin/migrate-docker-to-podman.sh /usr/bin/install-to-disk.sh /usr/bin/prepare-disk.sh /usr/bin/make-target-env.sh /usr/bin/install-atomic.sh /usr/bin/cosmic-report; do bash -n "$f" || exit 1; done'
if [[ "$variant" == frmwrk ]]; then
    check "lid -> suspend-then-hibernate" run grep -q '^HandleLidSwitch=suspend-then-hibernate' /etc/systemd/logind.conf.d/10-lid.conf
    check "fprintd installed"     run rpm -q fprintd
fi
# Updates are staged, never applied automatically (no surprise reboots).
check "bootc timer enabled, stage-only" run sh -c '
    [ "$(systemctl is-enabled bootc-fetch-apply-updates.timer)" = enabled ] || { echo "timer not enabled"; exit 1; }
    d=/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf
    [ "$(stat -c %a $d)" = 644 ] || { echo "drop-in mode $(stat -c %a $d)"; exit 1; }
    last=$(cat /usr/lib/systemd/system/bootc-fetch-apply-updates.service $d | grep "^ExecStart=" | tail -1)
    [ "$last" = "ExecStart=/usr/bin/bootc upgrade --quiet" ] || { echo "effective: $last"; exit 1; }'
# Signing policy must name the published image (fix-signing-registry.sh).
# Checked by content: the registries.d file name differs between builds.
check "signing policy for ghcr.io/samwick07/$NAME" run sh -c "
    grep -q '\"ghcr.io/samwick07/$NAME\"' /etc/containers/policy.json || { echo 'policy.json: no entry for ghcr.io/samwick07/$NAME'; exit 1; }
    ! grep -q '\"localhost/' /etc/containers/policy.json || { echo 'policy.json: localhost/ entry left'; exit 1; }
    grep -lq 'ghcr.io/samwick07/$NAME:' /etc/containers/registries.d/*.yaml || { echo 'registries.d: no sigstore config for the image'; exit 1; }
    grep -rq 'use-sigstore-attachments: true' /etc/containers/registries.d/ || { echo 'registries.d: sigstore attachments off'; exit 1; }
    test -f /etc/pki/containers/$NAME.pub || { echo 'missing /etc/pki/containers/$NAME.pub'; exit 1; }"
check "image pubkey == repo cosign.pub" bash -c "cmp <($CTR run --rm '$IMG' cat /etc/pki/containers/$NAME.pub) cosign.pub"
# CAC: the public DoD bundle downloads and verifies (pinned root, signed sums).
check "setup-cac.sh --fetch (DoD PKI verified)" run setup-cac.sh --fetch
# Public repo + public image: no personal values.
check "leak check: repo"         scripts/check-leaks.sh
check "leak check: image"        env CTR="$CTR" scripts/check-leaks.sh --image "$IMG"

if [[ "$FAILED" == 0 ]]; then echo "== smoke test PASSED"; else echo "== smoke test FAILED"; exit 1; fi
