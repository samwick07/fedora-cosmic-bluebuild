# files/ — content shipped into the image

| Directory | Lands at | Notes |
| --- | --- | --- |
| `etc/` | `/etc/` | Static config. On ostree it is stored as `/usr/etc` and 3-way merged with local edits on every upgrade. |
| `scripts/` | run at build time (`script` module) or copied to `/usr/bin` (`files` module) | See the tables in `recipes/*.yml` for which is which. |
| `distrobox/distrobox.ini` | `/usr/share/distrobox/distrobox.ini` | `distrobox assemble` manifest: `dev`, `claude`, `rocm`; the dotfiles repo's `run_once_20-distrobox.sh` assembles it. |

Rules that bit us once already:

- Never target `/usr/local`, `/opt`, `/home`, `/root`, `/mnt` — they are symlinks into `/var`,
  which the image only populates on the very first `bootc install` and never on upgrade.
- Never `source: .` in a `files` module: it copies this whole directory to `/`.
- Scripts placed via `files` need an explicit `chmod 0755` snippet (see the recipes).
