#!/usr/bin/env bash
#
# smoke-test.sh — checks a built image before it is installed or pushed.
# Used by hand (docs/local-build.md) and by the CI workflow, which only pushes
# when this passes.
#
#   scripts/smoke-test.sh IMAGE        e.g. ghcr.io/samwick07/fedora-cosmic-frmwrk:latest_linux_amd64
#
# CTR=docker to use docker instead of podman. Run from the repo root (compares
# files/share/flatpaks.list with the recipe).
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
    else printf 'FAIL  %s\n%s\n' "$desc" "$(sed 's/^/      /' <<<"$out")"; FAILED=1
         # In CI also as an annotation: readable on the PR page and through the API
         # without downloading the job log.
         [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error title=smoke test::%s: %s\n' "$desc" "$(head -c 900 <<<"$out" | sed ':a;N;$!ba;s/%/%25/g;s/\n/%0A/g')"
    fi
}

variant=$(run sh -c '. /usr/lib/os-release; echo "$VARIANT_ID"')
echo "== $IMG (VARIANT_ID=$variant)"

BIN="/usr/bin/cosmic-enroll /usr/libexec/cosmic-signed-origin /usr/libexec/cosmic-net-box /usr/libexec/cosmic-evidence /usr/bin/cosmic-acceptance /usr/libexec/libvirt-user-groups /usr/bin/cosmic-nightly /usr/bin/cosmic-nightly-notify /usr/bin/cosmic-session-wait /usr/bin/win11-cac /usr/bin/cac-status /usr/bin/cosmic-report"
DATA="/usr/lib/systemd/system/cosmic-nightly.service /usr/lib/systemd/system/cosmic-nightly.timer /usr/lib/systemd/system/cosmic-nightly-catchup.service /usr/lib/systemd/system/cosmic-nightly-catchup.timer /etc/xdg/autostart/cosmic-nightly-notify.desktop /usr/share/fedora-cosmic-atomic/flatpaks.list /usr/share/fedora-cosmic-atomic/drift-ignore.regex /usr/share/fedora-cosmic-atomic/nightly.example.env /usr/lib/systemd/system/system-flatpak-setup.service.d/20-retry.conf /usr/lib/systemd/user/user-flatpak-setup.service.d/20-retry.conf /usr/lib/modules-load.d/i2c-dev.conf /usr/lib/udev/rules.d/60-i2c-uaccess.rules /usr/lib/systemd/system/libvirt-relabel.service /usr/lib/systemd/system/libvirt-user-groups.service /usr/lib/systemd/system/cosmic-signed-origin.service /usr/lib/systemd/system/cosmic-net-box.service /usr/share/fedora-cosmic-atomic/net-box.ini /usr/share/fedora-cosmic-atomic/net-box.example.env /usr/lib/systemd/system/cosmic-evidence-sleep.service /usr/lib/systemd/system/cosmic-evidence-tunnel@.service /usr/lib/udev/rules.d/90-cosmic-evidence.rules"

