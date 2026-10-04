# Operations: the daily routine, shipped tools, design decisions

## Daily

| Task | How |
| --- | --- |
| See what happened overnight | The notification at login, or `nightly` (alias: the job's report and log). Failures are listed first; the restore point line says how old the newest backup is |
| Apply an update | The nightly job only **stages** the image (`bootc status` shows it). Reboot when nothing long is running; nothing reboots on its own |
| Update now | `up` (topgrade: staged image, flatpaks, Homebrew, boxes) |
| Roll back | Previous or pinned entry in GRUB, or `sudo bootc rollback && systemctl reboot` |
| Get a file back | `docs/restore.md` (daily snapshots, DAS, B2) |
| Something broke | `cosmic-report "<what you were doing>"`; a bug → GitHub issue with `cosmic-report --public` (`known-issues.md`) |

## Changing the system

Every change starts as a row in `docs/end-state.md`; then:

| To add | Where |
| --- | --- |
| A GUI app | `default-flatpaks` in `recipes/common-modules.yml` **and** `files/share/flatpaks.list` (the smoke test compares them) |
| A CLI tool | `~/.Brewfile` in the dotfiles → `chezmoi apply` (installs it) |
| A toolchain, IDE or distro package | `~/.config/distrobox/distrobox.ini` in the dotfiles → `chezmoi apply`; rebuild a box: `distrobox assemble create --file ~/.config/distrobox/distrobox.ini --name dev --replace` |
| Something that needs the kernel, a host service, or root at night | `recipes/` → pull request → CI builds and smoke-tests it → merge → the nightly build publishes it |
| A dotfile | `chezmoi edit …` → `chezmoi apply` → commit, push; `chezmoi update` on the other machine |
| Fedora 44 → 45 | `docs/local-build.md` |

Anything changed by hand outside these shows up in the next drift report.

## Tools shipped in the image

| Path | Purpose |
| --- | --- |
| `/usr/bin/cosmic-nightly` | The one scheduled job (04:30 + hourly catch-up): manifest, the daily home snapshot, backups to the DAS and B2, drift report, staged upgrades (image, flatpaks, Homebrew, boxes), report. Never reboots. `--dry-run`, `--catch-up` |
| `/usr/bin/cosmic-nightly-notify` | Shows the report once at login |
| `/usr/bin/cosmic-acceptance` | Spec section 6 with nothing ticked by hand: live state + evidence from use (PASS / FAIL / WAIT / YOU); `--exercise` runs the active trials once (it suspends and hibernates); the nightly job runs it daily (`--record`) and it pins known-good deployments (L3) |
| `cosmic-evidence-sleep` (service), `cosmic-evidence-tunnel@` (udev) | Recorders for acceptance: battery and Bluetooth around every sleep; routes and DNS whenever a VPN tunnel comes up. Journal only (`journalctl -t cosmic-evidence`) |
| `/usr/bin/cosmic-enroll` | Fingerprint, then TPM2 + PIN on every LUKS device (`--check` to look) |
| `cosmic-signed-origin`, `cosmic-hibernation`, `cosmic-net-box` (services) | First boot finishes alone: signature-verified updates, hibernation kargs, the rootful `net` box (VPN clients from `/var/lib/net-box/installers/`: Cisco's `.sh` or `.deb`, Windscribe fetched by itself, nmap/mtr/tcpdump wrappers in `/usr/local/bin`) |
| `/usr/bin/cac-status` | CAC on the host: pcscd, OpenSC, DoD roots, readers |
| `/usr/bin/win11-cac` | The default way to hand the CAC reader to the Win11 VM and back (`attach` / `detach` / `status`); SPICE redirection in the VM window is the fallback |
| `/usr/bin/enable-hibernation.sh` | Check/repair resume and LUKS kargs, swap, SELinux module. `--check` |
| `/usr/bin/cosmic-report` | State snapshot for the journal or an issue; `--public` redacts |
| `/usr/bin/cosmic-session-wait` | Session start: waits for the greeter to release the GPU (`known-issues.md`) |
| `/usr/bin/enable-vfio.sh` | Desktop only: bind one NVMe controller to vfio-pci |

## Design decisions

The spec (`docs/end-state.md`) records every decision with its reason; the ones people ask about:

- **Custom image, stock base** (F4, F9): CI catches failures before the laptop does; only what needs the host is layered.
- **Homebrew for CLI, distrobox for toolchains and GUI dev apps, flatpak for GUI apps** — Universal Blue's lanes.
- **The whole virtualization stack layered** (V1, A14): SPICE USB redirection of the CAC reader must work as the fallback to `win11-cac`.
- **One nightly job, never a reboot** (J1, L2): long sessions are never interrupted.
- **Two different backups** (F8): plain files on the DAS, encrypted restic on B2; a restore point within a day (R1).
- **GRUB, not systemd-boot** (`bootloader.md`); **modular libvirt sockets**, not `libvirtd.service`.
- **Personal values only in `site.env`** (gitignored): the repo and image are public; `scripts/check-leaks.sh` guards it.
