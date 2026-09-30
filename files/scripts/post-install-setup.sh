#!/usr/bin/env bash
#
# post-install-setup.sh — One-shot system configuration for Fedora Cosmic Atomic
#
# Run this AFTER the final signed rebase + reboot. It handles everything that
# can't be baked into the image because it depends on per-installation state
# (drive UUIDs, restored data, browser profiles).
#
# This script is idempotent — safe to re-run. It skips steps already done.
# As you adapt to COSMIC DE and the atomic workflow, edit this script and
# commit changes to git. Each reinstall picks up your latest preferences.
#
# USAGE:
#   sudo post-install-setup.sh              # run all steps
#   sudo post-install-setup.sh --step N     # run only step N (1-8)
#   sudo post-install-setup.sh --list       # list steps
#   sudo post-install-setup.sh --check      # verify status of all steps
#
# PREREQUISITES:
#   - Booted into the signed custom image (rpm-ostree status shows signed)
#   - Network connected
#   - DAS physically connected (USB/SATA)
#
set -euo pipefail

# ─── Constants ────────────────────────────────────────────────────────
DAS_UUID="00000000-0000-0000-0000-000000000000"
DAS_MOUNT="/run/media/<user>/DAS"
RESTIC_REPO="${DAS_MOUNT}/frmwrk-restic-repo"
RESTIC_PASSFILE="${HOME}/.restic/frmwrk-repo.pass"
HERMES_BACKUP="${DAS_MOUNT}/hermes-backup"