check "bootc present"              run bootc --version
# The same lint the Universal Blue template runs on every build (/var content, kargs, …)
check "bootc container lint"       run bootc container lint
check "shipped scripts executable" run sh -c "for f in $BIN; do test -x \$f || { echo not executable: \$f; exit 1; }; done"
check "shell scripts parse"        run sh -c "for f in $BIN; do bash -n \$f || exit 1; done"
check "shipped data readable (644)" run sh -c "for f in $DATA; do [ \$(stat -c %a \$f) = 644 ] || { stat -c '%a %n' \$f; exit 1; }; done"
# F9: the whole layered set (plus what the base must keep providing)
check "layered packages (F9)"      run rpm -q tailscale NetworkManager-openconnect restic distrobox pcsc-lite pcsc-lite-ccid opensc firefox
# V1/V2: the virtualization stack, incl. what SPICE USB redirection needs (daily CAC path)
check "virtualization stack (V1)"  run rpm -q qemu-kvm qemu-img qemu-char-spice qemu-device-usb-redirect libvirt libvirt-daemon-kvm libvirt-nss edk2-ovmf swtpm swtpm-tools virt-manager virt-viewer
check "SPICE USB redirection helper (V2)" run sh -c 'ls /usr/libexec/spice-client-glib-usb-acl-helper /usr/libexec/spice-gtk-*/spice-client-glib-usb-acl-helper 2>/dev/null | grep -q . || { echo "spice-client-glib-usb-acl-helper missing"; exit 1; }'
check "libvirt units enabled (V1)" run sh -c 'for u in virtqemud.socket libvirt-relabel.service libvirt-user-groups.service; do [ "$(systemctl is-enabled $u)" = enabled ] || { echo "$u not enabled"; exit 1; }; done'
# C1: Homebrew ships in the image and unpacks at first boot; upgrades belong to J1
check "Homebrew set up at first boot (C1)" run sh -c '[ "$(systemctl is-enabled brew-setup.service)" = enabled ]'
check "no brew auto-update timers (J1)" run sh -c 'for t in brew-update.timer brew-upgrade.timer; do [ "$(systemctl is-enabled $t 2>/dev/null)" != enabled ] || { echo "$t enabled"; exit 1; }; done' 
# Packages the old plan layered: none may be added on top of the base. Compared with
# the base image itself, so something the base already ships (tmux, say) is not a failure.
NOT_LAYERED="ghostty starship topgrade chezmoi syncthing tmux openssl checkpolicy iio-sensor-proxy NetworkManager-openvpn"
BASE="$(sed -n 's/^base-image: *//p' recipes/recipe-*.yml | head -1):$(sed -n 's/^image-version: *//p' recipes/recipe-*.yml | head -1)"
in_image() { "$CTR" run --rm "$1" sh -c "rpm -q --qf '%{NAME}\\n' $NOT_LAYERED 2>/dev/null | grep -v 'not installed'" | sort; }
not_layered() {
    local x; x=$(comm -23 <(in_image "$IMG") <(in_image "$BASE"))
    [[ -z "$x" ]] || { echo "added on top of the base:" $x; return 1; }
}
check "nothing extra layered (F9, vs $BASE)" not_layered
check "no stray top-level dirs"    run bash -c 'x=$(ls / | grep -vE "^(afs|bin|boot|dev|etc|home|lib|lib64|media|mnt|opt|ostree|proc|root|run|sbin|srv|sys|sysroot|tmp|usr|var)$"); [ -z "$x" ] || { echo "$x"; exit 1; }'
# V4: DoD roots in the system trust, offline
check "DoD CAs in system trust (V4)" run sh -c 'n=$(trust list | grep -ci "DoD"); [ "$n" -ge 10 ] || { echo "only $n DoD entries"; exit 1; }'
# J1: the one updater; stages, never applies, never reboots
check "nightly timer enabled (J1)" run sh -c '[ "$(systemctl is-enabled cosmic-nightly.timer)" = enabled ]'
check "first-boot and net box units enabled (L1, N4)" run sh -c 'for u in cosmic-signed-origin.service cosmic-net-box.service; do [ "$(systemctl is-enabled $u)" = enabled ] || { echo "$u not enabled"; exit 1; }; done'
check "sleep recorder enabled (L5)" run sh -c '[ "$(systemctl is-enabled cosmic-evidence-sleep.service)" = enabled ]'
check "catch-up timer enabled (R1)" run sh -c '[ "$(systemctl is-enabled cosmic-nightly-catchup.timer)" = enabled ]'
check "nightly job never reboots"  run sh -c '! grep -vE "^[[:space:]]*#" /usr/bin/cosmic-nightly | grep -nE "bootc upgrade[^|]*--apply|bootc switch|systemctl (reboot|poweroff|kexec|soft-reboot)|shutdown -r|systemd-inhibit"'
check "no second updater"          run sh -c '[ "$(systemctl is-enabled bootc-fetch-apply-updates.timer 2>/dev/null)" != enabled ] || { echo "bootc-fetch-apply-updates.timer is enabled"; exit 1; }'
check "flatpaks.list == recipe"    bash -c "diff <(grep -v '^#' files/share/flatpaks.list | sed '/^\$/d' | sort) <(sed -n '/type: default-flatpaks/,/scope: user/p' recipes/common-modules.yml | sed -n 's/^ *- \([A-Za-z0-9._-]*\.[A-Za-z0-9._-]*\).*/\1/p' | sort)"
if [[ "$variant" == frmwrk ]]; then
    check "lid -> suspend-then-hibernate" run grep -q '^HandleLidSwitch=suspend-then-hibernate' /usr/lib/systemd/logind.conf.d/10-lid.conf
    check "fprintd + pam installed"    run rpm -q fprintd fprintd-pam
    check "hibernation kargs at boot (L1)" run sh -c '[ "$(systemctl is-enabled cosmic-hibernation.service)" = enabled ]'
    check "TPM2 in the initramfs config (P9)" run grep -q 'tpm2-tss' /usr/lib/dracut/dracut.conf.d/90-tpm2.conf
    # Graphical LUKS prompt; in text mode kernel messages scroll it away.
    check "kargs.d: rhgb quiet"   run sh -c 'k=$(cat /usr/lib/bootc/kargs.d/*.toml 2>/dev/null); for a in rhgb quiet; do printf "%s" "$k" | grep -q "\"$a\"" || { echo "missing karg $a in /usr/lib/bootc/kargs.d"; exit 1; }; done'
