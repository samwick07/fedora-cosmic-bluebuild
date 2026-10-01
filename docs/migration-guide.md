# Framework 13 AMD — Install, Migration and Recovery Runbook

This is the complete procedure to bring the laptop back from nothing: a blank or
existing disk, the DAS with the restic repo, this repository, and a machine that
can run podman. Follow it top to bottom for the first install; for a rebuild
after a disaster start at **Phase 2**.

Two disks are involved during the migration:

| Disk | Role | LUKS UUIDs (protected by `install-atomic.sh`) |
| --- | --- | --- |
| 4TB NVMe (internal) | Fedora 44 Workstation — the current OS. Untouched until Phase 5. | root `00000000-0000-0000-0000-000000000000`, swap `00000000-0000-0000-0000-000000000000` |
| 2TB NVMe in the DAS enclosure | Test target. Gets wiped and reinstalled freely. | (see `scripts/targets/2tb-test.env` after generating it) |
| DAS data disk | restic repos, backup scripts, hermes backup. Never a target. | `00000000-0000-0000-0000-000000000000` |

Bootloader: **GRUB** (Fedora Atomic default, BLS entries on the ext4 `/boot`).
See `docs/bootloader.md` for why systemd-boot is not used.

---

## Phase 0 — Before touching anything

1. **Backup is fresh and verified.** On the Workstation:
   ```bash
   export RESTIC_REPOSITORY=/run/media/<user>/DAS/frmwrk-restic-repo RESTIC_PASSWORD_FILE=~/.restic/frmwrk-repo.pass
   sudo restic unlock
   sudo restic snapshots --latest 3
   sudo restic check --read-data-subset=10%           # ~1 h on USB; do the full --read-data once before Phase 5
   # dry-run restore of something small, to prove passphrase + syntax
   sudo restic restore latest --target /tmp/rt --include /home/<user>/.ssh && ls -la /tmp/rt/home/<user>/.ssh && sudo rm -rf /tmp/rt
   ```
   If the backup script on the DAS is older than `backup/frmwrk_backup_command.sh`
   in this repo, copy the repo versions over and run a backup:
   ```bash
   cp backup/frmwrk_backup_command.sh backup/frmwrk-restic-excludes /run/media/<user>/DAS/
   /run/media/<user>/DAS/frmwrk_backup_command.sh
   ```
2. **Secrets off the machine.** Copy to a USB stick / password manager:
   `~/.restic/frmwrk-repo.pass` (and know the passphrase itself), `cosign.key`,
   the LUKS passphrases, the Windows VM BitLocker recovery key if enabled.
3. **Secure Boot OFF** in the Framework firmware (F2 → Security). Required for
   hibernation (kernel lockdown) and for the custom image.
4. **Image built and pushed.** `docs/local-build.md`. You need
   `localhost/fedora-cosmic-frmwrk:latest` in podman and the same image on
   GHCR (public) for updates.
5. **Dotfiles repo exists.** Push `~/migration-prep/dotfiles` to
   `github.com/samwick07/dotfiles` (private is fine — step 6 clones over SSH with
   the restored key). Test it on the Workstation first:
   `chezmoi init --source ~/migration-prep/dotfiles --dry-run --verbose` shows
   exactly what would change without touching anything.
6. **Syncthing on dsktp: pause every shared folder** before the install.
   Test drive: keep them paused for the WHOLE test, until the 4TB Workstation is
   booted again (the test system has the same device identity). Real 4TB run:
   resume after `post-install-setup.sh` step 6, which asks you to confirm the pause
   before it enables Syncthing.

---

## Phase 1 — Prepare the target disk

The install script does **not** partition. The disk must already have:

```
p1  600M   vfat         EFI system partition
p2  1–2G   ext4         /boot
p3  96G    crypto_LUKS  -> swap        (RAM 60 GB × 1.5; needed for hibernation)
p4  rest   crypto_LUKS  -> btrfs /     (the script reformats the btrfs, keeps the LUKS)
```

