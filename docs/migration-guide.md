# Framework 13 AMD — Migration Guide

Step-by-step guide for migrating from Fedora Workstation to Fedora Cosmic Atomic
using the custom BlueBuild image.

## Prerequisites

- BlueBuild image built and pushed to GHCR (verified green CI)
- Restic backup completed (DAS connected at `/run/media/<user>/DAS`)
- Cosign private key backed up (`~/migration-prep/bluebuild-recipe/cosign.key`)
- Ventoy USB drive with the Fedora Cosmic Atomic F44 ISO
- 2TB NVMe physically installed in the laptop (4TB removed)

## Step 1: Install Cosmic Atomic from ISO

1. Boot from the Ventoy USB drive
2. Select `Fedora-COSMIC-Atomic-ostree-x86_64-44-1.7.iso`
3. In the Anaconda installer:
   - **Installation Destination:** Select the 2TB NVMe
   - **Partitioning:** Custom (or Standard Partition scheme, NOT LVM)
     - Create these partitions:
       ```
       /boot/efi   600M   EFI System Partition (vfat)
       /boot       2G     ext4
       swap        96G    LUKS encrypted (for hibernation with 60GB RAM)
       /           rest   LUKS encrypted btrfs
       ```
   - **Root Password:** Set it (needed for initial setup)
   - **User:** Create your user `<user>`, make it administrator
4. Begin installation and wait for it to complete
5. Reboot (remove Ventoy USB)

## Step 2: First Boot (Stock Cosmic Atomic F44)

