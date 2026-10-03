# End state: frmwrk on Fedora COSMIC Atomic

**Status: DRAFT, under review.** This is the specification the repo builds toward.
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
| F4 | Fedora 44 Atomic, custom image built **locally** with BlueBuild, signed, on public GHCR | Reproducible system; GitHub Actions minutes nearly exhausted | Nothing personal in the image or this repo (`check-leaks.sh`); personal values in `site.env` and the private dotfiles repo. |
| F5 | Encrypted disk (LUKS2: root and swap) | Laptop leaves the house | One passphrase at boot and at resume. |
| F6 | Test on the 2TB drive first; the 4TB Workstation is untouched until this spec's acceptance checks pass | The Workstation is the daily driver | Two installs of the same spec; the second must need no fixes. |
| F8 | **Backups follow 3-2-1**: local copy as plain files on the DAS (later a NAS), off-site copy encrypted (block-level) in the cloud | Data safety without lock-in to one target | Two tools, one trigger: the daily update routine (S2). Targets are configuration, so a NAS can replace the DAS. |
| F7 | Names: images `fedora-cosmic-frmwrk` / `-dsktp`; hosts `frmwrk` / `dsktp` | "cosmic-desktop" reads as the DE | The desktop (dsktp) is out of scope until the laptop has run 3–6 months. |

## 2. How to read the requirement tables

- **Lane**: where it is declared.
  - `image` = recipe (needs the kernel, systemd, `/dev`, or must exist before the user layer)
  - `flatpak` = GUI app
  - `box:<name>` = needs its own distro (IDE, toolchain, vendor stack)
  - `user` = installed into `$HOME` by the user layer (native installers, `uv`, npm prefix)
  - `dotfiles` = user config (chezmoi)
  - `data` = restored or synced, never installed
  - `manual` = a documented one-time step
- **When**: `day-1` blocks daily use · `week-1` needed soon · `later` nice to have.
- **State**:
  - `confirmed` = decided by you
  - `proposed: keep` / `proposed: drop` = recommendation from the evidence; becomes
    confirmed when you accept it
  - `question` = needs your answer (section 7)
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
| P5 | Firmware updates (fwupd / LVFS) | base image | week-1 | fwupd installed | proposed: keep | `fwupdmgr get-updates` |
| P6 | Fingerprint for login and sudo, enrolled at setup | image (`fprintd-pam`) + manual (`fprintd-enroll`) | week-1 | Goodix reader; `sudo` asks for the finger daily | confirmed | `sudo` and the COSMIC lock screen accept the finger |
| P7 | Ambient light / rotation (`iio-sensor-proxy`) | image | — | no sign of use | proposed: drop | — |
| P8 | Power profiles, thermal | base image | day-1 | tuned-ppd + thermald enabled | proposed: keep (base default) | `powerprofilesctl` |
| P9 | TPM2 unlock of LUKS (root and swap), **with a PIN** | image (dracut `tpm2-tss`) + manual (`systemd-cryptenroll --tpm2-device=auto --tpm2-with-pin=yes`) | week-1 | clevis-luks + clevis-pin-tpm2 installed on the Workstation | confirmed (PIN: question 1) | boot and resume ask for the short PIN; the passphrase still works as fallback |
| P10 | Printing (CUPS, network and Bluetooth printers) | base image | week-1 | cups enabled | confirmed | a test page prints |
| P11 | External monitor brightness (`ddcutil`, DDC/CI over i2c) | image (ddcutil + `i2c-dev` loaded) | later | installed | confirmed | `ddcutil detect` as the user lists the monitor |