The 2TB test drive already has this layout (from the previous attempt). For a
blank disk, create it once — either with the Fedora installer (Custom
partitioning, "Encrypt" on p3 and p4, then abort/ignore the OS it installs) or
by hand:

```bash
D=/dev/sdX                                     # CHECK with lsblk -o NAME,SIZE,MODEL first
sudo sgdisk --zap-all $D
sudo sgdisk -n1:0:+600M -t1:ef00 -c1:EFI \
            -n2:0:+2G   -t2:8300 -c2:boot \
            -n3:0:+96G  -t3:8309 -c3:cryptswap \
            -n4:0:0     -t4:8309 -c4:cryptroot $D
sudo mkfs.vfat -F32 -n EFI ${D}1
sudo mkfs.ext4 -L boot ${D}2
sudo cryptsetup luksFormat --type luks2 ${D}3
sudo cryptsetup luksFormat --type luks2 ${D}4
# The install script will mkswap / mkfs.btrfs inside the containers.
```

Then generate the target file and **read it against `lsblk`**:

```bash
cd ~/migration-prep/fedora-cosmic-bluebuild
sudo scripts/make-target-env.sh /dev/sdX > scripts/targets/2tb-test.env
lsblk -o NAME,SIZE,FSTYPE,UUID,MODEL /dev/sdX
cat scripts/targets/2tb-test.env
```

---

## Phase 2 — Install

```bash
cd ~/migration-prep/fedora-cosmic-bluebuild
sudo scripts/install-atomic.sh scripts/targets/2tb-test.env
```

The script prints the disk, every partition and what it will do, then waits for
you to type the disk name. It refuses to run if any protected UUID or the
running OS is on the target. Expect ~5–10 minutes. It ends with
`Installation complete on /dev/sdX`.

If it fails, the most useful evidence is the bootc output plus
`sudo findmnt -R /mnt/atomic-target`. Fix, re-run: the script reformats the
btrfs root each time, so a half-written target is never a problem.

Behind the scenes it does: `mkfs.btrfs` → mount root, `/boot`, `/boot/efi` →
`bootc install to-filesystem --bootloader grub --boot-mount-spec UUID=<boot>
--karg rd.luks.uuid=<root> --karg rd.luks.uuid=<swap> --karg resume=UUID=<swap-fs>`
→ writes `/etc/crypttab`, `/boot`, `/boot/efi` and swap lines into the new
deployment's `/etc/fstab` → creates the `<user>` user + passwords → copies the
target `.env` to `/etc/fedora-cosmic-atomic/install-target.env` on the new system.

---

## Phase 3 — First boot

1. Reboot, **F12**, choose the target disk (it appears as its enclosure or
   "Fedora"). Both LUKS containers prompt (once if the passphrases match).
2. Log in as **`<user>`** with the password you typed during the install
   (the script created the user, uid 1000, in `wheel` and `libvirt`, and gave
   root the same password). There is no first-run wizard on the bootc path.
3. Connect to Wi-Fi. Open the terminal (COSMIC Terminal; Ghostty is in the image too).
4. Sanity:
   ```bash
   bootc status                     # image: ghcr.io/samwick07/fedora-cosmic-frmwrk:latest
   cat /proc/cmdline                # rd.luks.uuid=… ×2, resume=UUID=…
   swapon --show                    # the 96G partition
   findmnt /boot /boot/efi
   ```
5. If the DAS is not auto-mounted, click it in Files (unlock) so it is at
   `/run/media/<user>/DAS`. Otherwise step 1 of the next script unlocks it.

---

## Phase 4 — Restore data, then declare the rest

```bash
sudo post-install-setup.sh
```

Steps, in order (each idempotent; `--step N` reruns one, `--check` reports):