1. Boot into the new system
2. Connect to Wi-Fi (or Ethernet)
3. Open a terminal (Ghostty won't be installed yet — use the default terminal)

## Step 3: Switch to systemd-boot (before rebasing)

The installer uses GRUB by default. Switch to systemd-boot for BLS-native ostree:

```bash
# Install systemd-boot to the ESP
sudo bootctl install

# Configure the loader
sudo mkdir -p /boot/efi/loader
sudo tee /boot/efi/loader/loader.conf << 'EOF'
default @saved
timeout 5
editor yes
EOF

# Set as firmware default
sudo efibootmgr -c -d /dev/nvme0n1 -p 1 \
  -L "systemd-boot" -l '\EFI\systemd\systemd-bootx64.efi'

# Verify
bootctl list
```

Reboot and verify:
```bash
bootctl status    # should say "Product: systemd-boot"
```

## Step 4: Rebase to Custom Image (Unsigned)

The first rebase uses the unsigned image to install the signing keys:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/samwick07/fedora-cosmic-framework:latest
sudo systemctl reboot
```

## Step 5: Second Boot (Custom Image, Unsigned)

Verify the rebase worked:
```bash
rpm-ostree status
# Should show: fedora-cosmic-framework:latest
```

Now rebase to the signed image for verified updates:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-framework:latest
sudo systemctl reboot
```

## Step 6: Third Boot (Custom Image, Signed)

Verify:
```bash
rpm-ostree status
# Should show: ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-framework:latest
```

## Step 7: Enable Hibernation

The swap partition UUID is unique to this install. Run the baked-in script:

```bash
sudo /usr/local/bin/enable-hibernation.sh
```

This detects the swap UUID and sets the `resume=` kernel parameter via `rpm-ostree kargs`.

Reboot for the karg to take effect:
```bash
sudo systemctl reboot
```

## Step 8: Test Hibernation

```bash
# Test suspend first
systemctl suspend

# After wake, test hibernation
systemctl hibernate

# After wake, test suspend-then-hibernate (lid close behavior)
systemctl suspend-then-hibernate
```

If hibernation fails:
- Verify Secure Boot is DISABLED in BIOS (required for resume from encrypted swap)
- Verify the swap partition is large enough (96GB for 60GB RAM)
- Check: `cat /proc/cmdstream` — should contain `resume=UUID=...`
- Check: `swapon --show` — swap should be active

## Step 9: Mount the DAS

```bash
# The DAS is LUKS-encrypted, GNOME may auto-mount it.
# If not, unlock and mount manually:
sudo cryptsetup luksOpen /dev/sda1 luks-00000000-0000-0000-0000-000000000000
sudo mount /dev/mapper/luks-00000000-0000-0000-0000-000000000000 /run/media/<user>/DAS
```

## Step 10: Restore Data from Restic

```bash
# Set up restic env vars
export RESTIC_REPOSITORY="/run/media/<user>/DAS/frmwrk-restic-repo"
export RESTIC_PASSWORD_FILE="$HOME/.restic/frmwrk-repo.pass"

# Verify the repo is accessible
sudo RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
  restic snapshots

# Restore home directory
sudo RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
  restic restore latest --target / --include /home/<user>/

# Restore system configs (if needed)
sudo RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
  restic restore latest --target / --include /etc/libvirt/
sudo RESTIC_REPOSITORY="$RESTIC_REPOSITORY" RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
  restic restore latest --target / --include /etc/NetworkManager/
```

## Step 11: Set Up Distrobox Containers

```bash
# Create all containers from the declarative .ini definitions
/usr/local/bin/distrobox-setup.sh

# Verify
distrobox-list
# Should show: fedora-ws, rocm, debian, ClaudeCode
```

## Step 12: Restore VM Manager VMs

If you backed up the Win11VM XML and qcow2:

```bash
# Ensure libvirtd is running
sudo systemctl start libvirtd

# Define the VM from the XML
sudo virsh define /etc/libvirt/qemu/Win11VM.xml

# Verify
virsh list --all
```

If the qcow2 needs to be restored from backup:
```bash
# Restore the qcow2 (513GB, takes a while)
sudo RESTIC_REPOSITORY="/run/media/<user>/DAS/frmwrk-restic-repo" \
  RESTIC_PASSWORD_FILE="$HOME/.restic/frmwrk-repo.pass" \
  restic restore latest --target / --include /var/lib/libvirt/vm-images/
```

## Step 13: Install Flatpaks

The default flatpaks are installed on first boot, but user-scope flatpaks
may need manual install:

```bash
flatpak install flathub org.mozilla.firefox
flatpak install flathub io.github.zen_browser.zen
flatpak install flathub com.github.tchx84.Flatseal
flatpak install flathub it.mijorus.gearlever
flatpak install flathub org.videolan.VLC
flatpak install flathub org.darktable.Darktable
flatpak install flathub org.inkscape.Inkscape
flatpak install flathub org.gimp.GIMP
flatpak install flathub com.calibre_ebook.calibre
flatpak install flathub org.zotero.Zotero
flatpak install flathub com.visualstudio.code
```

## Step 14: Restore Hermes

If you backed up Hermes to the DAS:

```bash
# Restore Hermes config and state
rsync -av /run/media/<user>/DAS/hermes-backup/ ~/.hermes/
```

## Verification Checklist

After completing all steps, verify:

- [ ] `rpm-ostree status` shows the signed custom image
- [ ] `bootctl status` shows systemd-boot
- [ ] `systemctl hibernate` works (suspends to disk and resumes)
- [ ] Lid close triggers suspend-then-hibernate
- [ ] DAS mounts and restic repo is accessible
- [ ] `distrobox-list` shows all 4 containers
- [ ] Flatpaks are installed and launch
- [ ] Wi-Fi works (NetworkManager configs restored)
- [ ] `rocminfo` works inside the rocm distrobox container
- [ ] `tailscale status` shows connected
- [ ] `virt-manager` opens and Win11VM is listed

## Rollback

If anything goes wrong, ostree makes rollback trivial:

```bash
# Rollback to previous deployment
sudo rpm-ostree rollback
sudo systemctl reboot
```

If the system is unbootable:
- The previous deployment appears in the systemd-boot menu at boot time
- Select it to boot into the previous working state
- From there, investigate or rollback

## Fedora 45 Upgrade (After Oct 20 Release)

Wait 2-4 weeks after F45 release for COPR packages to catch up, then:

1. Edit `recipes/recipe-framework.yml`:
   ```yaml
   image-version: 45  # was 44
   ```
2. Commit and push:
   ```bash
   git add recipes/*.yml && git commit -m "upgrade: Fedora 45" && git push
   ```
3. Wait for GitHub Actions to build (green checkmark)
4. On the laptop:
   ```bash
   rpm-ostree upgrade
   sudo systemctl reboot
   ```
