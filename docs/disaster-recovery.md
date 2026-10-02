# Disaster recovery: a new or replacement drive

The system is declarative: the image (this repo, GHCR), the user layer
(chezmoi dotfiles) and the data (restic on the DAS) are all outside the
laptop. A dead NVMe costs a drive and an afternoon of restore time, nothing
else — as long as the pieces below exist.

## What must exist before you need it

| Piece | Where | Check |
| --- | --- | --- |
| Image | `ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (public, signed) | `cosign verify --key cosign.pub …` |
| Repo + `cosign.pub` | github.com/samwick07/fedora-cosmic-bluebuild | — |
| `site.env` (user, hostname, DAS UUID, swap size, protected disks) | private dotfiles repo `.migration-prep/site.env`, the DAS root, the key USB | `diff` the copies after any change |
| restic repo | DAS: `frmwrk-restic-repo` | backup log ends with `no errors were found` |
| A bootable rescue system | the old test drive in its USB enclosure (has every tool below + site.env), or any Fedora live USB with podman | boot it once a quarter |
| Secrets | your head / password manager: DAS LUKS passphrase, restic passphrase, GitHub login (for the private dotfiles if the SSH key is not restored yet) | — |

The new drive's LUKS passphrase and the login password are chosen during the
procedure.

## Procedure

1. **Boot the rescue system.** Test drive: plug in the USB enclosure, **F12**,
   pick it. Live USB instead: `sudo dnf install -y gdisk dosfstools` if
   missing, `git clone https://github.com/samwick07/fedora-cosmic-bluebuild`,
   and put `site.env` into `scripts/targets/` (from the DAS or the key USB).
2. **Identify the new disk by id, never by letter:**
   ```bash
   ls -l /dev/disk/by-id/ | grep -v part      # e.g. nvme-WD_BLACK_SN850X_4000GB_<serial>
   ```
3. **Check the disk, then install — one command** (shipped as
   `/usr/bin/install-to-disk.sh`; repo: `scripts/install-to-disk.sh`):
   ```bash
   install-to-disk.sh --check /dev/disk/by-id/nvme-…    # verdict only, no root, no changes
   sudo install-to-disk.sh /dev/disk/by-id/nvme-…       # add --test for a test install
   ```
   | Verdict | What happens |
   | --- | --- |
   | **new / blank** | partitions + encrypts it (asks the new LUKS passphrase once), installs — no other questions |
   | **contains data** | lists what is on it (Windows/NTFS, Linux filesystems, LUKS, mounted), offers to erase it: type `WIPE <name>` |
   | **already configured** | says so; reinstalling keeps ESP, /boot and the LUKS containers and reformats only the root (you type the disk name) |
   | **running / protected** | refuses, with the reason |

   It checks the image is present **before** erasing anything, writes the target
   file (`auto-<disk>.env`, next to `site.env` or in `/var/lib/fedora-cosmic-atomic/targets`),
   sets `SKIP_FINALIZE` from the bus (USB = 1) and hands over to `install-atomic.sh`.
   Under the hood: `prepare-disk.sh` → `make-target-env.sh` → `install-atomic.sh`
   (each still usable on its own).
4. **Image:** the rescue drive already has it in root's podman storage after an
   update; otherwise `sudo podman pull ghcr.io/samwick07/fedora-cosmic-frmwrk:latest`
   (public) and `cosign verify --key cosign.pub` it — `install-to-disk.sh` stops
   before erasing anything if the image is missing.
5. Power off, put the new drive in the slot (if it was in an enclosure), boot.
   Then `docs/migration-guide.md` Phase 3 (first boot) and Phase 4
   (`sudo post-install-setup.sh`: DAS, restore by allowlist, hibernation, CAC,
   VM, chezmoi, Tailscale).
6. After the first backup from the new drive: `restic snapshots --latest 2`
   shows the same host name as before (from `SITE_HOSTNAME`), so the backup
   continues the old snapshot series.

## Practise it

`sudo prepare-disk.sh --selftest` runs the partition + target-file part on a 20 GiB sparse loop
device (throwaway passphrase), then checks that `make-target-env.sh` reads the
layout back correctly. Run it after changing either script and once a quarter
on the rescue drive. A full rehearsal = the 2TB test install itself.
