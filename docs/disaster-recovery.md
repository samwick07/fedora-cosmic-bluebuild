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
3. **Partition + encrypt** (shipped in the image as `/usr/bin/prepare-disk.sh`;
   in the repo `scripts/prepare-disk.sh`):
   ```bash
   sudo prepare-disk.sh --dry-run /dev/disk/by-id/nvme-…   # read what it will do
   sudo prepare-disk.sh /dev/disk/by-id/nvme-…             # asks the new LUKS passphrase once
   ```
   It refuses the disk you booted from and any disk holding a
   `PROTECTED_LUKS_UUIDS` container; a non-blank disk needs `WIPE <name>` typed.
4. **Target file:**
   ```bash
   sudo make-target-env.sh /dev/disk/by-id/nvme-… > ~/new-disk.env
   ```
   Internal NVMe: `SKIP_FINALIZE=0`. Real machine: `TEST_INSTALL=0`. If the
   rescue system's `site.env` protects the dead drive's UUIDs, nothing to change
   (they are simply not present).
5. **Image:** the rescue drive already has it in root's podman storage after an
   update; otherwise `sudo podman pull ghcr.io/samwick07/fedora-cosmic-frmwrk:latest`
   (public) and `cosign verify --key cosign.pub` it.
6. **Install:** `sudo install-atomic.sh ~/new-disk.env` — the summary shows the
   image id; type the disk name.
7. Power off, put the new drive in the slot (if it was in an enclosure), boot.
   Then `docs/migration-guide.md` Phase 3 (first boot) and Phase 4
   (`sudo post-install-setup.sh`: DAS, restore by allowlist, hibernation, CAC,
   VM, chezmoi, Tailscale).
8. After the first backup from the new drive: `restic snapshots --latest 2`
   shows the same host name as before (from `SITE_HOSTNAME`), so the backup
   continues the old snapshot series.

## Practise it

`sudo prepare-disk.sh --selftest` runs steps 3–4 on a 20 GiB sparse loop
device (throwaway passphrase), then checks that `make-target-env.sh` reads the
layout back correctly. Run it after changing either script and once a quarter
on the rescue drive. A full rehearsal = the 2TB test install itself.
