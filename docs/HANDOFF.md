# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 (late evening)

## Where things stand
- **Image and user layer merged** (PR #7, dotfiles PR #2; CI build + smoke test green).
  Nothing has run on hardware since the refactor. A review of the design against Universal
  Blue, BlueBuild and bootc practice (with proposed spec changes) is in the Project, not here.
- **Refactor in progress.** The first test install (2TB, 2026-10-02/03) showed that the
  end state had been copied from the Workstation and installed by one imperative script.
  New approach: write the spec (`docs/end-state.md`), then build image → user layer →
  migration checklist, each tested alone.
- **Fixed:** COSMIC (F1) and hibernation (F2) are hard requirements; install path (L1) is
  the stock COSMIC Atomic ISO, then `bootc switch` to the signed image.
- **Laptop:** back on the 4TB Workstation (daily driver, untouched). The 2TB is in the USB
  enclosure, untouched: it is a record of the first run and will be reinstalled.
- **Workflow:** the Claude GitHub App now has push access; changes arrive as pull requests.
  Project description and instructions rewritten for the spec-first approach.
- **`modutil` hang (first run):** no journal entries (pcscd logs nothing at its default
  level; `setup-cac` ran from a terminal). Not diagnosable from logs; the held timeout fix
  covers it; reproduce on the next install.
- **Evidence so far:** fingerprint `sudo` is in daily use on the Workstation → P6 keep.
- **Held fixes** from the first run are on branch `held/first-run-fixes` (scrubbed,
  not for merge as-is). Take what the spec asks for (the flatpak retry drop-ins → N1).
- **Spec confirmed** (2026-10-03). Custom image kept (F4, revisit condition recorded). F9: base image as close to
  stock as possible (layered: libvirt stack, Tailscale, and NetworkManager-openconnect for
  the VPN trial). Nightly build in GitHub Actions. Backups: rsync snapshots on the DAS +
  restic to Backblaze B2.
- **VPN trial** (N4/N5): NetworkManager-openconnect (COSMIC network menu), Cisco Secure
  Client in the rootful `vpn` box, Windscribe as native NetworkManager WireGuard and as its
  app in `vpn`. Try each on the 2TB, keep what works; the rest is removed. N6 (`.local`
  name over the VPN) postponed: the name moves to a real domain.
- **Nightly job J1:** backup → drift report → staged upgrades → report; never reboots.
- **CAC is a must** in the Win11 VM (V2), Chrome in `dev` and base Firefox (V3); DoD roots
  baked into the image at build time (V4).
- **Rebuild plan:** `docs/rebuild-plan.md` lists keep/change/retire for every file in both
  repos.
- **One status file:** this one. `dotfiles/.migration-prep/HANDOFF.md` keeps only private
  facts and rules; the one-time migration checklist is `dotfiles/.migration-prep/MIGRATION.md`.
- **Project:** linked to this repo through GitHub; the dotfiles repo is to be linked too
  (it holds the private journal, lessons and migration checklist).

## Next (in order)
1. Decide the pre-install proposals from the review (each needs a spec row first):
   acceptance checklist (spec section 6, still empty) and a host-side check script; the DAS
   write rule (CLAUDE.md says read-only, but W1/W4 and J1's snapshots write to it);
   signature enforcement after `bootc switch` (L1); btrfs layout check at install.
2. Docs PR: `docs/install.md` (L1), retire `migration-guide.md` and `clean-room.md`,
   rewrite `disaster-recovery.md`, update CLAUDE.md layout table and README; spec C1: gh,
   btop, fastfetch moved from externals into the `dev` box.
3. Confirm the first nightly CI run publishes and signs the F9 image.
4. Workstation, read-only, before the laptop moves: MIGRATION W1 (Docker volumes), W2
   (Cisco facts).
5. 2TB: install (stock ISO + `bootc switch`) → image checks (incl. `cac-status`, the
   nightly job with `--dry-run`) → `chezmoi init --apply` → user-layer checks (VPN trial,
   CAC in Chrome, Firefox and the VM) → MIGRATION part B.

## Facts that are easy to forget
- Restic: `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`, password file
  `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