| # | Does | Needs |
| --- | --- | --- |
| 1 | Mounts the DAS by LUKS UUID | DAS attached, passphrase |
| 2 | Restores `~/.restic` (prompts for the repo passphrase), then every path in `/etc/fedora-cosmic-atomic/restore-allowlist.txt` in order — Syncthing data folders, `.ssh`/`.gnupg`/`.config/gh`, `.claude`/`.hermes`/`migration-prep`, and **last** the Syncthing identity; plus `/etc/NetworkManager` and the restic sudoers | hours for ~1.4 TiB |
| 3 | Verifies hibernation (karg, swap, SELinux); repairs on the Anaconda path | — |
| 4 | CAC system half: pcscd, DoD roots into the system trust | cert bundle from step 2 |
| 5 | libvirt: modular daemons, `/etc/libvirt`, `Win11VM.qcow2` (512 GB), NVRAM + swtpm state, defines the VM | — |
| 6 | **User layer**: `chezmoi init --apply git@github.com:samwick07/dotfiles.git`. Its `run_once` scripts install Homebrew + `~/.Brewfile`, `distrobox assemble` the `dev`/`claude`/`rocm` containers, apply flatpak overrides, run `setup-cac.sh --user`, enable the Syncthing user service | SSH key from step 2; network; ~6 GB of pulls |
| 7 | Tailscale: restore the old node identity or `tailscale up` as a new node | interactive |

Then **log out and back in** (libvirt group, brew on PATH, dotfiles), and reboot
if step 3 changed kargs.

Nothing else from the old `~` comes back automatically — that is the point.
`docs/clean-room.md` has the three-line recipe for pulling anything you miss
from the archive and deciding which lane it belongs in.

Not done by the script, by design:

- **Docker → Podman**: `migrate-docker-to-podman.sh` (in `/usr/bin`) moves the
  Open WebUI / SearXNG volumes from the backup into rootless podman. Run once.
- **Hermes**: `~/.hermes` config is restored, the runtime is not (it was
  excluded from the backup). Reinstall Hermes, then
  `systemctl --user enable --now hermes-gateway.service` (unit comes from dotfiles).
- **Claude Desktop + CLI**: the `claude` distrobox is assembled by chezmoi with
  `claude-desktop` installed and exported ("Claude (on claude)" in the menu);
  `run_once_25-claude-cli.sh` installs the CLI into the same box and `claude`
  on the host is an alias into it. Sign in again on first launch.
- **VS Code / Antigravity settings**: not restored. Sign in with Settings Sync,
  or pull `~/.config/Code/User/settings.json` from the archive and
  `chezmoi add` it.

## Phase 5 — Validate, then do it for real

Validation checklist for the test drive (all must pass before the 4TB run):

- [ ] Boots unattended to the LUKS prompt and to the COSMIC login; `bootc status` shows the GHCR image
- [ ] `systemctl hibernate` → power off → power on → session resumes; lid close suspends, hibernates after 5 min
- [ ] Wi-Fi and the OpenVPN/OpenConnect profiles connect
- [ ] `post-install-setup.sh --check` is all green
- [ ] `chezmoi doctor` clean; `brew bundle check --global` says satisfied; `code` opens from the app menu (exported from the `dev` box)
- [ ] `distrobox enter rocm -- rocminfo | grep gfx` shows gfx1103 (with `HSA_OVERRIDE_GFX_VERSION=11.0.0` exported)
- [ ] Syncthing (test drive): keep every folder **paused on dsktp for the whole test**, then run
      `~/migration-prep/fedora-cosmic-bluebuild/scripts/test/syncthing-2tb-check.sh` — it asks you to confirm the
      pause, pauses every local folder, proves frmwrk connects to dsktp (direct over Tailscale), then stops and
      disables Syncthing so the 4TB can go back in safely. Delete the script once it passes.
- [ ] **Full Win11 VM test** (step 5 restores the real 512 GB disk — do not skip it on the test drive):
    - [ ] `virsh -c qemu:///system start Win11VM`; boots to the Windows login, no BitLocker recovery prompt (swtpm + NVRAM restored)
    - [ ] Secure Boot + TPM 2.0 present in Windows (`tpm.msc`, `msinfo32` → Secure Boot State: On)
    - [ ] virtio: disk on the Red Hat VirtIO SCSI/block driver, network on the VirtIO Ethernet adapter, internet works
    - [ ] Display/input over SPICE in virt-manager; clipboard if spice-vdagent is installed in Windows
    - [ ] CAC into Windows: `sudo win11-cac attach` → in Windows `certutil -scinfo` lists the card and certs → a DoD site works in Edge → `sudo win11-cac detach` → on the host `opensc-tool --list-readers` sees the reader again
