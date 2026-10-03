# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 (night)

## Where things stand
- **The spec is complete for the first install** (`docs/end-state.md`), including the
  acceptance checklist (section 6) and the install path (`docs/install.md`). Nothing has run
  on hardware since the refactor; the laptop is on the 4TB Workstation, the 2TB is in the
  USB enclosure awaiting a fresh install.
- **Decisions on 2026-10-03 (evening):** the whole virtualization stack is layered like
  Bluefin DX (SPICE USB redirection of the CAC reader is the daily path; no virt-manager
  flatpak). Homebrew is the CLI lane. R1: a restore point within a day (all of `/etc`, `/var`
  state, a nightly manifest, hourly catch-up). Approved from the design review: hourly home
  snapshots, backups from a snapshot, box drift and monthly rebuild, live VM backup (V5,
  after M7), DAS write rule, signed-origin check, `cosmic-acceptance`, docs rewrite.
- **Merged:** #8 (HANDOFF), #9 (R1). **Open, a chain** (each includes the ones before;
  merge in order, or only the last): #10 virtualization + Homebrew → #11 snapshots, box
  drift → #12 docs, acceptance, pre-install items. CI (build, smoke test, `bootc container
  lint`) green on all three. Dotfiles **#3** (Brewfile, box baselines, VPN box state,
  MIGRATION) goes with #10.
- **Not verifiable here, first seen on the 2TB:** brew in the boxes (read-only mount),
  btrfs snapshots and the bind-mounted restic run, SPICE redirect with host pcscd running,
  `cosmic-acceptance` on a real machine.
- **VPN trial** (N4/N5) and **CAC everywhere** (V2/V3) are decided by testing on the 2TB.
- Private facts and rules: `dotfiles/.migration-prep/HANDOFF.md`; the one-time checklist:
  `dotfiles/.migration-prep/MIGRATION.md`.

## Next (in order)
1. Merge #10 → #11 → #12 and dotfiles #3; confirm the nightly CI publishes and signs.
2. Workstation, read-only except `DAS/migration/`: MIGRATION W1 (Docker volumes), W2
   (Cisco facts), W4 (Notepad++), W5 (last backup).
3. 2TB: `docs/install.md` end to end → `sudo cosmic-acceptance` → user layer →
   `sudo cosmic-acceptance --user` → MIGRATION part B (M1–M12) → section 6 manual checks.
4. Then the 4TB, with no changes; then L4 (rehearsal on the 2TB) and L6 (download size).

## Facts that are easy to forget
- Old restic archive (read-only, migration source): `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`,
  password file `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
