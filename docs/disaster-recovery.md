# Disaster recovery

Nothing on the laptop is the only copy. The system is rebuilt from two repositories and
the data from two backups; a dead drive costs a drive and an afternoon.

| Lost | Comes back from | How |
| --- | --- | --- |
| A file, minutes or hours ago | `/var/home/.snapshots/` (hourly, last 48 h, on the laptop) | `docs/restore.md` |
| A file or folder, days ago | DAS snapshots (plain files) or B2 (restic) | `docs/restore.md` |
| A bad update | The previous or the pinned deployment in GRUB | `sudo bootc rollback`, or pick it at boot |
| The system disk, or the laptop | Image (GHCR) + dotfiles (GitHub) + data (DAS or B2) | below |
| The DAS | B2 (independent tool, place and format) | replace the DAS; the next night writes a new snapshot series |

## What must exist before you need it

| Piece | Where | Check |
| --- | --- | --- |
| Image | `ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (public, signed, rebuilt nightly) | `cosign verify --key cosign.pub ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` |
| Image definition | this repository | — |
| User layer | the private dotfiles repository | `chezmoi status` empty (drift report) |
| Data and machine state | DAS snapshots + B2, nightly (S2, R1) | the nightly report: restore point < 26 h |
| Secrets | password manager: LUKS passphrase, restic repository password, B2 keys (nightly and admin), GitHub login | — |
| A bootable spare | the 2TB test drive after the test (L4) | boot it once a quarter |

## Rebuild a machine

1. Install per `docs/install.md` (stock ISO, partitioning, `bootc switch`, signed rebase,
   Secure Boot off, `enable-hibernation.sh`). To return to the exact image of the last
   backup, switch to the digest in the manifest instead of `:latest` (`docs/restore.md`).
2. User layer: SSH key, `brew install chezmoi`, `chezmoi init --apply`.
3. Restore per `docs/restore.md` "The whole machine as of yesterday": home, `/etc` except
   the install-specific files, `/var` state, VM disks, then the boxes and flatpaks from the
   manifest.
4. `sudo cosmic-acceptance --user`, the drift report, one hibernate/resume.
5. Re-enrol what is tied to the hardware or the install: fingerprint (`fprintd-enroll`),
   TPM2 + PIN (`systemd-cryptenroll`), Tailscale (log in again unless the old machine is
   gone for good and its state was restored).

## Practise it (spec L4)

After the 4TB install: one full rebuild of the 2TB from these steps, timed. Every quarter:
one folder from B2 and the VM disk from the DAS, restored and opened.
