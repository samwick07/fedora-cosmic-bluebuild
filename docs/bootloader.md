# Bootloader: GRUB, and why not systemd-boot (yet)

Both images boot with **GRUB2 + shim**, the Fedora Atomic default. bootc /
rpm-ostree write Boot Loader Specification entries to `/boot/loader/entries/`
and a static `grub.cfg` on `/boot` reads them; new deployments and rollback
entries appear in the menu automatically. Nothing to configure.

## Why the systemd-boot plan was dropped

The previous version of this repo tried to switch to systemd-boot two ways.
Both produce an unbootable disk with the partition layout we use:

1. `bootc install --bootloader systemd` needs `systemd-boot-unsigned` inside
   the image (it is not in the Fedora base and was not layered) and expects the
   ESP mounted at `/boot`. With a stock image bootc *reports success* and
   leaves no bootloader ([bootc#2486](https://github.com/bootc-dev/bootc/issues/2486)).
2. `bootctl install` after an Anaconda install: ostree puts kernels and BLS
   entries on the ext4 `/boot`; systemd-boot only reads FAT (ESP/XBOOTLDR), so
   the menu is empty ([ostree#1719](https://github.com/ostreedev/ostree/issues/1719)).

## If you want to try it later

Do it on the test drive, after everything else works:

- Repartition with a **single 1–2 GB FAT ESP mounted at `/boot`** (no ext4
  `/boot`), swap LUKS, root LUKS.
- Layer `systemd-boot-unsigned` in the recipe.
- Secure Boot stays off (already required for hibernation).
- `bootc install to-filesystem --bootloader systemd` with the ESP pre-mounted
  at `/target/boot`; drop `--boot-mount-spec`.

Verify with `bootctl status` and `bootctl list` (every deployment must be
listed) before trusting it.

## Rollback with GRUB

Hold **Shift** or press **Esc** during boot for the menu; pick the previous
deployment. Make it permanent with `sudo bootc rollback` (or `rpm-ostree rollback`).
