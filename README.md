# fedora-cosmic-bluebuild — declarative Fedora Cosmic Atomic for two AMD machines

One BlueBuild repository, two images, built **locally** and pushed to GHCR:

| Image | Machine | Recipe |
| --- | --- | --- |
| `ghcr.io/samwick07/fedora-cosmic-framework:latest` | Framework 13 AMD (Ryzen 7040U, 780M) — laptop, hibernation, fingerprint | `recipes/recipe-framework.yml` |
| `ghcr.io/samwick07/fedora-cosmic-desktop:latest` | ROG STRIX X870-I, Ryzen 9 9950X, RX 9070 XT — VFIO passthrough of a 2TB NVMe to a Win11 VM | `recipes/recipe-desktop.yml` |

Base: `quay.io/fedora-ostree-desktops/cosmic-atomic:44`. Bootloader: GRUB
(`docs/bootloader.md`). Shared content: `recipes/common-modules.yml`.

## If the laptop is dead: the 6-line version

```bash
git clone git@github.com:samwick07/fedora-cosmic-bluebuild.git ~/migration-prep/fedora-cosmic-bluebuild && cd $_
bluebuild build recipes/recipe-framework.yml                                    # docs/local-build.md
sudo scripts/make-target-env.sh /dev/<disk> > scripts/targets/<disk>.env && $EDITOR scripts/targets/<disk>.env
sudo scripts/install-atomic.sh scripts/targets/<disk>.env                       # reboot into it
sudo post-install-setup.sh                                                      # restores ~ and everything else from the DAS
post-install-setup.sh --check
```

Everything needed is in this repo (system), `github.com/samwick07/dotfiles`
(user config, via chezmoi), the DAS (restic repo `frmwrk-restic-repo`, LUKS
UUID `xxxxxxxx-…`), and two secrets you must hold outside all of them: the
restic passphrase and `cosign.key`. Full runbook: **`docs/migration-guide.md`**;
the model behind it: **`docs/clean-room.md`**.

## Repository map

```
recipes/
  common-modules.yml        packages, services, flatpaks, scripts shipped to /usr/bin — shared
  recipe-framework.yml      + fprintd/iio-sensor-proxy, ROCm env, hibernation drop-ins + SELinux
  recipe-desktop.yml        + IOMMU kargs, ROCm env, enable-vfio.sh
files/
  etc/                      static config -> /etc, incl. fedora-cosmic-atomic/restore-allowlist.txt
  scripts/                  build-time scripts (configure-*.sh) and host scripts (-> /usr/bin)
  distrobox/distrobox.ini   `distrobox assemble` manifest: dev, claude, rocm (-> /usr/share/distrobox)
scripts/
  make-target-env.sh        read a disk's UUIDs into scripts/targets/<name>.env
  install-atomic.sh         bootc install to-filesystem onto a pre-made LUKS layout (UUID-driven, guarded)
  targets/example.env       template; real targets are gitignored
  reregister-win11vm.sh     recreate the Win11VM domain if its XML is ever lost
backup/
  frmwrk_backup_command.sh  restic backup (source of truth for the copy on the DAS)
  frmwrk-restic-excludes    anchored exclude list
  restic-backup-sudoers     /etc/sudoers.d/restic-backup
docs/
  clean-room.md             the four layers, software lanes, restore allowlist, Syncthing rules
  migration-guide.md        install → first boot → restore → validate → 4TB → rollback
  local-build.md            build, smoke-test, sign, push, switch, version bump
  hibernation-setup.md      what must be true for suspend-then-hibernate, and how to check
  bootloader.md             GRUB; why systemd-boot was dropped and how to try it later
.github/workflows/build.yml manual fallback only (workflow_dispatch) — no scheduled or PR builds
cosign.pub                  image verification key (private key: cosign.key, gitignored)
```

## Host scripts shipped in the image

