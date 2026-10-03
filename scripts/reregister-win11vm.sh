#!/bin/bash
#
# reregister-win11vm.sh — Re-register the Win11VM in libvirt
#
# The qcow2 disk exists at /var/lib/libvirt/vm-images/Win11VM.qcow2 (512GB)
# but the VM domain XML was lost. This script recreates the storage pool
# and registers the VM so the XML is captured in the next restic backup.
#
# Run with: sudo bash reregister-win11vm.sh
#
set -euo pipefail

echo "=== Re-registering Win11VM in libvirt ==="

# 1. Start the modular libvirt daemons (libvirtd.service conflicts with them)
echo "[1/5] Starting libvirt (modular daemons)..."
systemctl start virtqemud.socket virtnetworkd.socket virtstoraged.socket virtnodedevd.socket virtsecretd.socket
export LIBVIRT_DEFAULT_URI=qemu:///system
sleep 2

# 2. Start the default network (NAT for VMs)
echo "[2/5] Starting default network..."
virsh net-start default 2>/dev/null || echo "  (default network already running or autostarted)"
virsh net-autostart default 2>/dev/null || true

# 3. Create the vm-images storage pool
echo "[3/5] Defining vm-images storage pool..."
if ! virsh pool-info vm-images 2>/dev/null; then
    virsh pool-define-as vm-images dir --target /var/lib/libvirt/vm-images
    virsh pool-build vm-images
    virsh pool-start vm-images
    virsh pool-autostart vm-images
    echo "  Pool created."
else
    echo "  Pool already exists."
    virsh pool-start vm-images 2>/dev/null || true
fi

# 4. Register the Win11VM domain
echo "[4/5] Defining Win11VM domain..."
if virsh domstate Win11VM 2>/dev/null | grep -q "shut off"; then
    echo "  Win11VM already defined (shut off)."
elif virsh domstate Win11VM 2>/dev/null | grep -q "running"; then
    echo "  Win11VM already defined and running."
else
    # Write the VM XML to a temp file and define it
    cat > /tmp/Win11VM.xml << 'VMXML'
<domain type='kvm'>
  <name>Win11VM</name>
  <memory unit='GiB'>16</memory>
  <currentMemory unit='GiB'>16</currentMemory>
  <vcpu placement='static'>8</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <!-- Keep the .fd firmware the VM was created with so the existing NVRAM file
         (/var/lib/libvirt/qemu/nvram/Win11VM_VARS.fd, in the restic backup) stays
         valid. If Fedora drops the .fd files, switch BOTH lines to the 4M qcow2
         variants and convert the NVRAM: qemu-img convert -f raw -O qcow2 ... -->
    <loader readonly='yes' secure='yes' type='pflash'>/usr/share/edk2/ovmf/OVMF_CODE.secboot.fd</loader>
    <nvram template='/usr/share/edk2/ovmf/OVMF_VARS.secboot.fd'>/var/lib/libvirt/qemu/nvram/Win11VM_VARS.fd</nvram>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <!-- OVMF_CODE.secboot is built with SMM_REQUIRE: without SMM it never boots. -->
    <smm state='on'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='4' threads='2'/>
  </cpu>
  <clock offset='localtime'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
    <timer name='hypervclock' present='yes'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2' cache='none' io='native'/>
      <source file='/var/lib/libvirt/vm-images/Win11VM.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <controller type='usb' index='0' model='qemu-xhci' ports='15'/>
    <controller type='sata' index='0'/>
    <controller type='pci' index='0' model='pcie-root'/>
    <controller type='pci' index='1' model='pcie-root-port'/>
    <controller type='pci' index='2' model='pcie-root-port'/>
    <controller type='pci' index='3' model='pcie-root-port'/>
    <controller type='pci' index='4' model='pcie-root-port'/>
    <controller type='pci' index='5' model='pcie-root-port'/>
    <controller type='pci' index='6' model='pcie-root-port'/>
    <controller type='pci' index='7' model='pcie-root-port'/>
    <controller type='virtio-serial' index='0'/>
    <interface type='network'>
      <source network='default'/>
      <model type='virtio'/>
    </interface>
    <channel type='spicevmc'>
      <target type='virtio' name='com.redhat.spice.0'/>
      <address type='virtio-serial' controller='0' bus='0' port='1'/>
    </channel>
    <input type='tablet' bus='usb'/>
    <input type='keyboard' bus='usb'/>
    <input type='mouse' bus='usb'/>
    <graphics type='spice' autoport='yes'>
      <listen type='address'/>
      <image compression='off'/>
      <gl enable='no'/>
    </graphics>
    <video>
      <model type='virtio' heads='1' primary='yes'/>
    </video>
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
    <tpm model='tpm-crb'>
      <backend type='emulator' version='2.0'/>
    </tpm>
  </devices>
</domain>
VMXML

    # swtpm state lives in /var/lib/libvirt/swtpm/<domain UUID>/. Reuse the
    # restored UUID so Windows sees the same TPM (no BitLocker recovery prompt).
    mapfile -t tpm_ids < <(ls /var/lib/libvirt/swtpm 2>/dev/null)
    if [[ ${#tpm_ids[@]} -eq 1 ]]; then
        sed -i "s|<name>Win11VM</name>|<name>Win11VM</name>\n  <uuid>${tpm_ids[0]}</uuid>|" /tmp/Win11VM.xml
        echo "  Reusing UUID ${tpm_ids[0]} (restored swtpm state)."
    else
        echo "  !! ${#tpm_ids[@]} entries in /var/lib/libvirt/swtpm — new UUID, so a NEW TPM (BitLocker may ask for its recovery key)."
    fi
    virsh define /tmp/Win11VM.xml
    rm /tmp/Win11VM.xml
    echo "  Win11VM defined."
fi

# 5. Verify
echo "[5/5] Verification..."
echo ""
echo "=== Storage pools ==="
virsh pool-list --all
echo ""
echo "=== VMs ==="
virsh list --all
echo ""
echo "=== VM XML location ==="
ls -la /etc/libvirt/qemu/Win11VM.xml 2>/dev/null && echo "XML is at /etc/libvirt/qemu/Win11VM.xml — will be captured by restic backup"
echo ""
echo "=== Done ==="
echo "The Win11VM is now registered. The domain XML is at /etc/libvirt/qemu/Win11VM.xml"
echo "Run your restic backup now to capture it."
echo ""
echo "To start the VM:  virsh start Win11VM"
echo "To open console:  virt-manager"