### 3.2 Desktop and shell

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | COSMIC session starts on every login (no black screen) | image | day-1 | — | confirmed | 10 logins; `journalctl -t cosmic-session-wait` |
| D2 | Terminal: Ghostty | image | day-1 | RPM, autostarted at login | proposed: keep | opens from the launcher |
| D3 | bash + starship prompt | image + dotfiles | day-1 | starship in use (installed by hand) | proposed: keep | prompt renders |
| D4 | tmux | image | — | not in shell history | proposed: drop | — |
| D5 | topgrade (one command updates everything) | image | week-1 | 57 uses, top 5 command | proposed: keep | updates image, flatpaks, boxes |
| D6 | Default browser: Google Chrome; Firefox (base) as fallback | see A2 | day-1 | Chrome is the https/html handler and autostarts | proposed: keep | links open in Chrome |
| D7 | Window tiling | COSMIC built-in | day-1 | GNOME Tactile extension | proposed: COSMIC tiling replaces it | tile shortcuts work |
| D8 | PDF viewer | flatpak | day-1 | Evince is the PDF handler | proposed: keep (flatpak) | PDF opens |
| D9 | COSMIC settings (keybindings, panel, theme) | dotfiles | week-1 | — | proposed: keep | fresh login looks right |

### 3.3 Network and remote access

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| N1 | Network at first boot, or every first-boot job retries | image (retry drop-ins) | day-1 | first test install failed here | confirmed | flatpaks install without manual action |
| N2 | Wi-Fi profiles migrate (~20 saved networks) | manual (copy NM profiles) | day-1 | many saved profiles | proposed: keep | known networks connect |
| N3 | Tailscale: this machine's own node | image + manual | day-1 | in daily use | proposed: keep | `tailscale status` |
| N4 | Cisco VPN for work (AnyConnect protocol) | **1st** NetworkManager-openconnect (image) · **2nd** Cisco Secure Client in a rootful distrobox (`--root`, host network, `/dev/net/tun`) · **3rd** layered in the image | week-1 | Cisco Secure Client installed, service enabled, autostarts | confirmed (lane decided by test) | the work VPN connects and routes; posture checks (if the server requires them) pass |
| N5 | Windscribe VPN | **1st** Windscribe WireGuard/OpenVPN configs as NetworkManager profiles · **2nd** the Windscribe client in a rootful distrobox, like N4 | later | installed, helper service enabled | confirmed (lane: question 2) | connects; no DNS leak |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp: Documents, Music, Pictures, Videos, Downloads, Desktop, Public, Templates, Applications, VMs, Sync | image + dotfiles (user unit) | day-1 | 11 folders; started from an autostart entry today; one malformed folder entry (empty id, path `~`) to check | confirmed | folders Up to Date |
| S2a | Local backup to the DAS as **plain files**, versioned (hard-link snapshots, e.g. `rsync --link-dest`); readable without special tools | dotfiles (script + config) | week-1 | today: restic to the DAS, run by hand | confirmed (tool: question 3) | a file from yesterday's snapshot opens directly from the DAS |
| S2b | Off-site backup to the cloud, **encrypted and deduplicated** (restic or kopia) | dotfiles (script + config) | week-1 | none today | confirmed (provider: question 3) | `snapshots` lists today's; a test restore works |
| S2c | Trigger: the daily update routine runs the backup first, then updates (topgrade custom step); a timer catches days without the routine | dotfiles (topgrade config + user timer) | week-1 | the backup is tied to the daily update habit | confirmed | backup log shows a run within the last 26 h |
| S2d | Targets are configuration (DAS today, NAS later; cloud bucket); the existing restic repo on the DAS stays as a read-only archive for the migration | dotfiles | week-1 | — | confirmed | switching the local target is a one-line change |
| S3 | Non-synced data to carry over: `~/.ssh`, `~/.gnupg`, `~/.hermes`, `~/.claude*`, app configs as needed | data (restic, by hand) | day-1 | `~/.config` 27 GB and `~/.local` 77 GB are mostly app state and Python packages, not to be copied wholesale | proposed: keep (explicit list) | migration checklist |

### 3.5 Applications (GUI)

