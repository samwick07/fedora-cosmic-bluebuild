#!/usr/bin/env bash
#
# cosmic-acceptance — the automatic part of the spec's acceptance checklist (end-state.md
# section 6) for the IMAGE layer on an installed machine. Read-only: it changes nothing.
#
#   sudo cosmic-acceptance            image-layer checks + the list of manual checks
#   sudo cosmic-acceptance --user     also the user-layer checks (after chezmoi init --apply)
#
# PASS / FAIL per check, MANUAL for what a person has to try. Exit 1 if anything failed.
# The smoke test checks the image as a container in CI; this checks the booted machine.
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo (reads bootc, btrfs and LUKS state)" >&2; exit 2; }
USER_LAYER=0; [[ "${1:-}" == --user ]] && USER_LAYER=1
U="${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}"
UHOME=$(getent passwd "$U" | cut -d: -f6)
FAILED=0
. /usr/lib/os-release

pass() { printf 'PASS    %-9s %s\n' "$1" "$2"; }
fail() { printf 'FAIL    %-9s %s\n' "$1" "$2"; FAILED=1; }
check() {  # id, description, command...
    local id="$1" desc="$2" out; shift 2
    if out=$("$@" 2>&1); then pass "$id" "$desc"; else fail "$id" "$desc"; [[ -n "$out" ]] && sed 's/^/                  /' <<<"$out"; fi
}
manual() { printf 'MANUAL  %-9s %s\n' "$1" "$2"; }
as_user() { runuser -u "$U" -- env HOME="$UHOME" XDG_RUNTIME_DIR="/run/user/$(id -u "$U")" "$@"; }
enabled() { local u; for u in "$@"; do [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == enabled ]] || { echo "$u is not enabled"; return 1; }; done; }

echo "== image layer — $(hostname), VARIANT_ID=${VARIANT_ID:-?}, $(date '+%F %R')"

# L1: the signed image, verified on every upgrade
check L1 "booted from the signed image (ostree-image-signed)" sh -c \
    'rpm-ostree status --booted --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"deployments\"][0]; r=d.get(\"container-image-reference\",\"\"); print(r); sys.exit(0 if r.startswith(\"ostree-image-signed:\") and \"fedora-cosmic-\" in r else 1)"'
# F2/P2: hibernation preconditions
check F2 "Secure Boot off (kernel lockdown would block hibernation)" sh -c \
    'l=$(bootctl status 2>/dev/null | grep -i "secure boot:"); echo "$l" | grep -qi disabled || { echo "${l:-bootctl reports no Secure Boot state}"; exit 1; }'
check P2 "kernel lockdown is none" sh -c 'grep -q "\[none\]" /sys/kernel/security/lockdown 2>/dev/null || { cat /sys/kernel/security/lockdown 2>/dev/null; exit 1; }'
check P2 "resume= and two rd.luks.uuid= on the kernel command line" sh -c \
    'c=$(cat /proc/cmdline); echo "$c" | grep -q "resume=" && [ "$(echo "$c" | grep -o "rd.luks.uuid=" | wc -l)" -ge 2 ] || { echo "$c"; exit 1; }'
check P2 "swap active and at least as large as RAM" sh -c \
    'ram=$(awk "/MemTotal/{print \$2*1024}" /proc/meminfo); sw=$(swapon --show=SIZE --bytes --noheadings | awk "{s+=\$1} END{print s+0}"); [ "$sw" -ge "$ram" ] || { echo "swap $sw < RAM $ram"; exit 1; }'
check P2 "lid closes into suspend-then-hibernate" sh -c 'systemd-analyze cat-config systemd/logind.conf | grep -q "^HandleLidSwitch=suspend-then-hibernate"'
check P2 "SELinux hibernation module loaded" sh -c 'semodule -l | grep -qx systemd_hibernate'
# P1/D1: boot and login
check P1 "graphical LUKS prompt (rhgb quiet)" sh -c 'grep -qw rhgb /proc/cmdline && grep -qw quiet /proc/cmdline'
check D1 "login waits for the greeter (cosmic-session-wait ran this boot)" sh -c 'journalctl -b -t cosmic-session-wait -q --no-pager | grep -q .'
# S2e/R1: home is its own btrfs subvolume
check S2e "/var/home is a btrfs subvolume (hourly snapshots, consistent backups)" sh -c \
    '[ "$(stat -f -c %T /var/home)" = btrfs ] && btrfs subvolume show /var/home >/dev/null'
# J1/L2: the one updater
check J1 "nightly job and catch-up timers enabled" enabled cosmic-nightly.timer cosmic-nightly-catchup.timer
check J1 "nightly job dry run" sh -c 'cosmic-nightly --dry-run >/dev/null'
check L2 "no second updater (bootc-fetch-apply-updates, brew timers)" sh -c \
    'for t in bootc-fetch-apply-updates.timer brew-update.timer brew-upgrade.timer; do [ "$(systemctl is-enabled $t 2>/dev/null)" != enabled ] || { echo "$t enabled"; exit 1; }; done'
