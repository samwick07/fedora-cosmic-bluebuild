# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 (late night)

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
  the image (VPN clients, nmap/mtr/tcpdump), `cosmic-enroll`, and the private `migrate.sh`
  for the one-time steps. **No manual checks (L5):** `cosmic-acceptance` reads live state and
  evidence recorded as the machine is used (journal; `cosmic-evidence-sleep`,
  `cosmic-evidence-tunnel@`; CUPS; the nightly restore probe), `--exercise` runs the active
  trials once, the nightly job reruns it and pins known-good (L3). What is left to you:
  finger, PIN, passphrase, the CAC PIN on a site and in Windows, the VPN logins.
- **Cisco (N4b):** the Workstation's `~/Downloads` has the 5.1.11 web-deploy `.sh`; it goes
  into the rootful `net` box (it needs a writable `/usr` and systemd; proprietary, so never
  in the public image). `migrate.sh export` picks it up with the profiles and the facts;
  Windscribe's `.deb` is fetched by the image. Risk: distrobox#1536 (`known-issues.md`).
- **Merged:** #8–#12, dotfiles #3. **Open:** #13 (F7 one dotfiles repo; acceptance without
  manual checks; Cisco's `.sh` in the net box) with dotfiles **#4** (machines.yaml, W2 and
  M10 automatic).
- **First seen on the 2TB:** the kickstart (`ostreecontainer` from the stock Atomic ISO,
  the passphrase prompt), the first-boot services, brew inside the boxes, btrfs snapshots
  and the bind-mounted restic run, the `net` box with Cisco's `.sh`, the evidence recorders,
  `--exercise` (RTC wake from hibernation on this firmware), `migrate.sh`.
- **One dotfiles repo for both machines** (F7), keyed by the machine name; frmwrk's
  migration lives in `dotfiles/.migration-prep/frmwrk/`.
- Private facts and rules: `dotfiles/.migration-prep/HANDOFF.md`.

## Next (in order)
1. Merge #13 and dotfiles #4; confirm the nightly CI publishes and signs.
2. Workstation: `.migration-prep/frmwrk/migrate.sh export` (W1, W2, W4, W5; nothing typed
   but the sudo password).
3. 2TB: `docs/install.md` (kickstart) → `sudo cosmic-acceptance` → user layer →
   `sudo cosmic-enroll` → `migrate.sh all` → `sudo cosmic-acceptance --exercise` → use it;
   WAIT lines clear with use, the pin comes by itself.
4. Then the 4TB, with no changes; then the warm spare (L4) and the download-size check (L6).

## Facts that are easy to forget
- Old restic archive (read-only, migration source): `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`,
  password file `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
  The new B2 repo: `latest --host <host> --tag nightly` (VM disks are their own snapshots).
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
