# Install: stock COSMIC Atomic ISO, then the signed image (spec L1)

From a blank (or to-be-erased) disk to a machine that passes `sudo cosmic-acceptance`.
About an hour plus downloads. Until the user says the 2TB test passed, the **only**
target is the 2TB test drive (CLAUDE.md ground rules).

## Before you start

| What | Why |
| --- | --- |
| Fedora COSMIC Atomic 44 ISO on a USB stick ([fedoraproject.org/atomic-desktops](https://fedoraproject.org/atomic-desktops/)) | The stock installer (Anaconda) |
| The target disk's model and serial, written down | You confirm them in Anaconda before anything is written |
| Network (Wi-Fi password or a cable) | `bootc switch` downloads the image |
| A LUKS passphrase and a login password | Chosen during the install |

## 1. Partition and install (Anaconda)

1. Boot the USB stick (F12 on the Framework). Language, keyboard.
2. **Installation destination → select only the target disk.** Check its model and serial
   against your note. Every other disk stays unticked (the 4TB Workstation drive and the
   DAS must never be written).
3. **Storage configuration: Advanced Custom (Blivet-GUI)** or Custom; delete what is on the
   target disk, then create:

   | Partition | Size | Type | Mount |
   | --- | --- | --- | --- |
   | EFI system | 1 GiB | EFI (FAT32) | `/boot/efi` |
   | boot | 2 GiB | ext4 | `/boot` |
   | swap | ≥ RAM (frmwrk: 96 GiB) | swap, **encrypted** (LUKS2) | — |
   | system | the rest | btrfs, **encrypted** (LUKS2), subvolumes `root` → `/` and `home` → `/home` | |

   Same passphrase for both LUKS containers (one prompt at boot, F5). `/home` as its own
   subvolume matters: the hourly snapshots and consistent backups need it (S2e).
4. Create the user (administrator, i.e. in `wheel`). Install. Reboot.

## 2. First boot: switch to the signed image

At the LUKS prompt, the passphrase; at the greeter, your login. Connect to the network.
Open COSMIC Terminal (host):

```bash
sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk:latest     # stock -> our image
systemctl reboot
```

After the reboot the image's signing policy is in place; switch once more so that every
future update is verified against `cosign.pub`:

```bash
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest
systemctl reboot
```

## 3. Firmware and kernel arguments

1. **Secure Boot off** in the firmware setup (F2 at power-on → Security). Hibernation
   needs it (F2; kernel lockdown blocks resume otherwise).
2. Kernel arguments for hibernation (Anaconda usually writes them; this adds what is
   missing and says so):
   ```bash
   sudo enable-hibernation.sh --check
   sudo enable-hibernation.sh            # only if --check reports something missing
   systemctl reboot
   ```

## 4. Check the image layer

```bash
findmnt /var/home                       # btrfs, subvol=/home (or similar)
sudo btrfs subvolume show /var/home     # must succeed (S2e)
sudo cosmic-acceptance                  # automatic checks + the list of manual ones
```

Fix every FAIL before going on; the manual list is the rest of section 6 of the spec.

## 5. User layer

```bash
ssh-keygen -t ed25519 -C "$(hostname)"  # one key per machine (I1); add it on GitHub
brew install chezmoi                    # Homebrew came with the image
chezmoi init --apply git@github.com:samwick07/dotfiles.git
sudo cosmic-acceptance --user
```

The dotfiles README has the details (Brewfile, boxes, the rootful `vpn` box by hand).

## 6. Migration, then acceptance

The one-time checklist is private: `dotfiles/.migration-prep/MIGRATION.md`, part B. It ends
with the first backups and a restore test (`docs/restore.md`). When the whole section 6
passes: pin the accepted deployment, so a known-good one stays in GRUB (L3):

```bash
sudo ostree admin pin 0
```

## If something goes wrong

| Symptom | Do |
| --- | --- |
| Black screen after login | Ctrl+Alt+F3, log in, `sudo systemctl restart cosmic-greeter` (`known-issues.md`) |
| `bootc switch` fails to pull | Network? `podman pull ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` shows the error |
| `rpm-ostree rebase` refuses the signature | The previous step did not boot our image: `rpm-ostree status` |
| Hibernate does nothing | `docs/hibernation-setup.md` |
| A bad image after an update | Previous entry in the GRUB menu, or `sudo bootc rollback` |