- [ ] CAC: `opensc-tool --list-readers`, PIN prompt on a DoD site in native Firefox; note whether the flatpak browsers work
- [ ] `sudo bootc upgrade` pulls from GHCR without auth errors (package is public)
- [ ] Run the backup script from the new OS once; `restic snapshots` shows it
- [ ] Use it for a few days. Every fix goes into this repo (system) or the dotfiles repo (user) → rebuild / `chezmoi update`

Then the 4TB:

1. Last Workstation backup + `restic check`. Copy anything not in the backup
   list that you would miss (check `restic ls latest | less`).
2. Boot the **test drive** (not the Workstation). From there the 4TB is just
   another disk, so `install-atomic.sh`'s "running system" guard does not fire.
3. `sudo scripts/make-target-env.sh /dev/nvme0n1 > scripts/targets/4tb-primary.env`,
   set `SKIP_FINALIZE=0` and `TEST_INSTALL=0`, and **edit `PROTECTED_LUKS_UUIDS`**: remove the two
   4TB UUIDs, add the test drive's root LUKS UUID.
4. `sudo scripts/install-atomic.sh scripts/targets/4tb-primary.env` — this
   reformats the 4TB's btrfs root. The ESP, `/boot`, and the LUKS containers
   (same passphrases) are kept.
5. Reboot into the 4TB, Phase 3 + 4 again (the restore is the slow part).
6. Keep the test drive as a bootable spare until the 4TB has survived a week
   and one `bootc upgrade`.

The desktop follows the same runbook with `recipe-dsktp.yml` — planned only
after the laptop has proven the workflow for several months.

---

## Rollback and recovery

| Problem | Action |
| --- | --- |
| New deployment does not boot | GRUB menu → previous entry. Then `sudo bootc rollback` to make it permanent. |
| Whole disk unbootable | Boot the other disk (test drive ⇄ 4TB) via F12; reinstall the broken one with `install-atomic.sh` (5 min) and rerun `post-install-setup.sh`. |
| Image on GHCR broken | `sudo bootc switch --transport containers-storage localhost/fedora-cosmic-frmwrk:latest` with a known-good local build, or `bootc rollback`. |
| Lost `cosign.key` | Build/push unsigned, `bootc switch ghcr.io/…` (unsigned transport is the default). Regenerate keys, commit new `cosign.pub`, rebuild, rebase signed later. |
| Lost restic password file | The passphrase itself is enough: `restic -r <repo> restore …` prompts for it. |
| Forgot which UUIDs a disk was installed with | `/etc/fedora-cosmic-atomic/install-target.env` on that system. |
| LUKS prompt never appears | Boot with the previous entry; check `rd.luks.uuid` in `/proc/cmdline` and `/etc/crypttab`; `sudo rpm-ostree kargs --append-if-missing=rd.luks.uuid=<uuid>`. |
| Hibernate fails | `sudo enable-hibernation.sh --check`; Secure Boot must be off; `journalctl -b -1 -u systemd-hibernate`. |

---

## Anaconda alternative (if you ever prefer the ISO)

`Fedora-COSMIC-Atomic-ostree-x86_64-44-1.7.iso` (fedoraproject.org → Atomic
Desktops → COSMIC). Custom partitioning with the layout above, user `<user>`.
After first boot:

```bash
sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/samwick07/fedora-cosmic-frmwrk:latest && sudo systemctl reboot
sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest && sudo systemctl reboot   # optional, after a signed push
sudo enable-hibernation.sh          # adds resume=; Anaconda already wrote crypttab/fstab
sudo post-install-setup.sh
```

Anaconda installs GRUB with shim; Secure Boot still has to be off for hibernation.
