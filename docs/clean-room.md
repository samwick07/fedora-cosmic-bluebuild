# Clean-room model: what lives where

The Workstation is not being ported; it is being replaced. Data survives,
everything else is declared again in the lane that fits the Atomic model.

| Layer | Owner | Reaches a new machine by |
| --- | --- | --- |
| System (kernel, daemons, host CLI, hardware env) | this repo → OS image | `bootc install` / `bootc upgrade` |
| User config + user-level setup | `samwick07/dotfiles` (chezmoi) | `chezmoi init --apply` |
| Live data (both machines) | Syncthing | already present when you sit down |
| Archive (everything, incl. VM disks) | restic on the DAS | `restic restore --include <path>` — by allowlist on rebuild, by hand afterwards |

Only the first two are declarative. The last two are data and are never "installed".

## Lanes for software

| Lane | Rule | Examples from the old Workstation |
| --- | --- | --- |
| **Image** (`recipes/`) | needs the host kernel, systemd, `/dev`, or must exist before the user layer can bootstrap | tailscale, syncthing, restic, libvirt/qemu/swtpm/edk2, fprintd, iio-sensor-proxy, NM VPN plugins, ghostty, tmux, starship, topgrade, chezmoi, age, distrobox |
| **Flatpak** (`common-modules.yml` → `default-flatpaks`) | GUI app | Chrome, Firefox, VLC, GIMP, Inkscape, Darktable, LibreOffice, Calibre, Signal, Steam, Bottles (replaces the wine RPMs), Remmina (replaces freerdp/tigervnc), Flatseal, Gear Lever |
| **Homebrew** (`~/.Brewfile` in dotfiles) | CLI tool, no distro dependency | eza bat fd ripgrep fzf zoxide jq yq btop fastfetch micro superfile gh uv shellcheck shfmt lazydocker opencode tesseract ocrmypdf nmap mtr |
| **distrobox** (`files/distrobox/distrobox.ini`) | needs a whole distro: IDEs, toolchains, vendor stacks | `dev` (Fedora: VS Code, Antigravity, Node 22, Java 25, Python, gcc), `claude` (Ubuntu 24.04: Claude Desktop from its apt repo, exported to the menu, plus the Claude Code CLI — as today, until an RPM/flatpak exists), `rocm` (AMD compute) |
| **AppImage** (`~/AppImages` + Gear Lever) | vendor ships only an AppImage | whatever is there today |
| **Dropped** | replaced by COSMIC or by a lane above | GNOME shell + extensions, gnome-software, Evolution, Rhythmbox, Ptyxis, gnome-boxes (→ virt-manager), docker/moby (→ podman), Thorium (→ Chrome), Windscribe/Cisco Secure Client RPMs (→ NM OpenVPN/OpenConnect; revisit if a site needs the vendor client) |

Decision rule when something new comes up: flatpak if it has a window, brew if
it is a binary you type, distrobox if it needs `apt`/`dnf` of its own, image
only if none of those work.

## Restore by allowlist

`files/etc/fedora-cosmic-atomic/restore-allowlist.txt` (shipped to `/etc` in the
image) is what `post-install-setup.sh` restores, in order: the Syncthing data
folders, then identity/credential dirs, then agent state you asked to keep,
then — last — the Syncthing device identity. Everything else stays in the
backup. When you miss something:

```bash
sudo restic -r /run/media/<user>/DAS/frmwrk-restic-repo ls latest /home/<user>/.config | less
sudo restic -r /run/media/<user>/DAS/frmwrk-restic-repo restore latest --target / --include /home/<user>/.config/darktable
sudo chown -R <user>: /home/<user>/.config/darktable
```

Then decide: is it config (→ `chezmoi add`), state the app should own (leave
it), or data (→ move into a Syncthing folder)?

## Dotfiles (chezmoi)

- Source of truth: `github.com/samwick07/dotfiles`. Bootstrap:
  `chezmoi init --apply samwick07`. Update: `chezmoi update`.
- Machine identity comes from the image: `/etc/os-release` `VARIANT_ID`
  (`frmwrk` | `dsktp`, the machine names) is `{{ .machine }}` in every template. Hostnames
  and prompts are not used.
- User-level setup lives in `run_once_*` scripts (Homebrew + Brewfile,
  `distrobox assemble`, flatpak overrides, `setup-cac.sh --user`, Syncthing user
  service). `post-install-setup.sh` step 6 triggers them after the data restore,
  which is what makes the CAC and Syncthing scripts find what they need.
- Secrets: age-encrypt into the repo once you have generated a key
  (`README.md` in the dotfiles repo). Until then `~/.ssh` and `~/.gnupg` come
  from the restic allowlist.
- COSMIC settings are not bulk-managed; cherry-pick individual RON files.

## Syncthing between laptop and desktop

Current folders (from `config.xml`): Documents, Music, Sync, Applications,
Videos, VMs, Downloads, Desktop, Pictures, Public, Templates; peers
`<user>@frmwrk` ↔ `<user>@dsktp`.

Rules that keep this safe with two active machines:

1. **Data only.** Nothing under `~/.config`, `~/.local`, `~/.var` is ever a
   Syncthing folder. Config is chezmoi's; app state is the app's.
2. **`~/VMs` holds reference images, not running VMs — fine to sync.** The
   rule to keep: a disk image that is *booted* never lives in a Syncthing
   folder (that is `/var/lib/libvirt/vm-images`, restic-only). If a reference
   image ever gets booted from `~/VMs`, copy it out first.
3. **Staggered File Versioning on every folder.** A bad merge becomes a
   recoverable old version instead of a loss.
4. **One machine edits a given file at a time.** Syncthing replicates; it does
   not merge. Markdown conflicts are trivial to reconcile, office/binary files
   are not. Close the file before switching machines.
5. **`.stignore` per folder**: `node_modules`, `.venv`, `__pycache__`,
   `.git` (push/pull code instead of syncing working trees), `(?d).DS_Store`,
   `(?d)*.tmp`. Downloads: consider ignoring `*.iso` and `*.part`.
6. **Identity is data.** `~/.local/state/syncthing/{cert.pem,key.pem,config.xml}`
   is this machine's device ID and folder list. It is on the restore allowlist,
   *last*, and the user service is enabled only after it is back. Never start
   Syncthing on a rebuilt machine before the folders are restored: an old
   identity plus empty folders propagates deletions to the desktop. Pause the
   folders on the desktop during a rebuild as belt-and-braces.
7. **Direct connection over Tailscale.** In each device's settings set the
   address to `tcp://<tailscale-ip>:22000` so laptop and desktop always find
   each other without relays, wherever the laptop is.
8. **Hibernation is fine.** The laptop resumes syncing where it stopped;
   versioning covers files edited on the desktop meanwhile.

## What the first weeks look like

The first `post-install-setup.sh` run leaves you with: data back, browsers and
media apps installed, brew tools, three containers, CAC working in native
Firefox, Syncthing reconnected, hibernation verified. Expect to spend the
following days pulling forgotten pieces from the archive with the three lines
above and deciding which lane each belongs in. Every such decision is a commit
to this repo or to the dotfiles repo, and the next rebuild — laptop or, months
from now, desktop — will not ask the question again.
