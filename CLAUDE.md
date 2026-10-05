# fedora-cosmic-bluebuild — project context for Claude

Machine names are the key everywhere (spec F7): `frmwrk`/`dsktp` = hostname = recipe =
image `fedora-cosmic-<name>` = `VARIANT_ID` = the dotfiles' `.machine`.

Migrating the Framework 13 AMD laptop **frmwrk** (login `$SITE_USER`, uid 1000) from
Fedora 44 Workstation to **Fedora 44 COSMIC Atomic**, built here with BlueBuild and
installed with bootc. Clean-room approach: keep the data, re-declare everything else.
The desktop **dsktp** follows only after the laptop has proven itself for 3–6 months.

**Start every session by reading `docs/HANDOFF.md`** (live status, exact next step) and
**`docs/end-state.md`** (the spec). Keep HANDOFF short and current; the narrative of what
happened goes to the private journal (`dotfiles/.migration-prep/JOURNAL.md`), bugs to
GitHub issues, caveats to `docs/known-issues.md`.

**The spec governs.** Since 2026-10-03 the project is being refactored: decide the end
state in `docs/end-state.md` first, then build it layer by layer (image, then user
layer, then a one-time migration checklist), each tested alone. Nothing is added to
`recipes/`, `files/` or the dotfiles repo without a row in the spec. Existing code that
the spec does not ask for is to be retired, not repaired. Fixed: COSMIC (F1) and
hibernation (F2) are hard requirements.

## Ground rules (non-negotiable)
- **Never write to the 4TB NVMe** (Fedora 44 Workstation). **The DAS** is an ordinary disk
  with other data on it: this project writes only `DAS/migration/` (W1, W4) and
  `DAS/frmwrk-snapshots/` (the nightly job, from M11). The old restic repo on it is a stale
  backup: never written, deleted only after the migration is complete and the new backups
  have proven themselves (spec F8, MIGRATION part C). LUKS UUIDs are `PROTECTED_LUKS_UUIDS` in
  `scripts/targets/site.env` (gitignored). With the stock installer (spec L1) nothing
  enforces them automatically: confirm the target disk (model, serial) before every install.
- Only the **2TB test drive** is installed to until the user says the test passed.
- The user runs installs, disk operations and anything needing a password
  or a physical action. Claude prepares and verifies.
- This repo and the GHCR image (`ghcr.io/samwick07/fedora-cosmic-frmwrk`) are
  **public**: nothing identifying anywhere in git — no user name, home paths,
  disk UUIDs, tailnet name, keys. Personal values live only in `site.env`; docs
  write `$SITE_USER` and `/home/$SITE_USER`. `scripts/check-leaks.sh` must pass
  before every push (it fails on `/home/<name>`, `/run/media/<name>`, any UUID).
- The image is built **nightly in GitHub Actions** (free for this public repo); local
  builds (`bluebuild build -B podman …`, `docs/local-build.md`) test a change before it is
  pushed. Keep the base image as close to stock as possible (spec F9).
- During the test, the 2TB system has its **own** Syncthing device ID and Tailscale
  node — never the real frmwrk identities.

## Layout
| Layer | Where | What |
| --- | --- | --- |
| Spec | `docs/end-state.md` | every requirement, its lane, its check; section 6 = acceptance |
| Image (system) | this repo: `recipes/`, `files/` | stock COSMIC Atomic + the F9 set (virtualization stack, Tailscale, restic, distrobox, CAC), Homebrew (module), nightly job J1, first-boot services, the rootful `net` box, `cosmic-acceptance`, `cosmic-enroll`; `VARIANT_ID=frmwrk` / `dsktp` |
| Install | `install/frmwrk.ks` + `docs/install.md` | stock ISO + kickstart (partitioning, image); first boot finishes alone (L1) |
| User | `github.com/samwick07/dotfiles` (chezmoi, private; one repo for both machines) | Brewfile (CLI; `~/.config/homebrew/Brewfile`), `distrobox.ini` (rootless dev, claude, rocm), shell, CAC for Chrome, Syncthing unit; per-machine values in `.chezmoidata/machines.yaml` |
| Migration (one-time) | dotfiles `.migration-prep/<machine>/` (private): `MIGRATION.md`, `migrate.sh`, `site.env` | frmwrk: W1–W6 on the Workstation, M1–M12 on the laptop |
| Backup / restore | J1 in the image; `docs/restore.md` | daily home snapshot, DAS rsync snapshots, restic to B2; `$HOME`, `/etc`, `/var` state, VM disks, manifest (R1); weekly warm spare (L4) |

App lanes: GUI → flatpak · CLI → Homebrew (`~/.config/homebrew/Brewfile`) · toolchains, IDEs, Chrome (CAC),
Ghostty → distrobox `dev` (Fedora) · Claude Desktop + Claude Code → `claude` (Ubuntu 24.04) ·
ROCm → `rocm` · VPN vendor clients and root network tools → rootful `net` (image-managed) ·
Windows apps → Bottles or the Win11 VM. No manual configuration: anything a person must do
is either physical (finger, PIN, firmware setting) or a secret typed once.

Docs: `docs/install.md`, `docs/restore.md`, `docs/disaster-recovery.md`, `docs/operations.md`,
`docs/local-build.md`, `docs/known-issues.md`, `docs/hibernation-setup.md`, `docs/bootloader.md`,
`docs/rebuild-plan.md` (the 2026-10-03 refactor, executed).
Machine state for the journal or an issue: `cosmic-report` (`--public` scrubs).
Acceptance on a machine: `sudo cosmic-acceptance [--user]`.
Evidence for the spec: `scripts/inventory-workstation.sh` (read-only, private output).

## Working style
- The user is often on a machine without their keys: give exact commands to paste,
  ask for the terminal output, diagnose from it.
- Changes go through pull requests (the Claude GitHub App has push access): small
  commits on a branch, `scripts/check-leaks.sh` clean, PR; the user reviews and merges.
  Patch files are a fallback only (downloads from the chat did not reach the laptop).
- Commit messages: imperative, say why. Keep `docs/HANDOFF.md` current.
