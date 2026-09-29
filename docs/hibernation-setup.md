# Hibernation on Fedora Atomic COSMIC — Complete Guide

## Overview

Your current Fedora Workstation uses a 96GB LUKS-encrypted swap partition
for hibernation with suspend-then-hibernate on lid close. This document
explains how to replicate that setup on Fedora Atomic COSMIC.

## The challenge with Atomic

On Fedora Workstation, hibernation needs:
  1. A swap partition (you have: 96GB LUKS on nvme0n1p3)
  2. resume=UUID=... kernel parameter (in GRUB config)
  3. rd.luks.uuid=luks-... (in GRUB config, for LUKS swap unlock at boot)
  4. /etc/systemd/sleep.conf (HibernateDelaySec)
  5. /etc/systemd/logind.conf (HandleLidSwitch)
  6. SELinux policy (for systemd-logind/swap access)

On Fedora Atomic, the challenges are:
  - /etc is writable but not part of the immutable image (persists across
    rebases, but can be overridden by image updates)
  - Kernel parameters are set via `rpm-ostree kargs`, not /etc/default/grub
  - The swap partition UUID is unique per installation, so resume= can't
    be baked into the image
  - The BlueBuild kargs module uses bootc, not rpm-ostree, so it requires
    bootc update instead of rpm-ostree upgrade for kargs to apply

## The solution: Two-phase approach

### Phase 1: Build-time (baked into the image)

These are in the BlueBuild recipe and apply automatically:

  - /etc/systemd/sleep.conf (HibernateDelaySec=300)
  - /etc/systemd/logind.conf (HandleLidSwitch=suspend-then-hibernate)
  - SELinux policy module (systemd_hibernate)
  - The enable-hibernation.sh script (placed at /usr/local/bin/)

### Phase 2: Post-install (run once after first boot)

These depend on the specific installation and must be done manually:

  - Set resume=UUID=<swap-uuid> kernel parameter
  - Set rd.luks.uuid=luks-<swap-luks-uuid> kernel parameter
  - Verify SELinux policy is loaded

## Installation steps

### During Fedora Atomic COSMIC installation

Create the partition layout with a LUKS-encrypted swap partition,
following the Framework guide:

  1. In the Anaconda installer, choose Custom partitioning
  2. Create /boot/efi (600MB, EFI System Partition)
  3. Create /boot (1.2GB, ext4)
  4. Create swap partition:
     - Device Type: Standard Partition
     - Check: Encrypt
     - Size: RAM × 1.5 (96GB for 60GB RAM)
  5. Create / (root, btrfs, encrypted, rest of drive)

This matches your current layout exactly:
  p1: 600M  EFI    (/boot/efi)
  p2: 1.2G  ext4   (/boot)
  p3: 96G   LUKS   (swap)
  p4: rest  LUKS   (btrfs root)

### After first boot (with your BlueBuild image rebased)

Run the post-install script:

  sudo /usr/local/bin/enable-hibernation.sh

This script will:
  1. Detect your swap partition and its UUID
  2. Set resume=UUID=<swap-uuid> via rpm-ostree kargs
  3. Install the SELinux policy if not already loaded
  4. Verify all configs are in place

Then reboot.

### After reboot: test

  # Test hibernation directly
  systemctl hibernate

  # Test suspend-then-hibernate
  systemctl suspend-then-hibernate

  # Close the lid — should suspend, then hibernate after 5 minutes

## What the recipe bakes in vs what you set post-install

  BAKED IN (in recipe-framework.yml):
  ─────────────────────────────────
  /etc/systemd/sleep.conf          → HibernateDelaySec=300
  /etc/systemd/logind.conf        → HandleLidSwitch=suspend-then-hibernate
  SELinux policy module            → systemd_hibernate
  /usr/local/bin/enable-hibernation.sh

  POST-INSTALL (via enable-hibernation.sh):
  ─────────────────────────────────
  resume=UUID=<swap-uuid>          → rpm-ostree kargs
  rd.luks.uuid=luks-<luks-uuid>    → Already set by Anaconda installer

## Why the swap partition UUID can't be in the recipe

The swap partition's UUID is generated when you create the LUKS container
during installation. It's unique to each installation. If we baked
resume=UUID=... into the image, it would point at a UUID that doesn't
exist on any other machine.

The kargs module in BlueBuild uses bootc (not rpm-ostree) to inject kernel
arguments. This works for static kargs that don't depend on the installation.
For the resume= parameter, which is installation-specific, the post-install
script uses `rpm-ostree kargs` directly.

## Secure Boot requirement

  Secure Boot must be DISABLED for hibernation to work.

This is a kernel limitation, not a Fedora one. The kernel's lockdown
feature (active when Secure Boot is enabled) blocks resume from an
encrypted swap partition. This was confirmed by the Universal Blue
community and Framework's own documentation.

This affects both your Framework 13 and your desktop. However, the desktop
doesn't need hibernation (it's not a laptop). The Framework needs it for
battery preservation when the lid is closed.

## Your current config (for reference)

  Current swap: /dev/dm-1 (mapped from nvme0n1p3 LUKS)
  Swap UUID: e6156996-4914-41d1-a35d-7150bf658859
  LUKS UUID: 00000000-0000-0000-0000-000000000000
  Current resume= param: resume=UUID=e6156996-4914-41d1-a35d-7150bf658859
  Current rd.luks.uuid: rd.luks.uuid=luks-00000000-0000-0000-0000-000000000000
  HibernateDelaySec: 300 (5 minutes)
  HandleLidSwitch: suspend-then-hibernate

## Alternative: Swapfile instead of swap partition

If you don't want a dedicated swap partition, you can use a swapfile
under /var/swap on Atomic. The enable-hibernation.sh script handles this
case automatically. The swapfile approach:

  Pros:
  - No separate partition needed
  - Can resize easily
  - Works with Atomic's partition layout

  Cons:
  - Slightly more complex setup (need resume_offset)
  - btrfs swapfile needs +C (no CoW) attribute
  - Must be under /var (the writable area on Atomic)

Your current setup uses a dedicated partition, which is simpler. If you
use the same partition layout during install (which the Framework guide
recommends), the post-install script will detect it automatically.

## COSMIC-specific notes

The Framework hibernation guide references a GNOME extension for the
hibernate button. Since you're using COSMIC (not GNOME), you don't need
the extension. The systemd configs (sleep.conf and logind.conf) handle
everything:

  - Lid close → suspend-then-hibernate (via logind.conf)
  - Suspend → hibernate after 5 min (via sleep.conf)
  - Manual hibernate: systemctl hibernate
  - Manual suspend-then-hibernate: systemctl suspend-then-hibernate

COSMIC may add its own power management UI in the future. For now,
the systemd configs are the mechanism, and they're baked into your image.

## Future: kernel 6.11+ Bluetooth workaround

If you hibernate with Bluetooth enabled on kernel 6.11+, you may get a
black screen on resume. Framework has a workaround documented at:
  https://github.com/FrameworkComputer/linux-docs/blob/main/hibernation/kernel-6-11-workarounds/suspend-hibernate-bluetooth-workaround.md

This is a kernel bug, not specific to Atomic. The workaround involves
a systemd service that disables Bluetooth before suspend and re-enables
it after resume. If you encounter this, add a script to the recipe:

  scripts/bt-suspend-workaround.sh

And a systemd service in the system/ directory:
  system/etc/systemd/system/bt-suspend.service

This can be added to the recipe if needed after testing.
