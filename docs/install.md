# Install: stock COSMIC Atomic ISO + this repo's kickstart (spec L1)

From a blank (or to-be-erased) disk to a machine that passes `sudo cosmic-acceptance`.
Everything that can be declared is: the partitioning and the image come from
`install/frmwrk.ks`, the rest is finished by the image at first boot. What a person does:
pick the disk, type the passphrase and the user, switch Secure Boot off, reboot twice.
Until the user says the 2TB test passed, the **only** target is the 2TB test drive.

## Before you start

| What | Why |
| --- | --- |
| Fedora COSMIC Atomic 44 ISO on a USB stick ([fedoraproject.org/atomic-desktops](https://fedoraproject.org/atomic-desktops/)) | The stock installer |
| The target's name in `/dev/disk/by-id` (e.g. `nvme-Samsung_SSD_990_PRO_2TB_<serial>`) | The kickstart touches only that disk, and refuses the 4TB and the DAS on its own |
| Network (a cable, or Wi-Fi chosen in the installer) | The image comes from the registry |

To read the disk names: boot the USB stick, Ctrl+Alt+F2, `ls -l /dev/disk/by-id/ | grep -v part`,
Ctrl+Alt+F6 back, reboot.

## 1. Install (kickstart)

1. Boot the USB stick (F12 on the Framework). At the boot menu, highlight the install
   entry, press **e**, and append to the `linux` line:
   ```
   inst.ks=https://raw.githubusercontent.com/samwick07/fedora-cosmic-bluebuild/main/install/frmwrk.ks cosmic.disk=<name> cosmic.hostname=frmwrk-test
   ```
   (`cosmic.hostname` only for the test install; the default is `frmwrk`.) Ctrl+X boots.
2. The installer opens with storage and software already set. It asks for the **LUKS
   passphrase** (one, for root and swap), and you create the **user** (administrator).
   Language and time zone as you like. Begin installation, reboot.

If the kickstart refuses (no `cosmic.disk`, unknown disk, or a protected volume on it), the
reason is on the screen and in `/tmp/cosmic-pre.log`; nothing has been written.

## 2. First boot

1. LUKS passphrase, login, network. The image finishes the install by itself:
   `cosmic-signed-origin` switches updates to signature-verified, `cosmic-hibernation`
   adds the hibernation kernel arguments, `cosmic-net-box` builds the rootful `net` box
   in the background. All of them stage changes; **reboot once** to apply them.
2. **Secure Boot off** in the firmware setup (F2 at power-on → Security). Hibernation needs
   it (spec F2). This is the one setting outside the disk.

## 3. Check the image layer

```bash
sudo cosmic-acceptance        # automatic checks + the list of manual ones
```

## 4. User layer

```bash
ssh-keygen -t ed25519 -C "$(hostname)"   # one key per machine (I1); add it on GitHub
brew install chezmoi                     # Homebrew came with the image
chezmoi init --apply git@github.com:samwick07/dotfiles.git
sudo cosmic-enroll                       # fingerprint, then TPM2 + PIN (finger, passphrase, PIN)
sudo cosmic-acceptance --user
```

## 5. Migration, then acceptance

The one-time steps are private: `dotfiles/.migration-prep/MIGRATION.md`, part B, mostly run
by its script. When every check of spec section 6 passes:

```bash
sudo cosmic-acceptance --pin             # pins this deployment as known-good (L3)
```

## Without the kickstart (fallback)

Install interactively: Installation destination → only the target disk (check model and
serial) → Advanced Custom: ESP 1 GiB, ext4 `/boot` 2 GiB, encrypted swap ≥ RAM (96 GiB),
encrypted btrfs for the rest with subvolumes `root` → `/` and `home` → `/home`. After the
first boot: `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` and reboot;
from there the same first-boot services finish the job (reboot once more).

## If something goes wrong

| Symptom | Do |
| --- | --- |
| Black screen after login | Ctrl+Alt+F3, log in, `sudo systemctl restart cosmic-greeter` (`known-issues.md`) |
| The installer cannot fetch the image | Network in the installer? The kickstart's `ostreecontainer` needs the registry |
| A first-boot service failed | `systemctl status cosmic-signed-origin cosmic-hibernation cosmic-net-box`; they retry on their own while offline |
| Hibernate does nothing | `docs/hibernation-setup.md` |
| A bad image after an update | Previous or pinned entry in the GRUB menu, or `sudo bootc rollback` |
