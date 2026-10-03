# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 (night)

## Where things stand
- **The spec is complete for the first install** (`docs/end-state.md`, section 6 =
  acceptance). Nothing has run on hardware since the refactor; the laptop is on the 4TB
  Workstation; the 2TB waits in the DAS enclosure for a fresh install.
- **Decisions, 2026-10-03:** whole virtualization stack layered (V1); Homebrew is the CLI
  lane (C1); restore point within a day (R1). **Corrections (night):** `win11-cac` is the CAC
  default, SPICE redirect the required fallback (V2); one home snapshot a day, 7 kept (S2e);
  the DAS stays an ordinary disk, only the old restic repo is frozen until MIGRATION part C
  (F8); the 2TB becomes a warm spare refreshed weekly (L4, built after the 4TB install); no
  live VM backup. **No manual configuration:** kickstart install (`install/frmwrk.ks`),
  first-boot services (signed origin, hibernation kargs), the rootful `net` box created by
  the image (VPN clients, nmap/mtr/tcpdump), `cosmic-enroll`, `cosmic-acceptance --pin`,
  and the private `migrate.sh` for the one-time steps.
- **Merged:** #8, #9. **Open, a chain** (each includes the ones before; merge in order, or
  only the last): #10 virtualization + Homebrew → #11 snapshots, box drift → #12 docs,
  acceptance, automation, corrections. Dotfiles **#3** (Brewfile, box baselines,
  `migrate.sh`, MIGRATION) goes with them.
- **First seen on the 2TB:** the kickstart (`ostreecontainer` from the stock Atomic ISO,
  the passphrase prompt), the first-boot services, brew inside the boxes, btrfs snapshots
  and the bind-mounted restic run, the `net` box and its launchers, `migrate.sh`.
- **One dotfiles repo for both machines** (F7), keyed by the machine name; frmwrk's
  migration lives in `dotfiles/.migration-prep/frmwrk/`.
- Private facts and rules: `dotfiles/.migration-prep/HANDOFF.md`.

## Next (in order)
1. Merge #10 → #11 → #12 and dotfiles #3; confirm the nightly CI publishes and signs.
2. Workstation: `.migration-prep/frmwrk/migrate.sh export` (W1, W4, W5); W2 by you (Cisco facts, vendor `.deb`s
   into `DAS/migration/net-box-installers/`).
3. 2TB: `docs/install.md` (kickstart) → `sudo cosmic-acceptance` → user layer →
   `sudo cosmic-enroll` → `sudo cosmic-acceptance --user` → `migrate.sh all` → section 6
   manual checks → `sudo cosmic-acceptance --pin`.
4. Then the 4TB, with no changes; then the warm spare (L4) and the download-size check (L6).

## Facts that are easy to forget
- Old restic archive (read-only, migration source): `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`,
  password file `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
