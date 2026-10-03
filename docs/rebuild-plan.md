# Rebuild plan: keep / change / retire

What happens to every file in this repo and in the dotfiles repo under the confirmed spec
(`docs/end-state.md`). "Retire" means deleted in a PR; git history and the branch
`held/first-run-fixes` keep the old code. Work follows the layers: image first, then
user layer; nothing here is migration (that is `dotfiles/.migration-prep/MIGRATION.md`).

## Image repo (`fedora-cosmic-bluebuild`)

### Recipes and image files

| Path | Verdict | Why / what changes |
| --- | --- | --- |
| `recipes/common-modules.yml` | **change** | Packages per F9: libvirt/QEMU/swtpm/edk2 (V1), Tailscale (N3), NetworkManager-openconnect (N4 trial). Out: Ghostty/starship/topgrade COPRs, chezmoi, age, git, tmux, restic, Syncthing, distrobox, gdisk, smartmontools, lm_sensors, nss-tools, openssl, NetworkManager-openvpn, openvpn, openconnect CLI, policycoreutils-python-utils. Flatpak list per spec 3.5 (Collabora Office, Signal, VLC, Inkscape, GIMP, darktable, Calibre, Remmina, Bottles, Flatseal, virt-manager trial). |
| `recipes/recipe-frmwrk.yml` | **change** | Drop iio-sensor-proxy; fprintd/fprintd-pam only if the base lacks them (check on the stock install); keep hibernation, kargs, signing. |
| `recipes/recipe-dsktp.yml` | keep | Out of scope until the laptop has run 3–6 months; aligned with F9 then. |
| `files/scripts/configure-hibernation.sh`, `enable-hibernation.sh` | keep | F2/P2. `checkpolicy` becomes build-time only (compile the SELinux module, then remove it). |
| `files/scripts/cosmic-session-wait.sh` (+ recipe snippet) | keep | D1, until upstream fixes cosmic-comp#2690. |
| `files/scripts/win11-cac.sh` | keep | V2. |
| `files/scripts/cosmic-report.sh` | keep | Diagnostics; take `--offline` from `held/first-run-fixes`. |
| `files/scripts/fix-signing-registry.sh` | keep | Needed while local BlueBuild builds sign for `localhost/`. |
| `files/systemd/bootc-fetch-apply-updates.service.d/10-stage-only.conf` | keep | L2 backstop. |
| flatpak retry drop-ins (`held/first-run-fixes`) | **add** | N1. |
| i2c udev rule + `i2c-dev` modules-load | **add** | P11 (config files only; `ddcutil` lives in `dev`). |
| TPM2 dracut config | **add** | P9 (the initramfs can unlock LUKS with TPM2 + PIN). |
| `files/scripts/enable-vfio.sh`, `configure-amd-gpu-desktop.sh` | keep | dsktp only. |
| `files/scripts/configure-amd-gpu-framework.sh`, `files/etc/environment.d/50-amd-common.conf`, `files/etc/profile.d/amd-common.sh` | **retire** | ROCm variables belong to the `rocm` box (E3), not the host session. |
| `files/scripts/setup-cac.sh` | **retire** | Host CAC = base `pcscd` only; opensc and the NSS db move to `dev` (V3), set up by the user layer with a timeout. |
| `files/scripts/install-atomic.sh`, `install-to-disk.sh`, `make-target-env.sh`, `prepare-disk.sh` (+ the `scripts/` symlinks) | **retire** | L1: stock ISO + `bootc switch`. |
| `files/scripts/post-install-setup.sh` | **retire** | Bring-up = image + user layer; one-time steps = MIGRATION.md. |
| `files/scripts/migrate-docker-to-podman.sh` | **retire** | One-time (MIGRATION W1/M6). |
| `files/etc/fedora-cosmic-atomic/restore-allowlist.txt` | **retire** | No restore in the bring-up path. |
| `files/distrobox/distrobox.ini` | **move to dotfiles** | Boxes are user layer (F9): `dev`, `claude`, `rocm`, `vpn` (rootful). |
| `files/README.md` | **change** | Describe what is left. |

### Scripts, CI, docs