| Path on the installed system | Purpose |
| --- | --- |
| `/usr/bin/post-install-setup.sh` | Root half of a rebuild: DAS, allowlist restore, hibernation check, CAC system trust, VMs, then `chezmoi init --apply`, Tailscale. `--list`, `--check`, `--step N`. |
| `/usr/bin/setup-cac.sh` | DoD PKI + OpenSC for pcscd, system trust, NSS/browser profiles. `--system` (root), `--user` (chezmoi), `--check`. |
| `/usr/share/distrobox/distrobox.ini` | `distrobox assemble create --file …` — `dev` (Fedora, VS Code/Antigravity exported), `claude` (Ubuntu), `rocm`. |
| `/usr/bin/enable-hibernation.sh` | Verify/repair resume karg, LUKS karg, swap, SELinux module. `--check`. |
| `/usr/bin/enable-vfio.sh` | Desktop: bind one NVMe controller to vfio-pci **by PCI address** (both T700s share an ID). |
| `/usr/bin/migrate-docker-to-podman.sh` | One-time: Open WebUI / SearXNG volumes and compose stack from Docker to rootless podman. |

## Four layers (clean-room)

1. **OS image** — this repo. Edit → `bluebuild build` → smoke test → push → `sudo bootc upgrade`.
2. **User layer** — `samwick07/dotfiles` (chezmoi): shell, ghostty, git, `~/.Brewfile`, and the `run_once` scripts that assemble containers, set flatpak permissions, wire CAC and Syncthing. Branches on the image's `VARIANT_ID`.
3. **Live data** — Syncthing between laptop and desktop (rules in `docs/clean-room.md`).
4. **Archive** — restic on the DAS, one repo per machine. Restored by allowlist on a rebuild, by hand afterwards.

## Daily operations

| Task | Command |
| --- | --- |
| Update | `sudo bootc upgrade && systemctl reboot` |
| Roll back | `sudo bootc rollback && systemctl reboot` (or pick the previous GRUB entry) |
| Add a GUI app | `default-flatpaks` list in `recipes/common-modules.yml` → build → push (or just `flatpak install` and add it later) |
| Add a CLI tool | `~/.Brewfile` in dotfiles → `brew bundle --global` |
| Add a toolchain / IDE | `files/distrobox/distrobox.ini` → build → push → `distrobox assemble create --file /usr/share/distrobox/distrobox.ini --name dev --replace` |
| Add something that needs the kernel/systemd | `recipes/common-modules.yml` (or one recipe) → build → push |
| Change a dotfile | `chezmoi edit …` → `chezmoi apply` → commit/push; `chezmoi update` on the other machine |
| Fedora 44 → 45 | `image-version: 45` in both recipes → build → test on the test drive → push (`docs/local-build.md`) |
| Backup | `/run/media/<user>/DAS/frmwrk_backup_command.sh` |
| Health | `post-install-setup.sh --check`, `setup-cac.sh --check`, `sudo enable-hibernation.sh --check` |

## Design decisions

- **GRUB, not systemd-boot** — the two systemd-boot approaches tried earlier both yield an unbootable disk with a separate ext4 `/boot`; see `docs/bootloader.md`.
- **bootc install to-filesystem onto pre-made LUKS**, not Anaconda — reproducible, 5 minutes, keeps the LUKS containers and their passphrases; the Anaconda ISO remains a documented alternative.
- **Nothing under `/usr/local`, `/opt`, `/home`** in the image — those are `/var` on ostree and are not updated after the first install.
- **Modular libvirt** (`virtqemud.socket` &c.), not `libvirtd.service` — they conflict.
- **Clean-room, not port-over** — data is restored by allowlist; config is declared in chezmoi; apps are re-chosen per lane (flatpak / Homebrew / distrobox / image). See `docs/clean-room.md`.
- **Desktop deferred** — `recipe-desktop.yml` builds, but the desktop migrates only after the laptop workflow has held up for months.
- **Local builds** — GitHub Actions is `workflow_dispatch` only.
- **VFIO by PCI address** — `vfio-pci.ids=` would capture the boot NVMe on the desktop.

## Secrets (never in git, never only on the laptop)

`cosign.key` (unencrypted — see `docs/local-build.md`), the restic passphrase /
`~/.restic/frmwrk-repo.pass`, the LUKS passphrases, and if BitLocker is on in
the VM, its recovery key.
