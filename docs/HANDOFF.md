# HANDOFF — live status

Read this first in every session, then `docs/end-state.md` (the spec). Keep it short:
where things stand and the exact next step. No personal values here (write `$SITE_USER`).
Private facts: `dotfiles/.migration-prep/HANDOFF.md`; the story so far:
`dotfiles/.migration-prep/JOURNAL.md`.

Last updated: 2026-10-05 (B2 layout proposed: one shared repository; next is the 2TB install)

## Where things stand
- **Built, not yet run on hardware.** The laptop runs the 4TB Workstation; the 2TB waits in
  the DAS enclosure for a fresh install. Image, user layer and migration are written,
  linted, unit-tested with stubs, and the image builds green in CI.
- **Open PRs:** this one (spec S2f, V6 proposed; nothing built). Drift engine (O2, F11)
  merged 2026-10-05 (#20); built later in planned sprints, after step 3.
- **B2 off-site (proposed, this PR):** one restic repository that frmwrk creates and dsktp
  joins later, so what Syncthing keeps identical is stored once (S2f); the Win11 VM disk gets
  `discard='unmap'` (V6). dsktp's backups are postponed with the rest of dsktp (spec 7.3).
- **NAS (next PR, stacked on this one):** S2g confirmed (nightly local copy to the NAS, history
  in its snapshots, Tailscale by default); S2h (DAS = slow copy of every machine) and S2i
  (Syncthing hub on the NAS) proposed. Nothing built until the NAS is bought.
- **Workstation export complete (W1, W2, W4, W5):** volume archives, the compose project,
  Cisco facts and the kept installer, Notepad++ settings in `DAS/migration/`; the last
  Workstation backup is in the old repo (`restic check` clean). Nothing else is needed
  from the Workstation until the real 4TB install (then `export w5` again).
- **Image published:** `main` (`0e85dd1`) built by hand 2026-10-04 02:33 UTC: build, smoke
  test, push, sign and signature check all green. The nightly cron has never fired yet.
- **Cisco (decided 2026-10-03):** no `.deb` from work IT; the web-deploy `.sh` kept from the
  Workstation is the one noted F10 exception (spec F10, N4). W2 copies it to the DAS, M10
  into `/var/lib/net-box/installers/`, `cosmic-net-box` runs it in the box once; the
  headend upgrades the client on connect. Method (a) stays in the trial.
- **The shape (spec section 5):** stock COSMIC Atomic ISO + `install/frmwrk.ks` → signed
  custom image (stock base + virtualization stack, Tailscale, restic, distrobox, CAC,
  Homebrew; F9) → first-boot services finish alone → user layer (`chezmoi init --apply`)
  → one-time migration (`dotfiles/.migration-prep/frmwrk/migrate.sh`).
- **Boxes:** `dev`, `claude`, `rocm` (rootless, from the dotfiles' `distrobox.ini`) and
  `net` (rootful, created and kept by the image). Boxes for single projects come later,
  declared with their projects.
- **Software comes from its publisher (F10):** nothing is carried over from the
  Workstation except data and settings, and the one noted exception, Cisco's installer.
  Windscribe's `.deb` is fetched by the `net` box.
- **Acceptance without manual checks (L5):** `sudo cosmic-acceptance` (live state +
  evidence from use; PASS / FAIL / WAIT / YOU), `--exercise` once with you present; the
  nightly job reruns it and pins known-good (L3). Left to you: finger, PIN, passphrase,
  the CAC PIN on a site and in Windows, VPN logins, Secure Boot off in the firmware.
- **Backups (J1, R1):** nightly home snapshot (7 kept), rsync snapshots on the DAS,
  restic to B2 (`--tag nightly`), restore probe, hourly catch-up; set up by M11.

## Next (in order)
1. Merge this PR (confirms S2f, V6; builds nothing). Check that the 06:17 UTC cron fires;
   if not, open an issue. Then, small PR: `nightly.example.env` gets a generic repository
   path; M11 in the dotfiles notes that it creates the shared repository.
2. 2TB, image layer alone: drive into the laptop, Secure Boot off, `docs/install.md`
   (boot line `inst.ks=… cosmic.disk=<by-id name> cosmic.hostname=frmwrk-test`) → reboot
   once → `sudo cosmic-acceptance`, then `--exercise`. Done when the image row of spec
   section 6 has no FAIL. Remove the old `frmwrk-test` SSH key from GitHub.
3. 2TB, user layer alone: `docs/install.md` section 4 → `sudo cosmic-acceptance --user`.
   Done when the user-layer row passes.
4. 2TB, migration: `migrate.sh all`; use it daily; WAIT lines clear with use.
5. Before the real 4TB install: `migrate.sh export w5` on the Workstation. Then the 4TB
   with no changes; then the warm spare (L4); rechunk only if L6 says so.

## Watch on the 2TB (unproven until hardware)
- Cisco in a rootful distrobox (distrobox#1536) and whether the VPN's DNS reaches the
  host (`known-issues.md`; the tunnel records show it).
- RTC wake from hibernation on the Framework firmware (`--exercise` says when to press power).
- The black-screen workaround at login (`cosmic-session-wait`, D1 counts logins).
- The kickstart's `ostreecontainer` from the stock ISO; first-boot services; brew inside
  the boxes; btrfs snapshots + the bind-mounted restic run.

## Facts that are easy to forget
- Old restic archive (read-only migration source): `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`,
  `latest --host frmwrk`; deleted only by `migrate.sh retire` after 30 good nights.
- New B2 repo: always `latest --host <host> --tag nightly` (VM disks are their own snapshots).
- Hibernation needs Secure Boot off, LUKS swap ≥ RAM, `resume=` + `rd.luks.uuid` kargs.
- `/home` → `/var/home` on Atomic. Write to `/var/home`, not through the symlink.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT
  drive → password manager; `docker logout ghcr.io` on the Workstation; the old
  `frmwrk-test` SSH key on GitHub goes when the 2TB is reinstalled.
