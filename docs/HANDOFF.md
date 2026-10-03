# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 15:15 EDT

## Where things stand
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
- **Spec confirmed** (2026-10-03) except O1 (drift report, spec section 7). F9: base
  image as close to stock as possible (layered: libvirt stack, Tailscale). Nightly build
  in GitHub Actions. Backups: rsync snapshots on the DAS + restic to Backblaze B2. VPNs:
  Cisco Secure Client and the Windscribe app in a rootful `vpn` distrobox; Windscribe
  also as NetworkManager WireGuard (COSMIC network menu); internal names over the VPN (N6).
- **One status file:** this one. `dotfiles/.migration-prep/HANDOFF.md` keeps only private
  facts and rules; the one-time migration checklist is `dotfiles/.migration-prep/MIGRATION.md`.
- **Project:** linked to this repo through GitHub; the dotfiles repo is to be linked too
  (it holds the private journal, lessons and migration checklist).

## Next (in order)
1. On the Workstation (MIGRATION.md part A, read-only): W2 Cisco facts, W3 how the
   internal names resolve (`logs/w3-cdn-local.log`). W1 (Docker volume export) any time
   before the laptop moves.
2. Keep/retire list for this repo (old installer, post-install restore steps, test
   scripts, Homebrew/Docker remnants) and for the dotfiles (Brewfile, run_once chain).
3. Rebuild the image layer per F9 (libvirt + Tailscale + config files + flatpak list);
   install on the 2TB (stock ISO + `bootc switch`), nothing restored; image-layer checks.
4. User layer on that bare image (dotfiles, boxes `dev`/`claude`/`rocm`/`vpn`); its checks.
5. Migration part B on the 2TB.

## Facts that are easy to forget
- Restic: `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`, password file
  `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
