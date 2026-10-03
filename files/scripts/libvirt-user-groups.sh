#!/usr/bin/bash
# libvirt-user-groups — put every member of wheel into the libvirt group (spec V1).
# On Atomic, a group the image defines may exist only in /usr/lib/group; usermod edits
# /etc/group, so the line is copied there first.
set -euo pipefail
if ! grep -q '^libvirt:' /etc/group; then
    line=$(grep '^libvirt:' /usr/lib/group 2>/dev/null) || { echo "no libvirt group defined"; exit 0; }
    echo "$line" >> /etc/group
fi
members=$(getent group wheel | cut -d: -f4 | tr ',' ' ')
for u in $members; do
    if ! id -nG "$u" | tr ' ' '\n' | grep -qx libvirt; then
        usermod -aG libvirt "$u" && echo "added $u to libvirt"
    fi
done
