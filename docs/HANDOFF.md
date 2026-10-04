# HANDOFF — live status

Read this first in every session, then `docs/end-state.md` (the spec). Keep it short:
where things stand and the exact next step. No personal values here (write `$SITE_USER`).
Private facts: `dotfiles/.migration-prep/HANDOFF.md`; the story so far:
`dotfiles/.migration-prep/JOURNAL.md`.

Last updated: 2026-10-03 (late: all PRs merged; next is publishing the image, then the 2TB)

## Where things stand
- **Built, not yet run on hardware.** The laptop runs the 4TB Workstation; the 2TB waits in
  the DAS enclosure for a fresh install. Image, user layer and migration are written,
  linted, unit-tested with stubs, and the image builds green in CI.
- **No open PRs.** #8–#13 here and dotfiles #1–#4 are merged; PR CI was green.
- **The published image is stale.** The last build of `main` that pushed was 2026-10-02
  (`187dd1d`, before the F9 rebuild), and the nightly cron has never fired (no scheduled
  run in the Actions history). The kickstart installs `:latest`, so `main` must be built
  and signed before the 2TB install.
- **The shape (spec section 5):** stock COSMIC Atomic ISO + `install/frmwrk.ks` → signed
  custom image (stock base + virtualization stack, Tailscale, restic, distrobox, CAC,
  Homebrew; F9) → first-boot services finish alone → user layer (`chezmoi init --apply`)
  → one-time migration (`dotfiles/.migration-prep/frmwrk/migrate.sh`).
- **Boxes:** `dev`, `claude`, `rocm` (rootless, from the dotfiles' `distrobox.ini`) and
  `net` (rootful, created and kept by the image). Boxes for single projects come later,
  declared with their projects.
- **Software comes from its publisher (F10):** nothing is carried over from the
  Workstation except data and settings. Windscribe's `.deb` is fetched by the `net` box;
  Cisco's `.deb` needs a direct link from work IT (`CISCO_DEB_URL`, private), because Cisco
  publishes it only behind a login. Without the link, the work VPN is method (a),
  NetworkManager-openconnect (`work-vpn`), which needs no package.
- **Acceptance without manual checks (L5):** `sudo cosmic-acceptance` (live state +
  evidence from use; PASS / FAIL / WAIT / YOU), `--exercise` once with you present; the
  nightly job reruns it and pins known-good (L3). Left to you: finger, PIN, passphrase,
  the CAC PIN on a site and in Windows, VPN logins, Secure Boot off in the firmware.
- **Backups (J1, R1):** nightly home snapshot (7 kept), rsync snapshots on the DAS,
  restic to B2 (`--tag nightly`), restore probe, hourly catch-up; set up by M11.

## Next (in order)
1. Publish `main`: Actions → bluebuild → Run workflow (`recipe-frmwrk.yml`). Done when the
   run is green, its summary says "signature OK", and `skopeo inspect
   docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` lists the tag `22455b1-44` (or
   a newer `<sha7>-44`). Then check that the 06:17 UTC cron fires; if it does not, open an
   issue (J1 and L2 assume a nightly image).
2. Optional: work IT's direct link to the Cisco Secure Client `.deb` (5.1.15+) → private
   `site.env` `CISCO_DEB_URL`; method (a) works without it.
3. Workstation: `dotfiles/.migration-prep/frmwrk/migrate.sh export` (W1 Docker volumes,
   W2 Cisco facts, W4 Notepad++ settings, W5 last backup; only the sudo password).
4. 2TB, image layer alone: drive into the laptop, Secure Boot off, `docs/install.md`
   (boot line `inst.ks=… cosmic.disk=<by-id name> cosmic.hostname=frmwrk-test`) → reboot
   once → `sudo cosmic-acceptance`, then `--exercise`. Done when the image row of spec
   section 6 has no FAIL. Remove the old `frmwrk-test` SSH key from GitHub.
5. 2TB, user layer alone: SSH key, `brew install chezmoi`, `chezmoi init --apply` →
   `sudo cosmic-enroll` → `sudo cosmic-acceptance --user`. Done when the user-layer row
   passes.
6. 2TB, migration: `migrate.sh all`; use it daily; WAIT lines clear with use; VPN trial
   decides N4/N5.
7. Then the 4TB with no changes; then the warm spare (L4); rechunk only if L6 says so.

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
