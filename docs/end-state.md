# End state: frmwrk on Fedora COSMIC Atomic

**Status: confirmed except the rows marked `proposed` (section 7).** This is the specification the repo builds toward.
Nothing goes into `recipes/`, `files/` or the dotfiles repo unless a row here asks for
it, and every row says *why* it exists and *how we know it works*.

The first test run (2026-10-03) showed that the previous plan copied its contents from
the Workstation and installed them in one imperative pass. This document reverses that:
**decide the end state first, then build it in layers, each checked on its own.** The
Workstation is evidence of what is used (`scripts/inventory-workstation.sh`), not the
list to port.

## 1. Fixed decisions

| ID | Decision | Why | Consequences |
| --- | --- | --- | --- |
| F1 | **COSMIC** is the desktop | It is what is being evaluated as the GNOME replacement | Its bugs are ours to work around (login black screen, cosmic-comp#2690: `cosmic-session-wait`). GNOME-specific tools and extensions do not carry over. |
| F2 | **Hibernation** is required | Without it the battery dies in the bag within 3–4 hours | Secure Boot **off** (kernel lockdown blocks hibernation). LUKS2 swap **partition** ≥ RAM (60 GB → 96 GB), `rd.luks.uuid` + `resume=` kargs, SELinux `systemd_hibernate` module, lid → suspend-then-hibernate after 5 min. Disk layout and install path must provide this. |
| F3 | Hardware: Framework 13, Ryzen 7040 (780M iGPU), 60 GB RAM | — | AMD-only; no NVIDIA. ROCm needs `HSA_OVERRIDE_GFX_VERSION=11.0.0` if wanted at all. |
| F4 | Fedora 44 Atomic, custom image built with BlueBuild, signed, on public GHCR. **Nightly build in GitHub Actions** (free for public repositories); local builds to test a change before pushing | Reproducible system, rebuilt daily on the newest base | Nothing personal in the image or this repo (`check-leaks.sh`); personal values in `site.env` and the private dotfiles repo. The signing key lives in the repo's Actions secrets. |
| F5 | Encrypted disk (LUKS2: root and swap) | Laptop leaves the house | One passphrase at boot and at resume. |
| F6 | Test on the 2TB drive first; the 4TB Workstation is untouched until this spec's acceptance checks pass | The Workstation is the daily driver | Two installs of the same spec; the second must need no fixes. |
| F8 | **Backups follow 3-2-1**: local copy as plain files on the DAS (later a NAS), off-site copy encrypted (block-level) in the cloud | Data safety without lock-in to one target | Two tools, one trigger: the daily update routine (S2). Targets are configuration, so a NAS can replace the DAS. |
| F9 | **Base image as close to stock as possible.** An RPM is layered only when it needs the host kernel or a host service; configuration files are fine. Everything else is a flatpak, a distrobox, or a single binary in `$HOME` installed by the user layer | Fewer layered packages: smaller image, fewer update conflicts, closer to what Fedora tests | Layered: the libvirt/QEMU/swtpm stack (V1) and Tailscale (N3). Not layered: Homebrew, Ghostty, starship, topgrade, chezmoi, distrobox, Syncthing, restic, NetworkManager VPN plugins, `openssl`. |
| F7 | Names: images `fedora-cosmic-frmwrk` / `-dsktp`; hosts `frmwrk` / `dsktp` | "cosmic-desktop" reads as the DE | The desktop (dsktp) is out of scope until the laptop has run 3–6 months. |

## 2. How to read the requirement tables

- **Lane**: where it is declared.
  - `image` = recipe (needs the kernel, systemd, `/dev`, or must exist before the user layer)
  - `flatpak` = GUI app
  - `box:<name>` = a distrobox: `dev` (Fedora, rootless, daily work), `claude` (Ubuntu), `rocm`, `vpn` (rootful, see N4)
  - `user` = single binaries in `~/.local/bin` (chezmoi externals) or `uv` tools, installed by the user layer
  - `dotfiles` = user config (chezmoi)
  - `data` = restored or synced, never installed
  - `manual` = a documented one-time step
- **When**: `day-1` blocks daily use · `week-1` needed soon · `later` nice to have.
- **State**:
  - `confirmed` = decided
  - `proposed` = recommendation awaiting your answer (section 7)
  - `drop` = decided against
- **Evidence**: what the Workstation inventory (2026-10-03, read-only) shows. "Installed"
  is not "used"; shell history and enabled services are the stronger signals.
- **Check**: the acceptance test. Section 6 collects them.

## 3. Requirements

### 3.1 Platform and hardware

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| P1 | Boots to a LUKS prompt, then the COSMIC greeter, unattended | image + install | day-1 | — | confirmed | cold boot ×3 |
| P2 | Hibernation per F2 | image + install | day-1 | Workstation runs this way today: Secure Boot off, 96 GB LUKS swap partition | confirmed | `systemctl hibernate` → resume; lid closed 5 min → hibernates |
| P3 | Suspend on lid close (s2idle); Bluetooth after resume | image | day-1 | s2idle | confirmed | lid close/open; BT reconnects |
| P4 | Wi-Fi (MediaTek), Bluetooth, audio, webcam, USB-C displays | base image | day-1 | devices present | confirmed | manual pass |
| P5 | Firmware updates (fwupd / LVFS) | base image | week-1 | fwupd installed | confirmed | `fwupdmgr get-updates` |
| P6 | Fingerprint for login and sudo, enrolled at setup | base image if it ships `fprintd-pam` (else layer it) + manual (`fprintd-enroll`) | week-1 | Goodix reader; `sudo` asks for the finger daily | confirmed | `sudo` and the COSMIC lock screen accept the finger |
| P7 | Ambient light / rotation (`iio-sensor-proxy`) | — | — | no sign of use | drop | — |
| P8 | Power profiles, thermal | base image | day-1 | tuned-ppd + thermald enabled | confirmed | `powerprofilesctl` |
| P9 | TPM2 unlock of LUKS (root and swap) **with a PIN** | image (dracut `tpm2-tss` config) + manual (`systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes`) | week-1 | clevis-luks + clevis-pin-tpm2 installed on the Workstation | confirmed | boot and resume ask for the short PIN; the passphrase still works |
| P10 | Printing (CUPS, network and Bluetooth printers) | base image | week-1 | cups enabled | confirmed | a test page prints |
| P11 | External monitor brightness (DDC/CI) | image: i2c udev rule + `i2c-dev` module-load (config files); `ddcutil` in box:dev | later | installed | confirmed | `ddcutil detect` lists the monitor |

### 3.2 Desktop and shell

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | COSMIC session starts on every login (no black screen) | image | day-1 | — | confirmed | 10 logins; `journalctl -t cosmic-session-wait` |
| D2 | Terminal: **Ghostty in box:dev** (COPR inside the box, exported to the menu; opens a shell in `dev`). COSMIC Terminal (stock) for host administration | box:dev | day-1 | Ghostty autostarted daily; no official flatpak | proposed | Ghostty opens from the launcher into `dev`; COSMIC Terminal opens a host shell |
| D3 | bash + starship prompt | user + dotfiles | day-1 | starship in use | confirmed | prompt renders on the host and in boxes |
| D4 | tmux | — | — | not in shell history | drop | — |
| D5 | topgrade: the daily update routine (backup, image, flatpaks, boxes) | user + dotfiles | week-1 | 57 uses | confirmed | one command updates everything after the backup |
| D6 | Default browser: Google Chrome (box:dev); Firefox (base) as fallback | A2 | day-1 | Chrome is the https/html handler | confirmed | links open in Chrome |
| D7 | Window tiling | COSMIC built-in | day-1 | GNOME Tactile extension | confirmed | tile shortcuts work |
| D8 | PDF viewer: Chrome's built-in viewer; a flatpak only if annotation is missed | A2 | day-1 | Evince is the PDF handler | confirmed | a PDF opens |
| D9 | COSMIC settings (keybindings, panel, theme) | dotfiles | week-1 | — | confirmed | fresh login looks right |

### 3.3 Network and remote access

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| N1 | Network at first boot, or every first-boot job retries | image (retry drop-ins) | day-1 | first test install failed here | confirmed | flatpaks install without manual action |
| N2 | Wi-Fi profiles migrate (~20 saved networks) | migration (M1) | day-1 | many saved profiles | confirmed | known networks connect |
| N3 | Tailscale: this machine's own node | image (needs the host daemon; F9 exception) + manual | day-1 | in daily use | confirmed | `tailscale status` |
| N4 | Cisco VPN for work (AnyConnect) | **box:vpn** — rootful distrobox (Ubuntu 24.04 with systemd, for the client's service), Cisco Secure Client inside. Distroboxes share the host network, so routes from this box reach the host, `dev`, `claude` and podman containers alike. Fallback if DNS or posture fails: NetworkManager-openconnect layered (F9 exception) | week-1 | Cisco Secure Client installed, service enabled, autostarts | proposed | VPN up: an internal host resolves and answers from the host, from `dev` (Chrome, Ghostty) and from a podman container (Hermes) |
| N5 | Windscribe VPN: WireGuard profiles in NetworkManager (built in, no plugin) for everyday use; the Windscribe app in box:vpn for its extras | NetworkManager config + box:vpn | later | installed, helper service enabled | confirmed | connects; no DNS leak |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp: Documents, Music, Pictures, Videos, Downloads, Desktop, Public, Templates, Applications, VMs, Sync | user (binary) + dotfiles (user unit) | day-1 | 11 folders; started from an autostart entry today; one malformed folder entry (empty id, path `~`) to fix | confirmed | folders Up to Date |
| S2a | Local backup to the DAS as **plain files**: `rsync --link-dest` hard-link snapshots (unchanged files cost no space; restore = copy from a dated folder). Keep 7 daily, 4 weekly, 12 monthly. VM disk images are copied separately, only when changed and the VM is off, last 2 kept | dotfiles (script + config) | week-1 | today: restic to the DAS, run by hand | confirmed | a file from yesterday's snapshot opens directly from the DAS |
| S2b | Off-site: **restic to Backblaze B2**, encrypted on the laptop before upload; same retention | dotfiles (script + config) | week-1 | none today | confirmed | `restic snapshots` lists today's; a test restore works |
| S2c | Trigger: the daily update routine runs the backup first, then updates (topgrade custom step); a timer catches days without the routine | dotfiles (topgrade config + user timer) | week-1 | the backup is tied to the daily update habit | confirmed | backup log shows a run within the last 26 h |
| S2d | Scope: all of `$HOME` (dotfiles and Downloads included; minus `~/.cache`, Trash and container image layers — container **volumes** are included); `/etc/libvirt` (domain and network XML) and `/var/lib/libvirt` (disks, NVRAM, swtpm). Targets are configuration (DAS → NAS later). The old restic repo on the DAS stays read-only for the migration | dotfiles | week-1 | home ≈ 750 GB + VM disks | confirmed | a VM restores from backup and boots |
| S3 | Data outside Syncthing to carry over: `~/.ssh`, `~/.gnupg`, `~/.hermes`, `~/.claude*`, app configs as needed (not `~/.config` or `~/.local` wholesale) | migration (M5) | day-1 | `~/.config` 27 GB, `~/.local` 77 GB | confirmed | migration checklist |

### 3.5 Applications (GUI)

| ID | App | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| A1 | Claude Desktop | box:claude (Ubuntu) | day-1 | runs from a distrobox today | confirmed |
| A2 | Google Chrome (CAC capable) | box:dev (RPM) | day-1 | default browser | confirmed |
| A3 | Firefox | base image | — | installed (base) | confirmed (fallback) |
| A4 | VS Code | box:dev | day-1 | RPM from Microsoft repo | confirmed |
| A5 | Antigravity | box:dev | week-1 | RPM installed | confirmed |
| A6 | PyCharm | — | — | COPR repo enabled | drop |
| A7 | GIMP, darktable | flatpak | later | RPMs installed | confirmed |
| A8 | Calibre | flatpak | later | RPM installed | confirmed |
| A9 | DaVinci Resolve | — | — | installed by hand | drop (add back later if needed) |
| A10 | Xilinx / FPGA tools | — | — | in synced Applications | drop |
| A11 | Notepad++ (and other small Windows apps) without the VM | flatpak (Bottles, one bottle per app, menu launcher) | week-1 | the most-used Wine app; a ~2 GB Wine prefix today | confirmed |
| A12 | RDP client (Remmina) | flatpak | later | freerdp + GNOME Connections installed | confirmed |
| A13 | Flatseal | flatpak | later | installed | confirmed (Gear Lever: drop) |
| A14 | virt-manager | flatpak if it manages `qemu:///system` on the test install; else image | week-1 | follows V1 | confirmed |
| A15 | Mail, calendar, contacts: Google, in Chrome only; nothing from GNOME on COSMIC | A2 | day-1 | all Google via Chrome today | confirmed |
| A16 | Office: **Collabora Office** (`com.collaboraoffice.Office`) instead of LibreOffice | flatpak | week-1 | preferred over plain LibreOffice | confirmed |
| A16b | Signal, VLC, Inkscape | flatpak | later | used now and then | confirmed |
| A17 | Steam | — | — | ~40 KB of data: never used | drop |
| A18 | Zotero, Zen browser | — | — | leftovers | drop |

### 3.6 CLI tools

Evidence: Homebrew holds only three tools (chezmoi, cosign, lazydocker), so it does not
earn its own lane. Most-used CLI tools from shell history: docker (83), topgrade (57),
btop (47), lazydocker (30), git, nmap, ssh, fastfetch, gh, curl.

| ID | Tools | Lane | State |
| --- | --- | --- | --- |
| C1 | chezmoi, starship, topgrade, gh, btop, fastfetch, restic, syncthing, distrobox, uv | user (single binaries via chezmoi externals / `uv`) | confirmed |
| C1b | git | base image if present, else box:dev | confirmed |
| C1c | nmap, 7zip, ddcutil | box:dev | confirmed |
| C2 | lazydocker (against the user podman socket), cosign | user | confirmed |
| C3 | Homebrew | — | drop (three tools; moved to C1/C2) |

### 3.7 Development environments

| ID | Need | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| E1 | Claude Code CLI, exported with `distrobox-export` | box:claude (Ubuntu, beside Claude Desktop); **not** on the host | day-1 | a native host install exists today | confirmed |
| E2 | Python data-science / ML (Jupyter, PyTorch, scikit-learn, Hugging Face, spaCy, Optuna): `uv` projects in `$HOME` for CPU work, box:rocm for GPU; never `pip --user` | user + box:rocm | week-1 | large `pip --user` stack incl. useless CUDA wheels | confirmed |
| E3 | GPU compute (ROCm on the 780M) | box:rocm | later | mainly for dsktp; useful on the laptop | confirmed |
| E4 | Containers: **podman only** (base); `podman-compose` (uv tool); user `podman.socket` for Docker-API tools. No Docker Engine | base + user | week-1 | Docker workloads migrate (M6) | confirmed | the Open WebUI stack and the Hermes sandbox run under podman |
| E5 | Hermes agent (gateway user service, sandbox in podman); reaches the work VPN (N4 check) | user + E4 | week-1 | 46 uses, 15 GB state | confirmed |
| E6 | Other AI CLIs: Gemini CLI, OpenCode, browser-use | box:dev (Node, uv), bins exported to the host | later | installed on the host today | confirmed |
| E7 | Java (Temurin) | — | — | repo enabled | drop |
| E8 | Image builds: nightly in GitHub Actions; local test builds with the BlueBuild CLI container + podman + cosign | CI + user | week-1 | in use | confirmed |
| E9 | General dev toolchain (Node, uv, gcc, ShellCheck), AI CLIs (E6) | box:dev | week-1 | VS Code + Antigravity live there | confirmed |

### 3.8 Virtualization and CAC

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| V1 | Win11 VM (virtio, Secure Boot + TPM in the guest), same disk as today | image (libvirt stack; F9 exception) + migration (M7) | week-1 | the old Windows dev-eval VM and the Fedora COSMIC test VM are dropped | confirmed | boots, no BitLocker prompt |
| V2 | CAC reader passed into the Win11 VM | image (`win11-cac`) | week-1 | — | confirmed | `certutil -scinfo` in Windows |
| V3 | CAC on the host, in Chrome | base (`pcscd`) + box:dev (opensc, NSS db) | week-1 | user NSS db exists; a smart-card script in use | confirmed | PIN prompt on a DoD site |

### 3.9 Identity and secrets (how they reach a new machine)

| ID | Item | Lane | State |
| --- | --- | --- | --- |
| I1 | SSH key for GitHub: one key per machine, added to GitHub at setup | migration (M2) | confirmed |
| I2 | GPG keys, `gh` auth | migration (M2) | confirmed |
| I3 | Restic password, cosign key: in the password manager only (no plaintext copies) | manual | confirmed |
| I4 | Password manager: Google (in Chrome) | A2 | confirmed |

## 4. Install and lifecycle

| ID | Topic | Options | State |
| --- | --- | --- | --- |
| L1 | Install path | **Stock Fedora COSMIC Atomic ISO** (Anaconda), then `bootc switch` to the signed image. Anaconda custom partitioning: ESP, ext4 /boot, LUKS2 swap ≥ RAM, LUKS2 btrfs root, one passphrase. First `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (unverified), reboot, then `sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (the signing policy ships in the image; `docs/local-build.md`). Then check kargs (`rd.luks.uuid` for swap, `resume=`); `enable-hibernation.sh` adds what is missing. Secure Boot off after install (F2). Retires `install-atomic.sh`, `prepare-disk.sh`, `make-target-env.sh`, `install-to-disk.sh`. | **confirmed** 2026-10-03 |
| L2 | Updates: the daily routine (D5) runs the backup, then `bootc upgrade` to the nightly build; it applies at the next reboot. The stage-only timer stays as a backstop | user + image (drop-in exists) | confirmed |
| L3 | Rollback: previous deployment in the GRUB menu | built in | confirmed |
| L4 | Rescue: the 2TB test drive, after the test, as a bootable spare | — | confirmed |

## 5. How the end state is reached (bring-up model)

Lessons from the first run, as rules:

1. **Image layer.** A fresh install boots to a working COSMIC desktop with **nothing
   restored**. It also works without network on first boot: any first-boot job that needs
   network retries until it succeeds.
2. **User layer.** It applies to a bare home, runs as the user, and never needs sudo or a
   restored file to start. Order inside it is explicit: a step never depends on a file
   that a later step writes (the first run ran `brew bundle` before the Brewfile existed).
3. **Migration** is a one-time **checklist**, not a script inside the image: data, VM
   disk, identities (Syncthing, Tailscale, SSH). Each item has its own check, and nothing
   is marked done until its check passes.
4. Each layer is tested alone, in this order: image (on the 2TB), then user layer (on that
   bare image), then migration.
5. Acceptance = every **Check** in section 3 passes on the 2TB; then the same on the 4TB
   with no changes.

## 5a. Migration checklist (one-time, layer 3)

**Moves to the private dotfiles repo** (`.migration-prep/MIGRATION.md`) once Claude's
GitHub App can reach it: the checklist is one-time and personal, and this repo only keeps
what is reused (image, spec, install and recovery docs). Until then it stays here, generic.

Done by hand, in order, each item checked before the next; never part of the image.
Source: the Workstation itself or the existing restic archive on the DAS.

| ID | Item | How | Check |
| --- | --- | --- | --- |
| M1 | Wi-Fi profiles (N2) | copy `/etc/NetworkManager/system-connections/` (root, mode 600) from the archive | known networks connect |
| M2 | SSH, GPG, `gh` (I1, I2) | new SSH key for this machine, added to GitHub; import GPG keys; `gh auth login` | `ssh -T git@github.com`; `gpg -K` |
| M3 | Syncthing identity (S1) | test install: new device. Real install: reuse the Workstation's identity, or a new device (decide at that point) | folders Up to Date |
| M4 | Tailscale node (N3) | test install: new node. Real install: new node, old one removed in the admin console | `tailscale status` |
| M5 | Data outside Syncthing (S3) | restore by explicit path: `~/.hermes`, `~/.claude`, `~/.claude.json`, app configs as needed | the app starts with its state |
| M6 | Docker → podman (E4) | **on the Workstation, before the switch:** export the Docker volumes of the Open WebUI stack (Open WebUI, SearXNG, Tailscale sidecar) and the Hermes sandbox state to the DAS; on the laptop: import into podman volumes, run the compose file with `podman-compose`. The old `migrate-docker-to-podman.sh` is reference material | Open WebUI shows its history; Hermes runs its sandbox |
| M7 | Win11 VM (V1) | restore `Win11VM.qcow2`, NVRAM, swtpm state and the domain XML; `<uuid>` must equal the swtpm directory name | boots, no BitLocker prompt |
| M8 | Notepad++ settings (A11) | copy its AppData folder from the Wine prefix into the bottle | settings and sessions are back |
| M9 | Fingerprint and TPM2+PIN enrollment (P6, P9) | `fprintd-enroll`; `systemd-cryptenroll` on root and swap | checks of P6 and P9 |
| M10 | Backups running (S2) | first local and cloud run; the old restic repo on the DAS stays read-only | checks of S2a–S2c |

## 6. Acceptance checklist

Generated from the Check columns once the tables are confirmed.

## 7. Open questions

Everything else is confirmed (2026-10-03). Two proposals wait for your answer:

1. **D2 Terminal:** Ghostty inside box:dev, with COSMIC Terminal for host administration?
2. **N4 Cisco:** client in a separate rootful box:vpn (reach is the same for every box,
   since they share the host network), with NetworkManager-openconnect as the fallback if
   the in-box client cannot give the host working DNS?

## Change log

- 2026-10-03: draft after the first test run; F1 (COSMIC) and F2 (hibernation) confirmed
  as hard requirements; L1 confirmed: stock ISO + `bootc switch`.
- 2026-10-03: Workstation inventory added as evidence; candidates turned into proposals
  and questions; Homebrew lane proposed for removal; Zotero and Zen dropped.
- 2026-10-03: decisions recorded: Cisco and Windscribe kept (NetworkManager first);
  podman only (Docker dropped, workloads migrate); Claude Code CLI only in its box;
  PyCharm, DaVinci, Xilinx, Java dropped; Notepad++ via Bottles; Google via Chrome;
  Collabora Office instead of LibreOffice; TPM2 unlock, printing, monitor brightness,
  fingerprint, ROCm and the AI CLIs kept; backups 3-2-1 (F8, S2a–S2d); migration
  checklist (5a) added.
- 2026-10-03: spec confirmed except D2 and N4. New F9 (base as close to stock as
  possible); F4 changed: nightly build in GitHub Actions (free for public repos).
  Backups: rsync hard-link snapshots on the DAS, restic to Backblaze B2, scope = all of
  `$HOME` + libvirt. Windscribe via NetworkManager WireGuard plus its app in box:vpn.
  Google in Chrome only (no GNOME pieces). The migration checklist moves to dotfiles.
