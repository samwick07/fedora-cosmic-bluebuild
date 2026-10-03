# HANDOFF — live status

Read this first in every session, then `docs/end-state.md`. Keep it short: where things
stand and the exact next step. No personal values here (write `$SITE_USER`).

Last updated: 2026-10-03 14:10 EDT

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
- **Spec decisions recorded** (2026-10-03): Cisco + Windscribe kept (NetworkManager
  first, rootful distrobox as fallback); podman only, Docker workloads migrate (M6);
  Claude Code CLI only in its box; PyCharm, DaVinci, Xilinx, Java dropped; Notepad++ via
  Bottles; Google via Chrome; Collabora Office; TPM2 unlock, printing, ddcutil,
  fingerprint, ROCm, AI CLIs kept; backups 3-2-1 (F8, S2a–d). Migration checklist added
  (spec 5a). Five questions left (spec section 7).
- **Project:** linked to this repo through GitHub; only the 2026-10-03 journal entry is
  uploaded (it moves to the dotfiles journal once that repo is linked).

## Next (in order)
1. Answer the five questions in `docs/end-state.md` section 7 (TPM2 PIN, Windscribe lane,
   backup tools/provider, desktop calendar, remaining proposals).
2. Mark the spec confirmed; write the keep/retire list for this repo and the dotfiles
   repo (grant the Claude GitHub App access to `dotfiles` for that).
3. M6 prep on the Workstation while Docker is still there: export the Open WebUI stack
   and Hermes volumes to the DAS.
4. Rebuild the image layer from the spec; install on the 2TB (stock ISO + `bootc switch`),
   nothing restored; run the image-layer checks.

## Facts that are easy to forget
- Restic: `/run/media/$SITE_USER/DAS/frmwrk-restic-repo`, password file
  `~/.restic/frmwrk-repo.pass`; always `latest --host frmwrk`; plain `sudo restic`.
- Hibernation needs Secure Boot off, a LUKS swap partition ≥ RAM, and `rd.luks.uuid` +
  `resume=` kargs (`docs/hibernation-setup.md`); validated green on the 2TB.
- `/home` → `/var/home` on Atomic. First boot of a fresh install has no Wi-Fi profile.
- Security loose ends: plaintext `cosign.key` and restic password copies on an exFAT drive →
  password manager; `docker logout ghcr.io` on the Workstation; the "frmwrk-test" SSH key
  on GitHub goes when the 2TB is reinstalled.
