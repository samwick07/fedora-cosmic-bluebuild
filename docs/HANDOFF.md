# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 13:15 EDT

## Where things stand
- **Refactor in progress.** The first test install (2TB, 2026-10-02/03) showed that the
  end state had been copied from the Workstation and installed by one imperative script.
  New approach: write the spec (`docs/end-state.md`), then build image → user layer →
  migration checklist, each tested alone.
- **Fixed:** COSMIC (F1) and hibernation (F2) are hard requirements.
- **Laptop:** back on the 4TB Workstation (daily driver, untouched). The 2TB is in the USB
  enclosure, untouched: it is a record of the first run and will be reinstalled.
- **Held, not pushed:** the 7 commits from the first run's debugging (step 5/6 fixes,
  `modutil` timeout, `cosmic-report --offline`, flatpak retry drop-ins, docs) live in the
  claude.ai Project as `followup-2026-10-03.patch`. Take what the spec still needs from it
  (the flatpak retry drop-ins satisfy N1); do not apply it wholesale.

## Next (in order)
1. On the Workstation: `scripts/inventory-workstation.sh` (read-only), then attach the
   output file to the chat. It is private; never commit it.
2. Go through `docs/end-state.md`: answer section 7, mark every candidate row
   keep / change / drop, and decide L1 (install path: Anaconda + `bootc switch`,
   recommended, vs. `install-atomic.sh`).
3. From the confirmed spec: a keep/retire list for this repo and the dotfiles repo, then
   rebuild the image layer and test it on the 2TB with nothing restored.

## Facts that are easy to forget
- Restic: `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`, password file
  `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