| ID | App | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| A1 | Claude Desktop | box:claude (Ubuntu) | day-1 | runs from a distrobox today | confirmed |
| A2 | Google Chrome (CAC capable) | box:dev (RPM) or flatpak | day-1 | default browser | proposed: keep; lane question (V3) |
| A3 | Firefox | image (base) | — | installed (base) | proposed: keep as fallback |
| A4 | VS Code | box:dev | day-1 | RPM from Microsoft repo | proposed: keep |
| A5 | Antigravity | box:dev | week-1 | RPM installed | proposed: keep |
| A6 | PyCharm | — | — | COPR repo enabled | confirmed: drop |
| A7 | GIMP, darktable | flatpak | later | RPMs installed | proposed: keep (later) |
| A8 | Calibre | flatpak | later | RPM installed | proposed: keep (later) |
| A9 | DaVinci Resolve | — | — | installed by hand | confirmed: drop (add back later if needed) |
| A10 | Xilinx / FPGA tools | — | — | in synced Applications | confirmed: drop |
| A11 | Notepad++ (and other small Windows apps) without the VM | flatpak (Bottles, one bottle per app, menu launcher) | week-1 | the most-used Wine app; a ~2 GB Wine prefix today | confirmed |
| A12 | RDP client (Remmina) | flatpak | later | freerdp + GNOME Connections installed | proposed: keep (later) |
| A13 | Flatseal, Gear Lever | flatpak | later | installed; AppImage folders are empty | proposed: Flatseal keep, Gear Lever drop |
| A14 | virt-manager | image | week-1 | follows V1 (replaces GNOME Boxes) | proposed: keep |
| A15 | Mail, calendar, contacts: Google, in Chrome (web apps) | A2 | day-1 | all Google via Chrome today | confirmed |
| A15b | Desktop calendar integration (Google calendar in the COSMIC panel, like GNOME Online Accounts today) | image (gnome-online-accounts + evolution-data-server) | later | COSMIC has no account integration of its own yet (pop-os/cosmic-epoch#2901); community applets read Evolution Data Server | question 4 |
| A16 | Office: **Collabora Office** (`com.collaboraoffice.Office`) instead of LibreOffice | flatpak | week-1 | preferred over plain LibreOffice | confirmed |
| A16b | Signal, VLC, Inkscape | flatpak | later | used now and then | confirmed |
| A17 | Steam | — | — | repo enabled, ~40 KB of data: never used | proposed: drop |
| A18 | Zotero, Zen browser | — | — | leftovers (no longer used) | confirmed: drop |

### 3.6 CLI tools

Evidence: Homebrew holds only three tools (chezmoi, cosign, lazydocker), so it does not
earn its own lane. Most-used CLI tools from shell history: docker (83), topgrade (57),
btop (47), lazydocker (30), git, nmap, ssh, fastfetch, gh, curl.

| ID | Tools | Lane | State |
| --- | --- | --- | --- |
| C1 | git, gh, btop, fastfetch, nmap, 7zip, chezmoi, topgrade, restic | image | proposed: keep |
| C2 | lazydocker (against the podman socket), cosign, bluebuild | user (single binaries via chezmoi externals into `~/.local/bin`) | proposed: keep |
| C3 | Homebrew | — | proposed: drop (three tools; move them to C1/C2) |

### 3.7 Development environments

| ID | Need | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| E1 | Claude Code CLI | box:claude (Ubuntu, beside Claude Desktop); **not** on the host | day-1 | a native host install exists today; host-native on Fedora is not the supported path | confirmed |
| E2 | Python data-science / ML (Jupyter, PyTorch, scikit-learn, Hugging Face, spaCy, Optuna) | user (`uv` venvs per project) or box:ml | week-1 | large `pip --user` stack, including CUDA wheels that do nothing on this AMD laptop | proposed: keep, per-project venvs, never `pip --user` |
| E3 | GPU compute (ROCm on the 780M) | box:rocm | later | mainly for dsktp; useful on the laptop | confirmed |
| E4 | Containers: **podman only** (base) + `podman-compose`; user `podman.socket` for Docker-API tools (lazydocker). No Docker Engine. | image | week-1 | Docker is the most-used command today; its workloads move to podman (migration M6) | confirmed | the Open WebUI stack and the Hermes sandbox run under podman |
| E5 | Hermes agent (gateway user service, sandbox container) | user + E4 | week-1 | 46 uses, 15 GB state, user unit enabled | proposed: keep |
| E6 | Other AI CLIs: Gemini CLI, OpenCode, browser-use | box:dev (Node, uv), bins exported to the host | later | installed on the host today | confirmed |
| E7 | Java (Temurin) | — | — | repo enabled | confirmed: drop |
| E8 | Build this image locally (bluebuild, podman, cosign) | image or box | week-1 | in use for this project | proposed: keep |
| E9 | General dev toolchain (Node, gcc, ShellCheck) | box:dev | week-1 | VS Code + Antigravity live there | proposed: keep (minimal) |

### 3.8 Virtualization and CAC

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| V1 | Win11 VM (virtio, Secure Boot + TPM in the guest), same disk as today | image + data | week-1 | defined; also an old Windows dev-eval VM and a Fedora COSMIC test VM | confirmed (Win11VM only; the other two proposed: drop) | boots, no BitLocker prompt |
| V2 | CAC reader passed into the Win11 VM | image (`win11-cac`) | week-1 | — | confirmed | `certutil -scinfo` in Windows |
| V3 | CAC on the host, in Chrome | image (pcscd, opensc) + A2 | week-1 | user NSS db exists; a smart-card setup script in use | proposed: keep | PIN prompt on a DoD site |

### 3.9 Identity and secrets (how they reach a new machine)

| ID | Item | Lane | State |
| --- | --- | --- | --- |
| I1 | SSH key for GitHub: one key per machine, added to GitHub at setup (the restored key was rejected on the test drive) | manual | proposed: keep |
| I2 | GPG keys, `gh` auth | data / manual | proposed: keep |
| I3 | Restic password, cosign key: in the password manager only (no plaintext copies) | manual | confirmed |
| I4 | Password manager: Google (in Chrome) | A2 | day-1 | all Google via Chrome | confirmed |

## 4. Install and lifecycle

| ID | Topic | Options | State |
| --- | --- | --- | --- |
| L1 | Install path | **Stock Fedora COSMIC Atomic ISO** (Anaconda), then `bootc switch` to the signed image. Anaconda custom partitioning: ESP, ext4 /boot, LUKS2 swap ≥ RAM, LUKS2 btrfs root, one passphrase. First `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (unverified), reboot, then `sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` (the signing policy ships in the image; `docs/local-build.md`). Then check kargs (`rd.luks.uuid` for swap, `resume=`); `enable-hibernation.sh` adds what is missing. Secure Boot off after install (F2). Retires `install-atomic.sh`, `prepare-disk.sh`, `make-target-env.sh`, `install-to-disk.sh`. | **confirmed** 2026-10-03 |
| L2 | Updates: staged automatically, applied at a reboot you choose | `bootc-fetch-apply-updates` drop-in (exists) | candidate |
| L3 | Rollback: previous deployment in the GRUB menu | built in | confirmed |
| L4 | Rescue: the retired test drive as a bootable spare | — | candidate |

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

Answered 2026-10-03: VPNs, containers, Claude Code CLI, vendor apps, Windows apps, Google
services, office and media apps, hardware extras, GPU compute and AI CLIs, backups.
Remaining:

1. **TPM2 unlock with a PIN (P9)?** Secure Boot is off (F2), so a TPM-only unlock would
   release the disk to anyone who boots the laptop. A PIN keeps the protection and is
   much shorter than the passphrase. Recommended: PIN.
2. **Windscribe (N5):** NetworkManager profiles from Windscribe's config generator (no
   app, simplest), or the Windscribe app in a rootful distrobox (keeps its features)?
3. **Backups (S2):** local tool: `rsync` hard-link snapshots (recommended: any target,
   plain files) or btrfs send/receive (the DAS is btrfs; a NAS might not be). Cloud: which
   provider, and restic (recommended: already in use) or kopia?
4. **Desktop calendar (A15b):** layer GNOME Online Accounts + Evolution Data Server now,
   or Google Calendar in Chrome only until COSMIC ships account integration?
5. **Accept the remaining `proposed` rows as they stand?** (P5, P7, P8, D2–D9, N2, N3,
   S3, A2–A5, A7, A8, A12–A14, A17, C1–C3, E2, E5, E8, E9, V1's two old VMs, V3, I1, I2,
   L2, L4.) Say which to change; the rest become confirmed.

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
