#!/usr/bin/env bash
#
# post-install-setup.sh — root half of bringing a Fedora Cosmic Atomic machine back.
#
# Clean-room model:
#   image   (this repo)      -> system            : already done by bootc install
#   restic  (DAS)            -> DATA, by allowlist : this script, step 2
#   chezmoi (dotfiles repo)  -> user config + brew + distrobox + flatpak overrides : step 6
# Nothing else from the old ~ is restored. Pull anything you miss later with
#   sudo restic -r <repo> restore latest --host <SITE_HOSTNAME> --target /var --include /home/<user>/<path>
#
# Shipped in the image at /usr/bin/post-install-setup.sh. Idempotent; completed
# steps are recorded in /var/lib/post-install-setup/.
#
# USAGE:
#   sudo post-install-setup.sh              # run all steps
#   sudo post-install-setup.sh --step N     # run only step N
#   post-install-setup.sh --list | --check
#
# PREREQUISITES:
#   - Booted into the custom image, logged in as SITE_USER, network up
#   - /etc/fedora-cosmic-atomic/site.env (copied there by install-atomic.sh from
#     scripts/targets/site.env): SITE_USER, DAS_LUKS_UUID, DAS_LABEL, RESTIC_REPO_DIR
#   - DAS attached (unlocked or not — step 1 handles it)
#   - You know the restic repository passphrase (the password file is inside
#     the backup, so the first restore prompts for it)
#
set -euo pipefail

# ─── Site values ──────────────────────────────────────────────────────
SITE_ENV="${SITE_ENV:-/etc/fedora-cosmic-atomic/site.env}"
# shellcheck disable=SC1090
[[ -r "${SITE_ENV}" ]] && source "${SITE_ENV}"
TARGET_USER="${SITE_USER:-${SUDO_USER:-}}"
[[ -n "${TARGET_USER}" && "${TARGET_USER}" != root ]] || { echo "ERROR: no SITE_USER in ${SITE_ENV} and not run via sudo"; exit 1; }
# /home/<user>, never $HOME (under sudo that is /root) and not getent's /var/home:
# restic snapshots from the Workstation store /home/<user>/..., and on Atomic
# /home -> var/home, so this one path works for --include and on disk.
USER_HOME="/home/${TARGET_USER}"
DAS_LUKS_UUID="${DAS_LUKS_UUID:-}"
DAS_MOUNT="/run/media/${TARGET_USER}/${DAS_LABEL:-DAS}"
RESTIC_REPO="${DAS_MOUNT}/${RESTIC_REPO_DIR:-frmwrk-restic-repo}"
RESTIC_PASSFILE="${USER_HOME}/.restic/frmwrk-repo.pass"
ALLOWLIST="${ALLOWLIST:-/etc/fedora-cosmic-atomic/restore-allowlist.txt}"
DOTFILES_REPO="${DOTFILES_REPO:-git@github.com:samwick07/dotfiles.git}"
STATE_DIR="/var/lib/post-install-setup"
# A test install runs for months beside the real machine, so it never takes over
# the real machine's network identities: Syncthing gets a new device ID (only the
# old config.xml is staged, for scripts/test/syncthing-test-device.sh) and
# Tailscale a new node. The real machine keeps syncing with dsktp meanwhile.
TEST_INSTALL=0
grep -qs '^TEST_INSTALL=1' /etc/fedora-cosmic-atomic/install-target.env && TEST_INSTALL=1
SYNCTHING_SOURCE_CONFIG="${USER_HOME}/.local/state/syncthing-source-config.xml"

# ─── Helpers ──────────────────────────────────────────────────────────
log()    { echo -e "\n\033[1;34m=== $* ===\033[0m"; }
ok()     { echo -e "  \033[0;32m✓\033[0m $*"; }
skip()   { echo -e "  \033[0;33m→\033[0m $* (already done, skipping)"; }
warn()   { echo -e "  \033[0;33m!\033[0m $*"; }
fail()   { echo -e "  \033[0;31m✗\033[0m $*"; }