| Path | Verdict | Why / what changes |
| --- | --- | --- |
| `.github/workflows/build.yml`, `scripts/ci-should-build.sh` | keep | F4 nightly build. |
| `scripts/smoke-test.sh` | **change** | Check what the image now ships; drop the retired scripts. |
| `scripts/check-leaks.sh` | keep | Public repo rule; drop the retired paths from its image scan. |
| `scripts/targets/site.example.env` | **change** | Keep only what `check-leaks.sh` uses (user, UUIDs to never publish). |
| `scripts/inventory-workstation.sh` | keep | Evidence for dsktp later. |
| `scripts/reregister-win11vm.sh`, `scripts/test/syncthing-test-device.sh` | **retire** | Migration-only (M7, M3). |
| `backup/frmwrk_backup_command.sh`, `backup/frmwrk-restic-excludes` | **retire after S2 runs** | The Workstation still uses them; S2 (dotfiles) replaces them. |
| `docs/migration-guide.md`, `docs/clean-room.md` | **retire** | Replaced by the spec, `docs/install.md` (new) and MIGRATION.md. |
| `docs/install.md` | **add** | L1 step by step: stock ISO, partitioning for F2, `bootc switch` twice, Secure Boot off, karg check. |
| `docs/disaster-recovery.md` | **change** | Reinstall = `docs/install.md` + user layer + restore from S2 (rsync snapshot or B2). |
| `docs/operations.md` | **change** | The daily routine (D5/L2/S2). |
| `docs/hibernation-setup.md`, `docs/bootloader.md`, `docs/local-build.md`, `docs/known-issues.md` | keep, update | Install path, CI-first builds, prune old-plan entries. |
| `CLAUDE.md`, `README.md` | **change** | Layout table and lanes per the spec. |

## Dotfiles repo (`dotfiles`, private)

| Path | Verdict | Why / what changes |
| --- | --- | --- |
| `dot_Brewfile`, `run_once_before_10-homebrew.sh.tmpl`, `dot_config/environment.d/10-brew.conf` | **retire** | C3: no Homebrew. |
| `.chezmoiexternal.toml` | **add** | C1/C2: single binaries into `~/.local/bin` (chezmoi, starship, topgrade, gh, btop, fastfetch, restic, syncthing, distrobox, uv, lazydocker, cosign). |
| `run_once_20-distrobox.sh.tmpl` + `distrobox.ini` (moved here) | **change** | Boxes `dev` (Chrome, VS Code, Antigravity, Ghostty, toolchain, AI CLIs, nmap, 7zip, ddcutil, opensc), `claude` (Claude Desktop + Claude Code CLI, exported), `rocm` (ROCm env vars), `vpn` (rootful, systemd; Cisco Secure Client, Windscribe app). Runs as the user, no sudo except the rootful box. |
| `run_once_25-claude-cli.sh.tmpl` | **retire** | Folded into the `claude` box definition. |
| `run_once_30-flatpak-overrides.sh.tmpl` | **change** | Only what the confirmed flatpaks need (Bottles). |
| `run_once_40-cac.sh.tmpl` | **change** | CAC setup inside `dev` (NSS db, opensc), bounded by a timeout. |
| `run_once_50-syncthing.sh.tmpl` | **change** | Syncthing from `~/.local/bin`, user unit; test-install identity rules stay. |
| `run_onchange_60-user-dirs.sh.tmpl` | keep | — |
| `dot_config/ghostty/`, `starship.toml`, `dot_bashrc.tmpl`, `dot_bash_profile`, `dot_gitconfig.tmpl` | keep | — |
| `dot_config/topgrade.toml.tmpl` | **change** | The daily routine: backup first (S2c), then `bootc upgrade`, flatpaks, boxes; no brew. |
| backup scripts + user timer | **add** | S2a–S2d. |
| `dot_config/systemd/user/hermes-gateway.service` | keep | E5. |
| `dot_local/bin/hibernate-check`, `iommu.sh`, `pikvm.sh` | keep | Per machine via `.chezmoiignore`. |
| `.migration-prep/c-history-rewrite.sh` | **retire** | One-off from 2026-10-01, done. |

## Order of work

1. Image PR: recipes + files per the table, smoke test updated; nightly CI builds it.
2. Docs PR: `docs/install.md`, retire the old guides, update CLAUDE.md/README.
3. Dotfiles PR: externals, boxes, topgrade routine, backups, retire Homebrew.
4. Test on the 2TB: install (L1) → image checks → user layer → its checks → MIGRATION.md part B.