# N1/N3: first boot jobs, Tailscale
check N1 "system flatpaks from the image's list installed" sh -c \
    'm=$(comm -13 <(flatpak list --system --app --columns=application | sort -u) <(grep -v "^#" /usr/share/fedora-cosmic-atomic/flatpaks.list | sed "/^$/d" | sort -u)); [ -z "$m" ] || { echo "missing: $m"; exit 1; }'
check N3 "tailscaled running" systemctl is-active --quiet tailscaled
# V1/V2: virtualization
check V1 "libvirt sockets enabled" enabled virtqemud.socket virtnetworkd.socket virtstoraged.socket
check V1 "$U is in the libvirt group" sh -c "id -nG '$U' | tr ' ' '\n' | grep -qx libvirt"
check V1 "virt-manager, virt-viewer, SPICE USB redirection installed" rpm -q virt-manager virt-viewer qemu-device-usb-redirect
# V3/V4: CAC on the host
check V4 "DoD roots in the system trust (offline)" sh -c 'n=$(trust list | grep -ci dod); [ "$n" -ge 10 ] || { echo "only $n"; exit 1; }'
check V3 "pcscd socket enabled" enabled pcscd.socket
# C1: Homebrew unpacked for the user
check C1 "Homebrew unpacked and owned by $U" sh -c "[ -x /home/linuxbrew/.linuxbrew/bin/brew ] && [ \"\$(stat -c %U /home/linuxbrew/.linuxbrew)\" = '$U' ]"
# P9/P6 preconditions
check P9 "TPM2 module in the initramfs config" test -f /usr/lib/dracut/dracut.conf.d/90-tpm2.conf
check P6 "fingerprint daemon installed" rpm -q fprintd fprintd-pam

if [[ $USER_LAYER == 1 ]]; then
    echo; echo "== user layer — $U"
    check C1 "every formula in ~/.Brewfile installed" as_user /home/linuxbrew/.linuxbrew/bin/brew bundle check --file "$UHOME/.Brewfile" --no-upgrade
    check D9 "dotfiles in their declared state (chezmoi status empty)" sh -c "out=\$(runuser -u '$U' -- env HOME='$UHOME' PATH=\"/usr/bin:/home/linuxbrew/.linuxbrew/bin\" chezmoi status); [ -z \"\$out\" ] || { echo \"\$out\"; exit 1; }"
    check E9 "boxes dev, claude, rocm exist" sh -c "for b in dev claude rocm; do runuser -u '$U' -- podman container exists \$b || { echo \"missing \$b\"; exit 1; }; done"
    check S1 "Syncthing user service enabled" sh -c "runuser -u '$U' -- env XDG_RUNTIME_DIR=/run/user/\$(id -u '$U') systemctl --user is-enabled --quiet syncthing.service"
    check V3 "OpenSC in Chrome's NSS database (dev box)" sh -c "runuser -u '$U' -- env HOME='$UHOME' modutil -dbdir sql:'$UHOME/.pki/nssdb' -list 2>/dev/null | grep -qiE 'opensc|p11-kit' || runuser -u '$U' -- distrobox enter dev -- modutil -dbdir sql:'$UHOME/.pki/nssdb' -list | grep -qiE 'opensc|p11-kit'"
fi

echo; echo "== manual checks (spec section 6)"
manual P1  "cold boot x3: LUKS prompt, then the COSMIC greeter"
manual P2  "systemctl hibernate -> resume; lid closed 5 min -> hibernates; 10 suspend-then-hibernate cycles, note the drain"
manual P3  "lid close/open: suspend and resume; Bluetooth reconnects"
manual P4  "Wi-Fi, Bluetooth, audio, webcam, USB-C display"
manual P6  "fprintd-enroll; sudo and the COSMIC lock screen accept the finger"
manual P9  "after systemd-cryptenroll --tpm2-with-pin: boot and resume ask for the PIN; the passphrase still works"
manual P10 "a test page prints"
manual D1  "10 logins without a black screen"
manual V2  "SPICE-redirect the CAC reader into the VM -> certutil -scinfo -> the Windows app signs in; also win11-cac attach/detach"
manual V3  "PIN prompt and login on a DoD site in Chrome (dev) and in Firefox"
manual N4  "VPN trial: each method connects; routes and DNS from host, dev and a podman container"
manual S2  "after a night: the report shows a backup < 26 h old; restore one file from the DAS and one from B2"
manual L3  "after acceptance: sudo ostree admin pin 0 (keep this deployment as known-good)"

echo
if [[ $FAILED == 0 ]]; then echo "== automatic checks PASSED — now the manual ones"; else echo "== automatic checks FAILED"; exit 1; fi
