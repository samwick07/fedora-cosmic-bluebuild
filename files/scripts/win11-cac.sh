#!/usr/bin/env bash
#
# win11-cac — hand the USB smart-card (CAC) reader to the Windows VM, and back.
# Shipped in the image at /usr/bin/win11-cac. The default way (spec V2); SPICE
# click-to-redirect in virt-manager / virt-viewer is the fallback.
#
#   sudo win11-cac attach  [VM]   # host releases the reader, VM gets it (live)
#   sudo win11-cac detach  [VM]   # VM releases it, host pcscd gets it back
#   win11-cac status       [VM]
#
# Default VM: Win11VM. The reader is found by its USB interface class (0x0b,
# CCID), so any CCID reader works (SCR3500, OmniKey, built-in). Override with
# CAC_READER=vvvv:pppp if more than one is plugged in.
#
# While attached, the HOST cannot use the card: pcscd is stopped so it does not
# hold the device, and browsers on the host lose CAC until `detach`.
# In Windows, test with:  certutil -scinfo   (built-in CCID driver; no install needed)
#
set -euo pipefail

ACTION="${1:-status}"
VM="${2:-Win11VM}"
URI="qemu:///system"
V="virsh -c $URI"

die() { echo "ERROR: $*" >&2; exit 1; }

find_reader() {
    if [[ -n "${CAC_READER:-}" ]]; then echo "$CAC_READER"; return; fi
    local intf dev found=()
    for intf in /sys/bus/usb/devices/*:*; do
        [[ -r "$intf/bInterfaceClass" ]] || continue
        [[ "$(cat "$intf/bInterfaceClass")" == "0b" ]] || continue
        dev="${intf%:*}"
        found+=("$(cat "$dev/idVendor"):$(cat "$dev/idProduct")")
    done
    mapfile -t found < <(printf '%s\n' "${found[@]}" | sort -u | sed '/^$/d')
    case ${#found[@]} in
        0) die "no CCID smart-card reader found on USB (plug it in, or set CAC_READER=vvvv:pppp)";;
        1) echo "${found[0]}";;
        *) die "several readers found (${found[*]}); set CAC_READER=vvvv:pppp";;
    esac
}

hostdev_xml() {
    local vid="${1%:*}" pid="${1#*:}"
    cat <<EOF
<hostdev mode='subsystem' type='usb' managed='yes'>
  <source startupPolicy='optional'>
    <vendor id='0x$vid'/>
    <product id='0x$pid'/>
  </source>
</hostdev>
EOF
}

vm_running() { [[ "$($V domstate "$VM" 2>/dev/null)" == "running" ]]; }
attached()   { $V dumpxml "$VM" 2>/dev/null | grep -q "<vendor id='0x${1%:*}'/>" && \
               $V dumpxml "$VM" 2>/dev/null | grep -q "<product id='0x${1#*:}'/>"; }

case "$ACTION" in
  attach)
    [[ $EUID -eq 0 ]] || die "run with sudo"
    vm_running || die "$VM is not running — start it first (virsh -c $URI start $VM)"
    R=$(find_reader); echo "reader: $R"
    if attached "$R"; then echo "already attached to $VM"; exit 0; fi
    echo "stopping host pcscd (host loses CAC until detach)"
    systemctl stop pcscd.socket pcscd.service 2>/dev/null || true
    tmp=$(mktemp); hostdev_xml "$R" > "$tmp"
    if ! $V attach-device "$VM" "$tmp" --live; then
        rm -f "$tmp"; systemctl start pcscd.socket || true
        die "attach failed; host pcscd restored"
    fi
    rm -f "$tmp"
    echo "attached $R to $VM. In Windows: certutil -scinfo"
    ;;
  detach)
    [[ $EUID -eq 0 ]] || die "run with sudo"
    R=$(find_reader); echo "reader: $R"
    if vm_running && attached "$R"; then
        tmp=$(mktemp); hostdev_xml "$R" > "$tmp"
        $V detach-device "$VM" "$tmp" --live || echo "!! detach-device failed (VM may have released it already)"
        rm -f "$tmp"
    else
        echo "not attached to a running $VM"
    fi
    systemctl start pcscd.socket
    echo "host pcscd back; check with: opensc-tool --list-readers"
    ;;
  status)
    R=$(find_reader 2>/dev/null || echo "none")
    echo "reader:      $R"
    echo "VM $VM:      $($V domstate "$VM" 2>/dev/null || echo 'not defined')"
    if [[ "$R" != none ]] && vm_running && attached "$R"; then echo "attached:    yes (to $VM)"; else echo "attached:    no (host owns it)"; fi
    echo "host pcscd:  $(systemctl is-active pcscd.socket 2>/dev/null)"
    ;;
  *) echo "usage: win11-cac attach|detach|status [VM]"; exit 1 ;;
esac
