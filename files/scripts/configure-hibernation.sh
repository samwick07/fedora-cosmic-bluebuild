#!/usr/bin/env bash
# configure-hibernation.sh — BUILD-TIME: bake the static half of
# suspend-then-hibernate into the image.
#
# Baked here:      systemd sleep/logind drop-ins, SELinux policy module
# Per-install:     resume=UUID=, rd.luks.uuid= (swap) — written by
#                  scripts/install-atomic.sh (bootc path) or
#                  /usr/bin/enable-hibernation.sh (Anaconda path)
set -euo pipefail

# ── systemd drop-ins (never overwrite the shipped files) ──────────────
install -d /etc/systemd/sleep.conf.d /etc/systemd/logind.conf.d

cat > /etc/systemd/sleep.conf.d/10-hibernate.conf <<'EOF'
# Suspend first; hibernate after this long asleep (5 min).
[Sleep]
HibernateDelaySec=300
EOF

cat > /etc/systemd/logind.conf.d/10-lid.conf <<'EOF'
# Lid close -> suspend-then-hibernate, docked or not.
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleLidSwitchDocked=suspend-then-hibernate
EOF

# ── SELinux: allow logind/sleep the swap + state accesses hibernation needs ──
# checkpolicy (checkmodule) and policycoreutils (semodule_package) are layered
# by common-modules.yml, so the module is compiled and installed at build time.
# The source is kept in /usr/share/selinux so it can be rebuilt on the host.
install -d /usr/share/selinux/packages/fedora-cosmic-atomic
cat > /usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.te <<'EOF'
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
allow systemd_sleep_t init_var_lib_t:dir { write add_name };
allow systemd_sleep_t swapfile_t:dir search;
EOF

if command -v checkmodule >/dev/null && command -v semodule_package >/dev/null; then
    tmp=$(mktemp -d)
    checkmodule -M -m -o "$tmp/systemd_hibernate.mod" /usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.te
    semodule_package -o /usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.pp -m "$tmp/systemd_hibernate.mod"
    semodule -n -i /usr/share/selinux/packages/fedora-cosmic-atomic/systemd_hibernate.pp
    rm -rf "$tmp"
    echo "SELinux systemd_hibernate module compiled and installed."
else
    echo "WARNING: checkmodule/semodule_package missing at build time; enable-hibernation.sh will install the module on the host." >&2
fi

echo "Hibernation base config installed (sleep.conf.d, logind.conf.d, SELinux)."