uid() { id -u "${TARGET_USER}"; }
run_as_user() {
    sudo -u "${TARGET_USER}" HOME="${USER_HOME}" \
        XDG_RUNTIME_DIR="/run/user/$(uid)" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(uid)/bus" "$@"
}
restic_root() { RESTIC_REPOSITORY="${RESTIC_REPO}" RESTIC_PASSWORD_FILE="${RESTIC_PASSFILE}" restic "$@"; }
# Restore from the real machine's newest snapshot. A test install backs up as
# "<SITE_HOSTNAME>-test"; a bare `latest` would pick that sparse snapshot.
SNAP=(latest)
[[ -n "${SITE_HOSTNAME:-}" ]] && SNAP=(latest --host "${SITE_HOSTNAME}")
# /home is a symlink on Atomic's READ-ONLY root. Restoring through it restores
# the files but then fails (lchown on the symlink: EROFS, restic exits 1), so
# home paths go into the directory that really holds home (/var), the rest to /.
restore_target() { if [[ "$1" == /home/* && -L /home ]]; then dirname "$(readlink -f /home)"; else echo /; fi; }
restic_restore() { local path="$1"; shift; restic_root restore "${SNAP[@]}" --target "$(restore_target "$path")" --include "$path" "$@"; }
# Test install: only the old config.xml (folder IDs, paths, the dsktp device),
# never cert.pem/key.pem — those would make this disk a second "frmwrk".
stage_syncthing_source_config() {
    local dir="$1" tmp
    if [[ -s "${SYNCTHING_SOURCE_CONFIG}" ]]; then skip "${SYNCTHING_SOURCE_CONFIG}"; return; fi
    tmp=$(mktemp -d /var/tmp/syncthing-source.XXXXXX)
    restic_root restore "${SNAP[@]}" --target "${tmp}" --include "${dir}/config.xml" >/dev/null
    if [[ -s "${tmp}${dir}/config.xml" ]]; then
        install -D -o "${TARGET_USER}" -g "${TARGET_USER}" -m 0600 "${tmp}${dir}/config.xml" "${SYNCTHING_SOURCE_CONFIG}"
        ok "test install: Syncthing identity NOT restored; old config staged at ${SYNCTHING_SOURCE_CONFIG}"
    else
        warn "no Syncthing config.xml in the snapshot — scripts/test/syncthing-test-device.sh will need it"
    fi
    rm -rf "${tmp}"
}
step_done()      { [[ -f "${STATE_DIR}/${1}.done" ]]; }
mark_step_done() { mkdir -p "${STATE_DIR}"; touch "${STATE_DIR}/${1}.done"; }

STEPS=(
    "Mount DAS"
    "Restore DATA from restic by allowlist (+ NetworkManager)"
    "Verify hibernation (resume= karg, swap active, SELinux module)"
    "CAC: pcscd + DoD roots into system trust"
    "libvirt: restore Win11VM (config, disk, NVRAM, TPM state)"
    "Bootstrap user layer: chezmoi init --apply (dotfiles, brew, distrobox, flatpak overrides, syncthing)"
    "Tailscale: bring the node up"
)

list_steps() {
    echo "Post-install setup steps:"
    for i in "${!STEPS[@]}"; do
        n=$((i + 1))
        if step_done "step${n}"; then echo "  ${n}. [x] ${STEPS[$i]}"; else echo "  ${n}. [ ] ${STEPS[$i]}"; fi
    done
}

check_status() {
    list_steps; echo ""
    mountpoint -q "${DAS_MOUNT}" && ok "DAS mounted" || fail "DAS not mounted"
    [[ -f "${RESTIC_PASSFILE}" ]] && ok "restic password file present" || fail "restic password file missing"
    [[ -d "${USER_HOME}/Documents" ]] && ok "Documents restored" || fail "Documents missing"
    grep -q 'resume=' /proc/cmdline && ok "resume= on cmdline" || fail "no resume= karg"
    swapon --show=NAME --noheadings | grep -qv zram && ok "swap partition active" || fail "no non-zram swap"
    systemctl is-active -q pcscd.socket && ok "pcscd.socket active" || fail "pcscd.socket inactive"
    [[ -d "${USER_HOME}/.local/share/chezmoi/.git" ]] && ok "chezmoi source present" || fail "chezmoi not initialised"
    [[ -x /home/linuxbrew/.linuxbrew/bin/brew ]] && ok "Homebrew installed" || warn "Homebrew not installed yet"
    local n; n=$(run_as_user distrobox list --no-color 2>/dev/null | tail -n +2 | grep -c . || true)
    [[ "${n}" -gt 0 ]] && ok "distrobox containers: ${n}" || warn "no distrobox containers yet"
    run_as_user systemctl --user is-active -q syncthing.service && ok "syncthing (user) running" || warn "syncthing (user) not running"
    systemctl is-active -q virtqemud.socket && ok "virtqemud.socket active" || warn "virtqemud.socket inactive"
    virsh -c qemu:///system list --all 2>/dev/null | grep -q Win11VM && ok "Win11VM registered" || warn "Win11VM not registered"
    tailscale status >/dev/null 2>&1 && ok "tailscale up" || warn "tailscale not connected"
    n=$(flatpak list --system --columns=application 2>/dev/null | wc -l || true)
    [[ "${n}" -gt 0 ]] && ok "system flatpaks: ${n}" || warn "system flatpaks not installed yet (systemctl status system-flatpak-setup)"
}

RUN_STEP=""
case "${1:-}" in
    --list)  list_steps; exit 0 ;;
    --check) check_status; exit 0 ;;
    --step)  RUN_STEP="${2:?--step requires a number}" ;;
    "")      ;;
    *)       echo "Usage: $0 [--list|--check|--step N]"; exit 1 ;;
esac
[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }
id "${TARGET_USER}" >/dev/null 2>&1 || { echo "ERROR: user ${TARGET_USER} does not exist"; exit 1; }

# ─── Step 1: Mount DAS ───────────────────────────────────────────────
step1_mount_das() {
    log "Step 1: Mount DAS"
    if mountpoint -q "${DAS_MOUNT}"; then
        skip "DAS already mounted"
    else
        [[ -n "${DAS_LUKS_UUID}" ]] || { fail "DAS_LUKS_UUID not set in ${SITE_ENV} — mount the DAS at ${DAS_MOUNT} yourself and rerun"; exit 1; }
        local das_part="/dev/disk/by-uuid/${DAS_LUKS_UUID}" dm="/dev/mapper/luks-${DAS_LUKS_UUID}"
        [[ -e "${das_part}" ]] || { fail "DAS LUKS partition (UUID ${DAS_LUKS_UUID}) not found. Is the DAS connected?"; exit 1; }
        [[ -e "${dm}" ]] || { echo "  Unlocking DAS (passphrase prompt)..."; cryptsetup open "$(readlink -f "${das_part}")" "luks-${DAS_LUKS_UUID}"; }
        mkdir -p "${DAS_MOUNT}"; mount "${dm}" "${DAS_MOUNT}"
        ok "DAS mounted at ${DAS_MOUNT}"
    fi
    [[ -d "${RESTIC_REPO}" ]] || { fail "restic repo not found at ${RESTIC_REPO}"; exit 1; }
    mark_step_done "step1"
}

# ─── Step 2: Restore DATA by allowlist ───────────────────────────────
step2_restore() {
    log "Step 2: Restore data from restic (allowlist: ${ALLOWLIST})"
    [[ -f "${ALLOWLIST}" ]] || { fail "allowlist not found at ${ALLOWLIST}"; exit 1; }

    if [[ ! -f "${RESTIC_PASSFILE}" ]]; then
        echo "  Password file not found. Restoring ~/.restic first (enter the repo passphrase when asked)."
        RESTIC_REPOSITORY="${RESTIC_REPO}" restic restore "${SNAP[@]}" --target "$(restore_target "${USER_HOME}/.restic")" --include "${USER_HOME}/.restic/" \
            || { fail "Could not restore the password file."; exit 1; }
        [[ -f "${RESTIC_PASSFILE}" ]] || { fail "restore ran but ${RESTIC_PASSFILE} is still missing"; exit 1; }
        chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.restic"; chmod 700 "${USER_HOME}/.restic"; chmod 600 "${RESTIC_PASSFILE}"
    fi
    restic_root snapshots --latest 1 >/dev/null || { fail "Cannot access restic repo at ${RESTIC_REPO}"; exit 1; }
    ok "restic repo accessible"

    # One restore per allowlist entry, in file order (Syncthing identity is last
    # on purpose: its folders must exist before the daemon ever starts).
    local path
    while IFS= read -r path; do
        path="${path%%#*}"; path="${path// /}"
        [[ -z "${path}" ]] && continue
        # shellcheck disable=SC2088  # a literal "~/" prefix in the allowlist, expanded here
        [[ "${path}" == "~/"* ]] && path="${USER_HOME}/${path#"~/"}"   # entries are home-relative
        if [[ "${TEST_INSTALL}" == 1 && "${path}" == */.local/state/syncthing ]]; then
            stage_syncthing_source_config "${path}"
            continue
        fi
        if [[ -e "${path}" && -n "$(ls -A "${path}" 2>/dev/null)" ]]; then
            skip "${path}"
            continue
        fi
        echo "  restoring ${path} ..."
        if [[ "${path}" == */.local/state/syncthing ]]; then
            # restic 0.19 refuses --include with --exclude ("mutually exclusive"),
            # so restore all of it, then drop the logs and the old index (rebuilt).
            restic_restore "${path}"
            rm -rf "${path}"/*.log "${path}/index-v2"
        else
            restic_restore "${path}"
        fi
        [[ -e "${path}" ]] && ok "${path}" || warn "${path} not in snapshot — skipped"
    done < "${ALLOWLIST}"
    chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}"
    restorecon -R "${USER_HOME}" 2>/dev/null || true

    # System config that is data, not image: Wi-Fi/VPN profiles.
    if [[ -n "$(ls -A /etc/NetworkManager/system-connections 2>/dev/null)" ]]; then
        skip "NetworkManager connections already present"
    else
        restic_restore "/etc/NetworkManager/" && {
            chmod 600 /etc/NetworkManager/system-connections/* 2>/dev/null || true
            systemctl reload NetworkManager || true
            ok "NetworkManager connections restored"; }
    fi

    mark_step_done "step2"
}

# ─── Step 3: Hibernation ─────────────────────────────────────────────
step3_hibernation() {
    log "Step 3: Hibernation"
    if grep -q 'resume=' /proc/cmdline && swapon --show=NAME --noheadings | grep -qv zram; then
        /usr/bin/enable-hibernation.sh --check || warn "see above"
    else
        /usr/bin/enable-hibernation.sh || true
        warn "REBOOT before testing hibernation"
    fi
    mark_step_done "step3"
}

# ─── Step 4: CAC system half ─────────────────────────────────────────
step4_cac() {
    log "Step 4: CAC — pcscd + DoD roots (system trust)"
    # setup-cac.sh downloads + verifies the public DoD PKI bundle (needs network).
    SUDO_USER="${TARGET_USER}" /usr/bin/setup-cac.sh --system || { fail "setup-cac.sh --system failed (network?)"; return 1; }
    mark_step_done "step4"
}

# ─── Step 5: libvirt / Win11VM ───────────────────────────────────────
step5_vms() {
    log "Step 5: libvirt — Win11VM"
    systemctl enable --now virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket virtsecretd.socket virtinterfaced.socket
    id -nG "${TARGET_USER}" | grep -qw libvirt || { usermod -aG libvirt "${TARGET_USER}"; ok "added ${TARGET_USER} to libvirt (re-login)"; }

    [[ -n "$(ls -A /etc/libvirt/qemu 2>/dev/null)" ]] || { restic_restore "/etc/libvirt/"; ok "/etc/libvirt restored"; }
    if [[ ! -f /var/lib/libvirt/vm-images/Win11VM.qcow2 ]]; then
        echo "  Restoring Win11VM.qcow2 (~512 GB, slow)..."
        restic_restore "/var/lib/libvirt/vm-images/"; ok "VM disk restored"
    else skip "Win11VM.qcow2 present"; fi
    restic_restore "/var/lib/libvirt/qemu/nvram/" 2>/dev/null && ok "OVMF NVRAM restored" || warn "no NVRAM in backup (fresh UEFI vars)"
    restic_restore "/var/lib/libvirt/swtpm/"     2>/dev/null && ok "swtpm state restored" || warn "no swtpm state in backup (BitLocker may ask for its recovery key)"
    restorecon -R /var/lib/libvirt 2>/dev/null || true

    local V="virsh -c qemu:///system"
    $V pool-info vm-images >/dev/null 2>&1 || { $V pool-define-as vm-images dir --target /var/lib/libvirt/vm-images; $V pool-start vm-images; $V pool-autostart vm-images; ok "vm-images pool"; }
    $V net-start default 2>/dev/null || true; $V net-autostart default 2>/dev/null || true
    if $V list --all 2>/dev/null | grep -q Win11VM; then skip "Win11VM registered"
    elif [[ -f /etc/libvirt/qemu/Win11VM.xml ]]; then $V define /etc/libvirt/qemu/Win11VM.xml; ok "Win11VM defined"
    else fail "Win11VM.xml missing — run scripts/reregister-win11vm.sh from the repo"; fi
    mark_step_done "step5"
}

# ─── Step 6: user layer via chezmoi ──────────────────────────────────
step6_chezmoi() {
    log "Step 6: chezmoi init --apply ${DOTFILES_REPO}"
    if [[ -d "${USER_HOME}/.local/share/chezmoi/.git" ]]; then
        skip "chezmoi already initialised — running 'chezmoi apply' instead"
        run_as_user chezmoi apply
    else
        # SSH clone needs the restored key and GitHub's host key.
        if [[ "${DOTFILES_REPO}" == git@github.com:* ]]; then
            [[ -f "${USER_HOME}/.ssh/id_ed25519" || -f "${USER_HOME}/.ssh/id_rsa" ]] || warn "no SSH key in ${USER_HOME}/.ssh — clone will fail; set DOTFILES_REPO=https://... or restore .ssh"
            run_as_user mkdir -p "${USER_HOME}/.ssh"
            run_as_user bash -c "ssh-keygen -F github.com >/dev/null 2>&1 || ssh-keyscan -t ed25519 github.com >> ${USER_HOME}/.ssh/known_hosts 2>/dev/null"
        fi
        # chezmoi's run_once_ scripts then install Homebrew + Brewfile, assemble
        # the distrobox containers, apply flatpak overrides, run setup-cac --user
        # and enable the Syncthing user service. This is the long step.
        run_as_user chezmoi init --apply "${DOTFILES_REPO}"
    fi
    ok "user layer applied"
    mark_step_done "step6"
}

# ─── Step 7: Tailscale ───────────────────────────────────────────────
step7_tailscale() {
    log "Step 7: Tailscale"
    systemctl enable --now tailscaled
    if tailscale status >/dev/null 2>&1; then
        skip "tailscale already connected"
    elif [[ "${TEST_INSTALL}" == 1 ]]; then
        # Never the old identity here: two disks with the same node key log each
        # other out, and the real machine's node must keep working.
        echo "  Test install: NEW node \"$(hostname)\" (the real machine's node stays untouched)."
        echo "  Approve it in the admin console; consider disabling its key expiry for the test period."
        tailscale up || warn "tailscale up needs an interactive login — run it yourself"
    else
        echo "  Option A (same node identity as before): restore /var/lib/tailscale from the backup."
        echo "  Option B (new node): tailscale up — approve it in the admin console."
        read -rp "  Restore old identity? (y/N) " r
        if [[ "${r,,}" == y ]]; then
            systemctl stop tailscaled
            restic_restore "/var/lib/tailscale/" && ok "tailscale state restored"
            systemctl start tailscaled
        fi
        tailscale up || warn "tailscale up needs an interactive login — run it yourself"
    fi
    mark_step_done "step7"
}

main() {
    echo "============================================"
    echo "  Fedora Cosmic Atomic — Post-Install Setup"
    echo "============================================"
    if ! bootc status 2>/dev/null | grep -qE 'fedora-cosmic-(frmwrk|dsktp)'; then
        warn "bootc status does not show the custom image. Some shipped scripts may be missing."
        read -rp "  Continue anyway? (y/N) " response; [[ "${response,,}" == "y" ]] || exit 0
    fi
    echo ""; list_steps; echo ""
    if [[ -n "${RUN_STEP}" ]]; then
        case "${RUN_STEP}" in
            1) step1_mount_das ;; 2) step2_restore ;; 3) step3_hibernation ;; 4) step4_cac ;;
            5) step5_vms ;; 6) step6_chezmoi ;; 7) step7_tailscale ;;
            *) echo "Invalid step: ${RUN_STEP}"; exit 1 ;;
        esac
    else
        step1_mount_das; step2_restore; step3_hibernation; step4_cac; step5_vms; step6_chezmoi; step7_tailscale
    fi
    log "Post-install setup complete"
    cat <<EOF
Next:
  1. Log out and back in (libvirt group, brew on PATH, restored dotfiles)
  2. post-install-setup.sh --check
  3. Syncthing: open http://127.0.0.1:8384 — the desktop should reconnect within a minute
     (test install: run scripts/test/syncthing-test-device.sh instead — own device, receive-only)
  4. Test hibernation:  systemctl hibernate
  5. Anything you miss from the old machine:
       sudo restic -r ${RESTIC_REPO} ls ${SNAP[*]} ${USER_HOME} | less
       sudo restic -r ${RESTIC_REPO} restore ${SNAP[*]} --target $(restore_target "${USER_HOME}/x") --include ${USER_HOME}/<path>
EOF
}
main "$@"
