# Operations: daily tasks, shipped tools, design decisions

## Daily tasks

| Task | How |
| --- | --- |
| Update | OS: staged automatically (`bootc-fetch-apply-updates.timer`, stage-only — never reboots) and by `topgrade`; it applies at the next reboot **you** choose. Apps/boxes/brew: `topgrade` when nothing long is running. `bootc status` shows what is staged. |
| Roll back | `sudo bootc rollback && systemctl reboot`, or pick the previous GRUB entry |
| Add a GUI app | `default-flatpaks` in `recipes/common-modules.yml` (or `flatpak install` now, declare later) |
| Add a CLI tool | `~/.Brewfile` in the dotfiles → `brew bundle --global` |
| Add a toolchain / IDE | `files/distrobox/distrobox.ini` → image → `distrobox assemble create --file /usr/share/distrobox/distrobox.ini --name dev --replace` |
| Add something that needs the kernel/systemd | `recipes/common-modules.yml` (or one recipe) → push → CI builds |
| Change a dotfile | `chezmoi edit …` → `chezmoi apply` → commit/push; `chezmoi update` on the other machine |
| Fedora 44 → 45 | `image-version: 45` in both recipes → test on the test drive → push (`local-build.md`) |
| Backup | `/run/media/$USER/DAS/frmwrk_backup_command.sh` (asks for sudo once) |
| Health | `post-install-setup.sh --check`, `setup-cac.sh --check`, `sudo enable-hibernation.sh --check` |
| Something broke | `cosmic-report "<what you were doing>"`; a bug → GitHub issue with `cosmic-report --public` (`known-issues.md`) |
| New / dead drive | `install-to-disk.sh` (`disaster-recovery.md`) |

## Tools shipped in the image

| Path | Purpose |
| --- | --- |
| `/usr/bin/post-install-setup.sh` | Root half of a rebuild: DAS, allowlist restore, hibernation, CAC trust, VM, `chezmoi init --apply`, Tailscale. `--list`, `--check`, `--step N`. |
| `/usr/bin/install-to-disk.sh` | Check a disk, then prepare + install (`disaster-recovery.md`). Building blocks: `prepare-disk.sh`, `make-target-env.sh`, `install-atomic.sh`. All read `/etc/fedora-cosmic-atomic/site.env`. |
| `/usr/bin/setup-cac.sh` | DoD PKI (downloaded, verified against pinned roots) + OpenSC: pcscd, system trust, NSS/browser profiles. `--system`, `--user`, `--check`, `--fetch`, `--refresh`. |
| `/usr/bin/win11-cac` | Hand the USB CAC reader to the Windows VM and back (`attach` / `detach` / `status`). |
| `/usr/bin/enable-hibernation.sh` | Verify/repair resume + LUKS kargs, swap, SELinux module. `--check`. |
| `/usr/bin/enable-vfio.sh` | Desktop: bind one NVMe controller to vfio-pci by PCI address. |
| `/usr/bin/cosmic-report` | State snapshot for the journal or an issue; `--public` redacts user/host/UUIDs/tailnet. |
| `/usr/bin/cosmic-session-wait` | Session start (`cosmic.desktop` Exec): waits up to 10 s for the greeter to release the GPU, then `start-cosmic`. Workaround for the login black screen (`known-issues.md`). `journalctl -t cosmic-session-wait` shows each wait. |
| `/usr/bin/migrate-docker-to-podman.sh` | One-time: Open WebUI / SearXNG from Docker to rootless podman. |
| `/usr/share/distrobox/distrobox.ini` | `distrobox assemble` manifest: `dev` (Fedora; VS Code/Antigravity exported), `claude` (Ubuntu), `rocm`. |

## Design decisions

- **GRUB, not systemd-boot** — both systemd-boot attempts gave an unbootable disk with a separate ext4 `/boot` (`bootloader.md`).
- **`bootc install to-filesystem` onto a prepared LUKS layout**, not Anaconda — reproducible, minutes, keeps containers and passphrases; Anaconda stays documented in `migration-guide.md`.
- **Nothing under `/usr/local`, `/opt`, `/home` in the image** — those live in `/var` and are not updated after the first install.
- **Modular libvirt** (`virtqemud.socket` &c.), not `libvirtd.service` — they conflict.
- **Clean-room, not port-over** — data restored by allowlist, config declared in chezmoi, apps re-chosen per lane (`clean-room.md`).
- **Personal values only in `site.env`** (gitignored) — the repo and the image are public; `scripts/check-leaks.sh` guards it.
- **CI builds nightly only when something changed**; the smoke test gates every push; local builds use the same scripts (`local-build.md`).
- **Desktop deferred** — `recipe-dsktp.yml` builds; the desktop migrates after the laptop has held up for months.
- **VFIO by PCI address** — `vfio-pci.ids=` would also capture the desktop's boot NVMe (same model).