fi
# Login black screen workaround (cosmic-comp#2690): the session waits for the greeter.
check "cosmic.desktop -> cosmic-session-wait" run sh -c '
    f=/usr/share/wayland-sessions/cosmic.desktop
    grep -qx "Exec=/usr/bin/cosmic-session-wait" $f || { grep "^Exec" $f; exit 1; }
    grep -qx "exec /usr/bin/start-cosmic \"\$@\"" /usr/bin/cosmic-session-wait || { echo "wrapper does not exec start-cosmic"; exit 1; }
    test -x /usr/bin/start-cosmic || { echo "no /usr/bin/start-cosmic"; exit 1; }
    pgrep -u cosmic-greeter -x cosmic-comp; [ $? -le 1 ] || { echo "pgrep cannot resolve user cosmic-greeter"; exit 1; }'
# Signing policy must name the published image (fix-signing-registry.sh).
# Checked by content: the registries.d file name differs between builds.
check "signing policy for ghcr.io/samwick07/$NAME" run sh -c "
    grep -q '\"ghcr.io/samwick07/$NAME\"' /etc/containers/policy.json || { echo 'policy.json: no entry for ghcr.io/samwick07/$NAME'; exit 1; }
    ! grep -q '\"localhost/' /etc/containers/policy.json || { echo 'policy.json: localhost/ entry left'; exit 1; }
    grep -lq 'ghcr.io/samwick07/$NAME:' /etc/containers/registries.d/*.yaml || { echo 'registries.d: no sigstore config for the image'; exit 1; }
    grep -rq 'use-sigstore-attachments: true' /etc/containers/registries.d/ || { echo 'registries.d: sigstore attachments off'; exit 1; }
    test -f /etc/pki/containers/$NAME.pub || { echo 'missing /etc/pki/containers/$NAME.pub'; exit 1; }"
check "image pubkey == repo cosign.pub" bash -c "cmp <($CTR run --rm '$IMG' cat /etc/pki/containers/$NAME.pub) cosign.pub"
# Public repo + public image: no personal values.
check "leak check: repo"         scripts/check-leaks.sh
check "leak check: image"        env CTR="$CTR" scripts/check-leaks.sh --image "$IMG"

if [[ "$FAILED" == 0 ]]; then echo "== smoke test PASSED"; else echo "== smoke test FAILED"; exit 1; fi
