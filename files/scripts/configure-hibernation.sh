#!/usr/bin/env bash
# configure-hibernation.sh
# Sets up suspend-then-hibernate for Framework 13 on Fedora Atomic COSMIC.
#
# This script runs during image BUILD time and handles what CAN be baked
# into the image: systemd configs, SELinux policy, and the sleep.conf.
#
# What CANNOT be baked in (must be done post-install):
#   - Swap partition creation (needs the LUKS partition, which is created
#     during Fedora installation)
#   - resume= kernel parameter (depends on the swap partition's UUID,
#     which is unique per installation)
#   - rd.luks.uuid for the swap partition (same reason)
#
# Those post-install steps are documented in docs/hibernation-post-install.md
# and automated in scripts/enable-hibernation.sh (run-once on first boot).
set -euo pipefail

# ─────────────────────────────────────────────
# 1. SYSTEMD SLEEP CONFIG
# ─────────────────────────────────────────────
# HibernateDelaySec: time in suspend before transitioning to hibernate.
# 300s = 5 minutes. Adjust to taste.
mkdir -p /etc/systemd
cat > /etc/systemd/sleep.conf << 'EOF'
[Sleep]
HibernateDelaySec=300
EOF

# ─────────────────────────────────────────────
# 2. SYSTEMD LOGIND CONFIG
# ─────────────────────────────────────────────
# Lid close triggers suspend-then-hibernate (suspend first, hibernate after delay).
# HandleLidSwitchDocked: same behavior when docked/external display connected.
mkdir -p /etc/systemd
cat > /etc/systemd/logind.conf << 'EOF'
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchDocked=suspend-then-hibernate
EOF

# ─────────────────────────────────────────────
# 3. SELinux POLICY FOR HIBERNATION
# ─────────────────────────────────────────────
# On Fedora Atomic, SELinux may block systemd-logind and systemd-sleep
# from accessing the swap device during hibernation.
# This policy module allows the necessary accesses.
# Based on the Universal Blue community guide and Fedora discussions.

# Create the SELinux policy source
mkdir -p /tmp/selinux-hibernate
cat > /tmp/selinux-hibernate/systemd_hibernate.te << 'EOF'
module systemd_hibernate 1.0;

require {
    type systemd_logind_t;
    type init_var_lib_t;
    type systemd_sleep_t;
    type swapfile_t;
    class dir { add_name search write };
    class cap_userns sys_ptrace;
}

#============= systemd_logind_t ==============
allow systemd_logind_t self:cap_userns sys_ptrace;
allow systemd_logind_t swapfile_t:dir search;

#============= systemd_sleep_t ==============
allow systemd_sleep_t init_var_lib_t:dir write;
allow systemd_sleep_t init_var_lib_t:dir add_name;
allow systemd_sleep_t swapfile_t:dir search;
EOF

# Compile and install the SELinux module
# checkmodule and semodule_package are needed at build time
if command -v checkmodule &>/dev/null; then
    checkmodule -M -m -o /tmp/selinux-hibernate/systemd_hibernate.mod \
        /tmp/selinux-hibernate/systemd_hibernate.te
    semodule_package -o /tmp/selinux-hibernate/systemd_hibernate.pp \
        -m /tmp/selinux-hibernate/systemd_hibernate.mod
    semodule -i /tmp/selinux-hibernate/systemd_hibernate.pp
    echo "SELinux hibernation policy installed."
else
    echo "WARNING: checkmodule not available at build time."
    echo "SELinux policy will need to be installed post-install."
    echo "See docs/hibernation-post-install.md"
    # Copy the .te file for post-install use
    mkdir -p /usr/local/share/selinux
    cp /tmp/selinux-hibernate/systemd_hibernate.te \
        /usr/local/share/selinux/systemd_hibernate.te
fi

rm -rf /tmp/selinux-hibernate

echo "Hibernation base config installed (sleep.conf, logind.conf, SELinux policy)."
echo "Post-install: run /usr/local/bin/enable-hibernation.sh after first boot."