# Must be root for most steps
if [[ "${1:-}" != "--list" && "${1:-}" != "--check" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run with sudo"
        exit 1
    fi
fi

# ─── Helpers ──────────────────────────────────────────────────────────
log()    { echo -e "\n\033[1;34m=== $* ===\033[0m"; }
ok()     { echo -e "  \033[0;32m✓\033[0m $*"; }
skip()   { echo -e "  \033[0;33m→\033[0m $* (already done, skipping)"; }
warn()   { echo -e "  \033[0;33m!\033[0m $*"; }
fail()   { echo -e "  \033[0;31m✗\033[0m $*"; }

run_as_user() {
    sudo -u <user> HOME=/home/<user> "$@"
}

step_done() {
    # Check if a step marker file exists
    [[ -f "/var/lib/post-install-setup/${1}.done" ]]
}

mark_step_done() {
    mkdir -p /var/lib/post-install-setup
    touch "/var/lib/post-install-setup/${1}.done"
}

# ─── Step list ────────────────────────────────────────────────────────
STEPS=(
    "Mount DAS and unlock restic repo"
    "Restore data from restic backup"
    "Enable hibernation (swap UUID + kernel args)"
    "Configure CAC / smart card reader with DoD PKI"
    "Create distrobox containers"
    "Restore libvirt VMs"
    "Install flatpaks and flatpak overrides"
    "Restore Hermes config"
)

list_steps() {
    echo "Post-install setup steps:"
    for i in "${!STEPS[@]}"; do
        n=$((i + 1))
        if step_done "step${n}"; then
            echo "  ${n}. [x] ${STEPS[$i]}"
        else
            echo "  ${n}. [ ] ${STEPS[$i]}"
        fi
    done
}

check_status() {
    list_steps
    echo ""

    # DAS
    if mountpoint -q "${DAS_MOUNT}"; then
        ok "DAS mounted at ${DAS_MOUNT}"
    else
        fail "DAS not mounted"
    fi

    # Restic
    if [[ -f "${RESTIC_PASSFILE}" ]]; then
        ok "Restic password file present"
    else
        fail "Restic password file missing at ${RESTIC_PASSFILE}"
    fi

    # Hibernation
    if rpm-ostree kargs 2>/dev/null | grep -q "resume="; then
        ok "Hibernation kernel args set"
    else
        fail "Hibernation not configured (no resume= karg)"
    fi

    # CAC
    if systemctl is-active pcscd.socket >/dev/null 2>&1; then
        ok "pcscd.socket active"
    else
        fail "pcscd.socket not active"
    fi

    # Distrobox
    local_count=$(run_as_user distrobox-list 2>/dev/null | grep -c . || true)
    if [[ "${local_count}" -gt 0 ]]; then
        ok "Distrobox containers: ${local_count}"
    else
        fail "No distrobox containers"
    fi

    # libvirt
    if systemctl is-active libvirtd >/dev/null 2>&1; then
        ok "libvirtd active"
        if virsh list --all 2>/dev/null | grep -q "Win11VM"; then
            ok "Win11VM registered"
        else
            warn "Win11VM not registered"
        fi
    else
        warn "libvirtd not running"
    fi

    # Flatpaks
    local_count=$(run_as_user flatpak list --columns=application 2>/dev/null | wc -l || true)
    if [[ "${local_count}" -gt 0 ]]; then
        ok "Flatpaks installed: ${local_count}"
    else
        warn "No flatpaks installed"
    fi

    # Hermes
    if [[ -d "${HOME}/.hermes" && -f "${HOME}/.hermes/config.yaml" ]]; then
        ok "Hermes config present"
    else
        warn "Hermes config not restored"
    fi
}

# ─── Parse args ───────────────────────────────────────────────────────
RUN_STEP=""
if [[ "${1:-}" == "--list" ]]; then
    list_steps
    exit 0
elif [[ "${1:-}" == "--check" ]]; then
    check_status
    exit 0
elif [[ "${1:-}" == "--step" ]]; then
    RUN_STEP="${2:?--step requires a number}"
fi

# ─── Step 1: Mount DAS ───────────────────────────────────────────────
step1_mount_das() {
    log "Step 1: Mount DAS"

    if mountpoint -q "${DAS_MOUNT}"; then
        skip "DAS already mounted"
        return 0
    fi

    # Find the DAS device (could be /dev/sda1, /dev/sdb1, etc.)
    local das_dev
    das_dev=$(lsblk -o NAME,FSTYPE -n | grep crypto_LUKS | awk '{print "/dev/"$1}' | head -1)

    if [[ -z "${das_dev}" ]]; then
        fail "No LUKS device found. Is the DAS connected?"
        exit 1
    fi

    echo "  Found LUKS device: ${das_dev}"

    # Unlock
    sudo cryptsetup luksOpen "${das_dev}" "luks-${DAS_UUID}"
    mkdir -p "${DAS_MOUNT}"
    sudo mount "/dev/mapper/luks-${DAS_UUID}" "${DAS_MOUNT}"

    if mountpoint -q "${DAS_MOUNT}"; then
        ok "DAS mounted at ${DAS_MOUNT}"
    else
        fail "Failed to mount DAS"
        exit 1
    fi

    mark_step_done "step1"
}

# ─── Step 2: Restore from restic ─────────────────────────────────────
step2_restore_restic() {
    log "Step 2: Restore data from restic"

    if [[ ! -f "${RESTIC_PASSFILE}" ]]; then
        # The password file is in the backup itself — chicken-and-egg.
        # Try to restore just the password file first.
        echo "  Password file not found. Restoring it first..."
        # This will prompt for the restic repo password interactively
        echo "  Enter your restic repo password when prompted:"
        restic -r "${RESTIC_REPO}" restore latest \
            --target / --include "/home/<user>/.restic/" \
            -- || {
            fail "Could not restore password file. Mount DAS and check repo."
            exit 1
        }
        chown <user>:<user> "${RESTIC_PASSFILE}"
        chmod 600 "${RESTIC_PASSFILE}"
    fi

    export RESTIC_REPOSITORY="${RESTIC_REPO}"
    export RESTIC_PASSWORD_FILE="${RESTIC_PASSFILE}"

    # Verify repo
    if ! sudo -u <user> \
        RESTIC_REPOSITORY="${RESTIC_REPO}" \
        RESTIC_PASSWORD_FILE="${RESTIC_PASSFILE}" \
        restic snapshots >/dev/null 2>&1; then
        fail "Cannot access restic repo at ${RESTIC_REPO}"
        exit 1
    fi
    ok "Restic repo accessible"

    # Check what's already restored
    if [[ -f "${HOME}/.bashrc" && -d "${HOME}/Documents" ]]; then
        skip "Home directory already restored"
    else
        echo "  Restoring home directory..."
        restic restore latest --target / --include "/home/<user>/"
        chown -R <user>:<user> /home/<user>/
        ok "Home directory restored"
    fi

    # Restore system configs
    if [[ -d /etc/libvirt/qemu ]]; then
        skip "Libvirt configs already present"
    else
        restic restore latest --target / --include "/etc/libvirt/"
        ok "Libvirt configs restored"
    fi

    if [[ -d /etc/NetworkManager/system-connections ]]; then
        skip "NetworkManager configs already present"
    else
        restic restore latest --target / --include "/etc/NetworkManager/"
        ok "NetworkManager configs restored"
    fi

    # Restore restic sudoers
    if [[ ! -f /etc/sudoers.d/restic-backup ]]; then
        echo "  Installing restic sudoers..."
        if [[ -f /home/<user>/migration-prep/bluebuild-recipe/scripts/restic-backup-sudoers ]]; then
            install -m 0440 -o root -g root \
                /home/<user>/migration-prep/bluebuild-recipe/scripts/restic-backup-sudoers \
                /etc/sudoers.d/restic-backup
            visudo -cf
            ok "Restic sudoers installed"
        else
            # Create inline
            cat > /etc/sudoers.d/restic-backup << 'SUDOERS'
Cmnd_Alias RESTIC = /usr/bin/restic
<user> ALL=(root) NOPASSWD: RESTIC
Defaults!RESTIC env_keep += "RESTIC_REPOSITORY RESTIC_PASSWORD_FILE"
SUDOERS
            chmod 0440 /etc/sudoers.d/restic-backup
            visudo -cf
            ok "Restic sudoers created inline"
        fi
    else
        skip "Restic sudoers already installed"
    fi

    mark_step_done "step2"
}

# ─── Step 3: Enable hibernation ──────────────────────────────────────
step3_hibernation() {
    log "Step 3: Enable hibernation"

    if rpm-ostree kargs 2>/dev/null | grep -q "resume="; then
        skip "Hibernation kargs already set"
    else
        echo "  Running enable-hibernation.sh..."
        /usr/local/bin/enable-hibernation.sh
        ok "Hibernation configured — REBOOT REQUIRED before testing"
    fi

    mark_step_done "step3"
}

# ─── Step 4: CAC / smart card ────────────────────────────────────────
step4_cac() {
    log "Step 4: Configure CAC / smart card reader"

    if [[ ! -f /usr/local/bin/setup-cac.sh ]]; then
        fail "setup-cac.sh not found in image. Are you on the custom image?"
        return 1
    fi

    # Run as user (script uses sudo internally for system trust)
    run_as_user /usr/local/bin/setup-cac.sh

    # Apply flatpak pcsc overrides
    for app_id in org.mozilla.firefox io.github.zen_browser.zen; do
        run_as_user flatpak override --user --socket=pcsc "${app_id}" 2>/dev/null && \
            ok "Flatpak ${app_id}: pcsc socket granted" || \
            warn "Flatpak ${app_id}: not installed yet (override will apply on install)"
    done

    mark_step_done "step4"
}

# ─── Step 5: Distrobox containers ────────────────────────────────────
step5_distrobox() {
    log "Step 5: Create distrobox containers"

    if [[ ! -f /usr/local/bin/distrobox-setup.sh ]]; then
        fail "distrobox-setup.sh not found in image"
        return 1
    fi

    run_as_user /usr/local/bin/distrobox-setup.sh

    echo ""
    run_as_user distrobox-list

    mark_step_done "step5"
}

# ─── Step 6: Restore libvirt VMs ─────────────────────────────────────
step6_vms() {
    log "Step 6: Restore libvirt VMs"

    systemctl enable --now libvirtd

    # Add user to libvirt group if not already
    if ! id <user> | grep -q libvirt; then
        usermod -aG libvirt <user>
        ok "Added <user> to libvirt group (re-login to take effect)"
    fi

    # Restore VM images if not present
    if [[ ! -f /var/lib/libvirt/vm-images/Win11VM.qcow2 ]]; then
        echo "  Restoring Win11VM.qcow2 from restic (this may take a while)..."
        export RESTIC_REPOSITORY="${RESTIC_REPO}"
        export RESTIC_PASSWORD_FILE="${RESTIC_PASSFILE}"
        restic restore latest --target / --include "/var/lib/libvirt/vm-images/"
        ok "VM images restored"
    else
        skip "Win11VM.qcow2 already present"
    fi

    # Define the VM
    if virsh list --all 2>/dev/null | grep -q "Win11VM"; then
        skip "Win11VM already registered"
    else
        if [[ -f /etc/libvirt/qemu/Win11VM.xml ]]; then
            virsh define /etc/libvirt/qemu/Win11VM.xml
            ok "Win11VM defined"
        else
            fail "Win11VM.xml not found at /etc/libvirt/qemu/Win11VM.xml"
            warn "Restore /etc/libvirt/ from restic first"
        fi
    fi

    mark_step_done "step6"
}

# ─── Step 7: Flatpaks ────────────────────────────────────────────────
step7_flatpaks() {
    log "Step 7: Install flatpaks and overrides"

    # The image installs system flatpaks on first boot, but user-scope
    # flatpaks and overrides may need manual install
    run_as_user flatpak remote-add --if-not-exists flathub \
        https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    # Ensure the default flatpaks from the image are installed
    local flatpaks=(
        org.mozilla.firefox
        io.github.zen_browser.zen
        com.github.tchx84.Flatseal
        it.mijorus.gearlever
        org.videolan.VLC
        org.darktable.Darktable
        org.inkscape.Inkscape
        org.gimp.GIMP
        com.calibre_ebook.calibre
        org.zotero.Zotero
        com.visualstudio.code
    )

    for fp in "${flatpaks[@]}"; do
        if run_as_user flatpak list --columns=application 2>/dev/null | grep -q "^${fp}$"; then
            skip "${fp}"
        else
            run_as_user flatpak install -y flathub "${fp}" 2>/dev/null && \
                ok "Installed: ${fp}" || \
                warn "Failed to install: ${fp}"
        fi
    done

    # Apply pcsc socket override for all flatpak browsers
    for app_id in org.mozilla.firefox io.github.zen_browser.zen; do
        run_as_user flatpak override --user --socket=pcsc "${app_id}" 2>/dev/null && \
            ok "pcsc override: ${app_id}" || true
    done

    mark_step_done "step7"
}

# ─── Step 8: Restore Hermes ──────────────────────────────────────────
step8_hermes() {
    log "Step 8: Restore Hermes config"

    if [[ ! -d "${HERMES_BACKUP}" ]]; then
        fail "Hermes backup not found at ${HERMES_BACKUP}"
        return 1
    fi

    if [[ -f "${HOME}/.hermes/config.yaml" ]]; then
        skip "Hermes config already present"
    else
        mkdir -p "${HOME}/.hermes"
        rsync -a "${HERMES_BACKUP}/" "${HOME}/.hermes/"
        chown -R <user>:<user> "${HOME}/.hermes"
        ok "Hermes config restored"
    fi

    mark_step_done "step8"
}

# ─── Main ────────────────────────────────────────────────────────────
main() {
    echo "============================================"
    echo "  Fedora Cosmic Atomic — Post-Install Setup"
    echo "============================================"
    echo ""

    # Verify we're on the right image
    if ! rpm-ostree status 2>/dev/null | grep -q "ostree-image-signed\|ostree-unverified-registry"; then
        warn "Not running a custom ostree image. Some baked-in scripts may be missing."
        echo "  Continue anyway? (y/N)"
        read -r response
        [[ "${response,,}" == "y" ]] || exit 0
    fi

    echo ""
    echo "Steps:"
    list_steps
    echo ""

    if [[ -n "${RUN_STEP}" ]]; then
        echo "Running only step ${RUN_STEP}"
        case "${RUN_STEP}" in
            1) step1_mount_das ;;
            2) step2_restore_restic ;;
            3) step3_hibernation ;;
            4) step4_cac ;;
            5) step5_distrobox ;;
            6) step6_vms ;;
            7) step7_flatpaks ;;
            8) step8_hermes ;;
            *) echo "Invalid step: ${RUN_STEP}"; exit 1 ;;
        esac
    else
        step1_mount_das
        step2_restore_restic
        step3_hibernation
        step4_cac
        step5_distrobox
        step6_vms
        step7_flatpaks
        step8_hermes
    fi

    echo ""
    log "Post-install setup complete"
    echo ""
    echo "Next steps:"
    echo "  1. REBOOT (for hibernation kargs to take effect)"
    echo "  2. Test hibernation: systemctl hibernate"
    echo "  3. Restart browsers for CAC PKCS#11 module"
    echo "  4. Run --check to verify: sudo post-install-setup.sh --check"
    echo ""
    echo "To re-run a single step:"
    echo "  sudo post-install-setup.sh --step N"
    echo ""
    echo "To iterate on this script:"
    echo "  Edit ~/migration-prep/bluebuild-recipe/files/scripts/post-install-setup.sh"
    echo "  Commit and push — next reinstall picks up your changes."
}

main "$@"
