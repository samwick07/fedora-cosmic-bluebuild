# Disaster recovery

Nothing on the laptop is the only copy. The system is rebuilt from two repositories and
the data from two backups; a dead drive costs a drive and an afternoon.

| Lost | Comes back from | How |
| --- | --- | --- |
| A file, up to a week ago | `/var/home/.snapshots/` (daily, last 7, on the laptop) | `docs/restore.md` |
| The laptop's disk, and you need to work **now** | The warm spare: the 2TB in the DAS enclosure, refreshed weekly (L4) | put it in the slot (or boot it from the enclosure), unlock, work; at most a week behind, plus whatever restore brings back |
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
| A warm spare | the 2TB in the DAS enclosure, refreshed weekly by the nightly job (L4) | the report's weekly line; a rehearsal boot each quarter with networking off |

## Rebuild a machine

1. Install per `docs/install.md` (stock ISO + kickstart; the first boot finishes the rest;
   Secure Boot off). To return to the exact image of the last
   backup, switch to the digest in the manifest instead of `:latest` (`docs/restore.md`).
2. User layer: SSH key, `brew install chezmoi`, `chezmoi init --apply`.
3. Restore per `docs/restore.md` "The whole machine as of yesterday": home, `/etc` except
   the install-specific files, `/var` state, VM disks, then the boxes and flatpaks from the
   manifest.
4. `sudo cosmic-acceptance --exercise` (checks, one suspend and one hibernate), the drift report.
5. Re-enrol what is tied to the hardware or the install: `sudo cosmic-enroll` (fingerprint,
   TPM2 + PIN); Tailscale logs in again unless the old machine is gone for good and its
   state was restored.

## Practise it (spec L4)

Every quarter: boot the warm spare once with networking off (it carries the primary's
Tailscale and Syncthing identities) and open a few files; restore one folder from B2 and
the VM disk from the DAS. A full rebuild from these steps is the fallback when no spare
exists.
