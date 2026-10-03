# Restore: one file, one folder, or the whole machine as of yesterday

Spec R1: a restore or rebuild returns to the previous day's state. The nightly job (J1)
writes two copies of the same scope (S2d: `$HOME`, all of `/etc`, `/var` state, VM disks)
plus a machine manifest in `/var/lib/cosmic-nightly/manifest/`, which is itself in both
copies. restic records your home as `/var/home/$SITE_USER` (its real path on Atomic).
Paths below write `$SITE_USER`; `$DAS` is the snapshot folder from `nightly.env`
(`LOCAL_SNAPSHOT_DIR`).

## Which copy to use

| Situation | Copy | Why |
| --- | --- | --- |
| A file deleted or broken in the last week | `/var/home/.snapshots/` on the laptop | One read-only snapshot a day, 7 kept (S2e); no tool, no network |
| A file or folder, at the desk | DAS | Plain files: open or copy them, no tool, no password |
| A file or folder, away from the DAS | B2 | restic downloads only what the file needs |
| The laptop's disk is lost | DAS if at hand, else B2 | Same content; the DAS is faster |
| The DAS is lost or damaged | B2 | The copies are independent: different tool, place and format |

## One file or folder

From the laptop's own daily snapshots (the last 7 days; same disk, so not a backup):

```bash
ls /var/home/.snapshots/                     # 2026-10-02  2026-10-03 …
cp -a /var/home/.snapshots/2026-10-03/$SITE_USER/Documents/report.odt ~/Documents/
```

From the DAS (dated folders, newest last):

```bash
ls "$DAS"                                    # 2026-10-02  2026-10-03 …
cp -a "$DAS/2026-10-03/home/Documents/report.odt" ~/Documents/
```

From B2 (encrypted; restic decrypts on the laptop). Needs the repository password (password
manager, spec I3) and a key that can read the bucket:

```bash
sudo -i                                                  # a root shell
set -a; . /etc/fedora-cosmic-atomic/nightly.env; set +a  # repository, password file, keys
restic snapshots --host frmwrk                           # pick one, or use latest
restic find --host frmwrk 'report.odt'                   # where it is, in which snapshots
restic restore latest --host frmwrk --target /var/tmp/r \
    --include /var/home/$SITE_USER/Documents/report.odt       # one file (or a folder)
restic dump latest --host frmwrk /var/home/$SITE_USER/Documents/report.odt > /var/tmp/report.odt
```

On a machine without `nightly.env` (a rebuild), export `RESTIC_REPOSITORY`, the key
variables and `RESTIC_PASSWORD_FILE` by hand from the password manager first. Only the
parts of the repository that hold the requested files are downloaded and decrypted.

To browse snapshots like folders: `restic mount ~/restic-mnt`. Fedora 44 ships only
`fusermount3`; restic looks for `fusermount`, so link it once:
`ln -s /usr/bin/fusermount3 ~/.local/bin/fusermount`. Always pass `--host`: `latest` alone
is the newest snapshot of *any* host (test installs are their own host).

## A changed or deleted file in `/etc`

```bash
sudo diff -ru "$DAS/2026-10-03/etc" /etc | less       # what changed since last night
sudo cp -a "$DAS/2026-10-03/etc/NetworkManager/system-connections/Home.nmconnection" \
     /etc/NetworkManager/system-connections/
sudo restorecon -Rv /etc/NetworkManager
```

## The whole machine as of yesterday

1. **Install** per `docs/install.md` (stock ISO, partitioning for hibernation).
2. **Same image as yesterday:** the booted digest is in `manifest/bootc-status.json`
   (`.status.booted.image.imageDigest`). `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk@<digest>`
   pins it; switch back to `:latest` once everything else is restored.
3. **Home:** copy `$DAS/<date>/home/` to `/var/home/$SITE_USER/` (write to `/var/home`,
   not through the `/home` symlink), or `restic restore … --include /var/home/$SITE_USER --target /`.
4. **`/etc`:** restore everything **except** what belongs to this installation:

   | Keep the new install's | Why |
   | --- | --- |
   | `fstab`, `crypttab` | new partition and LUKS UUIDs |
   | `machine-id` | must be unique per installation |
   | `passwd`, `group`, `shadow`, `gshadow`, `subuid`, `subgid` | system ids may differ on a new install; the image puts the user back into `libvirt` at boot |
   | `ostree/`, `kernel/` | written by the installer |
   | `hostname` | only if the machine gets a new name |

   ```bash
   sudo rsync -aAX --exclude-from=- "$DAS/<date>/etc/" /etc/ <<'EOF'
   /fstab
   /crypttab
   /machine-id
   /passwd*
   /group*
   /shadow*
   /gshadow*
   /subuid*
   /subgid*
   /ostree/
   /kernel/
   EOF
   ```
   Kernel arguments are not in `/etc`: compare `manifest/kernel-cmdline.txt` with
   `rpm-ostree kargs` and run `enable-hibernation.sh` for `resume=` and `rd.luks.uuid`.
5. **`/var` state:** copy back `lib/bluetooth`, `lib/fprint`, `lib/libvirt`,
   `lib/containers/storage/volumes`, `roothome`, `usrlocal`, `opt` from `$DAS/<date>/var/`.
   `lib/tailscale` only if the old machine is gone for good (a second node with the same
   key conflicts); otherwise log in again.
6. **Labels:** `sudo restorecon -R /etc /var`.
7. **VM disks:** the newest copy in `$DAS/vm-images/` back to its folder.
8. **User layer:** `chezmoi init --apply` (bootstrap in the dotfiles README), then bring
   boxes and flatpaks to yesterday's set: compare `manifest/boxes/<box>.pkgs` with the box
   and `manifest/flatpaks-*.txt` with `flatpak list`; install what is missing.
9. **Check:** the drift report and `manifest/units-*.txt` against the restored machine;
   reboot; hibernate and resume once.
