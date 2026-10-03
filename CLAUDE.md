# fedora-cosmic-bluebuild — project context for Claude

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
- **Never write to the 4TB NVMe** (Fedora 44 Workstation) or the **DAS data disk**
  except reading the restic repo. Their LUKS UUIDs are `PROTECTED_LUKS_UUIDS` in
  `scripts/targets/site.env` (gitignored). With the stock installer (spec L1) nothing
  enforces them automatically: confirm the target disk before every install.
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

## Layout (as built by the old plan — the spec decides what stays)
| Layer | Where | What |
| --- | --- | --- |
| Image (system) | this repo: `recipes/`, `files/` | packages, `/usr/bin` scripts, `/etc` defaults; `VARIANT_ID=frmwrk` / `dsktp` |
| Install | `scripts/` (never in the image) | `prepare-disk.sh`, `make-target-env.sh`, `install-atomic.sh`, `reregister-win11vm.sh`, `scripts/test/` |
| Restore (old plan, under review) | `files/scripts/post-install-setup.sh` → `/usr/bin` | 7 steps: DAS, restic allowlist restore, hibernation, CAC, Win11VM, chezmoi, Tailscale |
| User | `github.com/samwick07/dotfiles` (chezmoi, private) | bash/ghostty/starship, Brewfile, `run_once_*` (brew, distrobox, Claude CLI, flatpak overrides, CAC, Syncthing) |
| Data | restic on the DAS (`frmwrk-restic-repo`) + Syncthing | allowlist: `files/etc/fedora-cosmic-atomic/restore-allowlist.txt` |

App lanes: GUI → flatpak · CLI → Homebrew (`~/.Brewfile`) · toolchains/IDEs →
distrobox (`dev` Fedora: VS Code, Antigravity, Chrome RPM; `claude` Ubuntu 24.04:
Claude Desktop .deb + Claude Code CLI; `rocm`). Bottles for Windows apps.

Docs: `docs/migration-guide.md` (runbook, Phases 0–5), `docs/clean-room.md`,
`docs/known-issues.md`, `docs/local-build.md`, `docs/operations.md`,
`docs/disaster-recovery.md`, `docs/hibernation-setup.md`, `docs/bootloader.md`.
Machine state for the journal or an issue: `cosmic-report` (`--public` scrubs).
Evidence for the spec: `scripts/inventory-workstation.sh` (read-only, private output).

## Working style
- The user is often on a machine without their keys: give exact commands to paste,
  ask for the terminal output, diagnose from it.
- Changes go through pull requests (the Claude GitHub App has push access): small
  commits on a branch, `scripts/check-leaks.sh` clean, PR; the user reviews and merges.
  Patch files are a fallback only (downloads from the chat did not reach the laptop).
- Commit messages: imperative, say why. Keep `docs/HANDOFF.md` current.
