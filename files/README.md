# files/ — content shipped into the image

Every file here answers to a row of `docs/end-state.md`; the recipes say where each lands.

| Directory | Lands at | What |
| --- | --- | --- |
| `scripts/` | build steps (`script` module) or `/usr/bin`, `/usr/libexec` (`files` module) | build: `install-dod-roots.sh` (V4), `configure-hibernation.sh` (F2), `fix-signing-registry.sh`; shipped: `cosmic-nightly` (J1), `cosmic-acceptance` (L5), `cac-status`, `win11-cac` (V2), `enable-hibernation.sh`, `cosmic-report`, `cosmic-session-wait` (D1), `libvirt-user-groups` (V1); desktop only: `enable-vfio.sh`, `configure-amd-gpu-desktop.sh` |
| `systemd/` | `/usr/lib/systemd/{system,user}/` | the nightly and catch-up timers, libvirt relabel and group units, flatpak retry drop-ins (N1) |
| `share/` | `/usr/share/fedora-cosmic-atomic/` | `flatpaks.list` and `drift-ignore.regex` (O1), `nightly.example.env` (template for the private `/etc` settings) |
| `lib/` | `/usr/lib/…` | i2c module load + uaccess rule (P11), dracut TPM2 module (P9) |
| `xdg/` | `/etc/xdg/autostart/` | the nightly report notifier |

Rules that bit us once already:

- Ship under `/usr` (and `/etc` only when a program reads nowhere else): `/usr` always
  follows the image, while a touched `/etc` file stops receiving updates.
- Never target `/usr/local`, `/opt`, `/home`, `/root`, `/mnt` — they are symlinks into `/var`,
  which the image only populates on the very first install and never on upgrade.
- Never `source: .` in a `files` module: it copies this whole directory to `/`.
- Files placed via `files` need an explicit `chmod` snippet (see the recipes); the smoke
  test checks executables and 0644 data files.
