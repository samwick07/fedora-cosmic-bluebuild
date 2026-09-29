# systemd-boot on Fedora Atomic COSMIC — Setup Guide

## Why systemd-boot over GRUB2

systemd-boot is BLS-native (Boot Loader Specification). ostree writes BLS
entry files to /boot/loader/entries/ — systemd-boot reads these directly,
with no GRUB config generation step. This means:

  - Simpler boot configuration (no grub2-mkconfig, no grub.cfg)
  - Faster boot (minimal bootloader, no scripting engine)
  - Clean rollback entries in the boot menu
  - Fedora is actively moving toward systemd-boot as a first-class option
  - UKI (Unified Kernel Image) support for future-proofing

## When to do this

After installing Fedora Atomic COSMIC, before rebasing to your BlueBuild
image. This way the bootloader is set up on the stock install, and your
custom image inherits the bootloader configuration.

## Prerequisites

  - Fedora Atomic COSMIC installed and booted on UEFI (not legacy BIOS)
  - Both machines are UEFI (Framework 13 and ROG STRIX X870-I are UEFI-only)
  - You have sudo access

## Step-by-step: Switch from GRUB2 to systemd-boot

### 1. Install systemd-boot to the ESP

```bash
# The ESP (EFI System Partition) is at /boot/efi on Fedora Atomic.
# Check it's mounted:
mount | grep boot/efi
# Should show: /dev/nvme0n1p1 on /boot/efi type vfat

# Install systemd-boot
sudo bootctl install

# This installs systemd-bootx64.efi to /boot/efi/EFI/systemd/
# and sets it as the default bootloader
```

### 2. Configure systemd-boot

```bash
# Create the loader configuration
sudo mkdir -p /boot/efi/loader/loader.conf

sudo tee /boot/eff/loader/loader.conf << 'EOF'
# Default to the first (most recent) entry
default @saved
# Show the boot menu for 5 seconds (useful for rollback selection)
timeout 5
# Try to boot the saved entry, fall back to the first entry
editor yes
EOF
```

### 3. Verify ostree BLS entries are visible

```bash
# ostree writes BLS entries to /boot/loader/entries/
ls /boot/loader/entries/
# Should see .conf files for each ostree deployment

# Check that systemd-boot can see them
bootctl list
# Should list all available boot entries including your current deployment
```

### 4. Set systemd-boot as the firmware default

```bash
# Set the boot order in the UEFI firmware
sudo efibootmgr -c \
  -d /dev/nvme0n1 -p 1 \
  -L "systemd-boot" \
  -l '\EFI\systemd\systemd-bootx64.efi'

# Verify it's first in the boot order
efibootmgr
# BootOrder should list "systemd-boot" first
```

### 5. Remove GRUB2 (optional, but cleaner)

```bash
# On Fedora Atomic, you can't remove GRUB2 from the image (it's in the
# base ostree), but you can stop using it by making sure the firmware
# boots systemd-boot first. The GRUB2 EFI files remain on disk but are
# unused.

# If you want to clean up the GRUB EFI files from the ESP:
sudo rm -rf /boot/efi/EFI/fedora
# CAUTION: Only do this after confirming systemd-boot boots and lists
# your ostree deployments correctly.
```

### 6. Reboot and verify

```bash
sudo systemctl reboot
```

After reboot:
```bash
# Verify you're using systemd-boot
bootctl status
# Should say "Product: systemd-boot" and show the current entry

# Verify ostree is still working
rpm-ostree status
# Should show your current deployment

# Verify the boot menu shows rollback entries
# (Press ESC or wait at the 5-second timeout during boot)
```

### 7. After rebasing to your BlueBuild image

```bash
# After you rebase to your custom image:
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/USERNAME/fedora-cosmic-framework:latest
sudo systemctl reboot

# systemd-boot will automatically pick up the new ostree deployment's
# BLS entry. No GRUB config to regenerate. The boot menu will show both
# the new deployment and the previous one (for rollback).

# Future rpm-ostree upgrades will also just work:
rpm-ostree upgrade
sudo systemctl reboot
# New deployment appears in systemd-boot menu automatically.
```

## How ostree + systemd-boot interact

```
rpm-ostree upgrade
       │
       ▼
ostree downloads new deployment
       │
       ▼
ostree writes new BLS .conf file
to /boot/loader/entries/
       │
       ▼
systemd-boot reads /boot/loader/entries/
on next boot and shows both old
and new deployments in the menu
       │
       ▼
Boot into new deployment.
If it fails, reboot and pick
the old entry from the menu.
```

No grub2-mkconfig. No grub.cfg. No blscfg module. Just BLS entries that
systemd-boot reads directly.

## Fedora Atomic specifics

Fedora Atomic (since F41) uses a static GRUB config that just chainloads
to BLS entries. When you switch to systemd-boot, you bypass GRUB entirely
and read those same BLS entries directly. The ostree deployment mechanism
doesn't change — only the bootloader that reads its output.

The Fedora change proposal "cleanup systemd install" (Changes/cleanup_systemd_install)
is working toward making `inst.sdboot` a first-class anaconda install option.
This means future Fedora Atomic installs may offer systemd-boot during
installation itself. For now, you install with GRUB and switch after.

## Troubleshooting

### bootctl install fails
  - Ensure /boot/efi is mounted and is vfat
  - Ensure you're booted in UEFI mode (not legacy BIOS)
  - Check: ls /sys/firmware/efi (should exist)

### ostree entries not showing in bootctl list
  - Check: ls /boot/loader/entries/ (should have .conf files)
  - If missing, ostree may need to re-deploy:
    sudo rpm-ostree upgrade (even if no update available)

### System boots into GRUB instead of systemd-boot
  - Check efibootmgr boot order
  - Some motherboards reset to the firmware default after CMOS clear
  - On the ROG STRIX X870-I: enter BIOS → Boot → set "systemd-boot" as
    Boot Option #1
  - On the Framework 13: enter BIOS (F2) → Boot → set "systemd-boot"
    as the first option

### Rollback with systemd-boot
  - During boot, wait for the 5-second timeout (or press a key)
  - systemd-boot shows a menu of all BLS entries
  - Select the previous deployment
  - To make it permanent: sudo rpm-ostree rollback
