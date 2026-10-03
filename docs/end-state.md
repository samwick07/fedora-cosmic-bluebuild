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
| P6 | Fingerprint for login and sudo | image (`fprintd-pam`) | week-1 | Goodix reader; `sudo` asks for the finger daily | confirmed | `sudo` prompts for the finger |
| P7 | Ambient light / rotation (`iio-sensor-proxy`) | image | — | no sign of use | proposed: drop | — |
| P8 | Power profiles, thermal | base image | day-1 | tuned-ppd + thermald enabled | proposed: keep (base default) | `powerprofilesctl` |
| P9 | TPM2 unlock of LUKS (clevis) | image + manual | ? | clevis-luks + clevis-pin-tpm2 installed | question | — |
| P10 | Printing (CUPS) | base image | later | cups enabled; no sign of use | question | — |
| P11 | External monitor brightness (`ddcutil`) | image | later | installed | question | — |

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
| N4 | Cisco Secure Client VPN (AnyConnect) | ? | ? | installed, service enabled, autostarts | question | — |
| N5 | Windscribe VPN | ? | ? | installed, helper service enabled | question | — |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp: Documents, Music, Pictures, Videos, Downloads, Desktop, Public, Templates, Applications, VMs, Sync | image + dotfiles (user unit) | day-1 | 11 folders; started from an autostart entry today; one malformed folder entry (empty id, path `~`) to check | confirmed | folders Up to Date |
| S2 | restic backup of this machine to the DAS | dotfiles (script + timer?) | week-1 | run by hand from a script on the DAS | question: schedule | `restic snapshots --host frmwrk` |
| S3 | Non-synced data to carry over: `~/.ssh`, `~/.gnupg`, `~/.hermes`, `~/.claude*`, app configs as needed | data (restic, by hand) | day-1 | `~/.config` 27 GB and `~/.local` 77 GB are mostly app state and Python packages, not to be copied wholesale | proposed: keep (explicit list) | migration checklist |

### 3.5 Applications (GUI)

| ID | App | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| A1 | Claude Desktop | box:claude (Ubuntu) | day-1 | runs from a distrobox today | confirmed |
| A2 | Google Chrome (CAC capable) | box:dev (RPM) or flatpak | day-1 | default browser | proposed: keep; lane question (V3) |
| A3 | Firefox | image (base) | — | installed (base) | proposed: keep as fallback |
| A4 | VS Code | box:dev | day-1 | RPM from Microsoft repo | proposed: keep |
| A5 | Antigravity | box:dev | week-1 | RPM installed | proposed: keep |
| A6 | PyCharm | box:dev | ? | COPR repo enabled | question |
| A7 | GIMP, darktable | flatpak | later | RPMs installed | proposed: keep (later) |
| A8 | Calibre | flatpak | later | RPM installed | proposed: keep (later) |
| A9 | DaVinci Resolve | box (vendor) | ? | installed by hand, helper COPR | question |
| A10 | Xilinx / FPGA tools | box (vendor) | ? | in synced Applications | question |
| A11 | Windows apps via Wine / Bottles | flatpak (Bottles) | later | a Wine prefix (~2 GB), `.exe` installers kept | question |
| A12 | RDP client (Remmina) | flatpak | later | freerdp + GNOME Connections installed | proposed: keep (later) |
| A13 | Flatseal, Gear Lever | flatpak | later | installed; AppImage folders are empty | proposed: Flatseal keep, Gear Lever drop |
| A14 | virt-manager | image | week-1 | follows V1 (replaces GNOME Boxes) | proposed: keep |
| A15 | Email/calendar (Evolution EWS) | ? | ? | evolution-ews installed | question |
| A16 | LibreOffice, Signal, VLC, Inkscape | flatpak | ? | not visible (inventory list truncated) | question |
| A17 | Steam | — | — | repo enabled, ~40 KB of data: never used | proposed: drop |
| A18 | Zotero, Zen browser | — | — | leftovers (no longer used) | confirmed: drop |

### 3.6 CLI tools

Evidence: Homebrew holds only three tools (chezmoi, cosign, lazydocker), so it does not
earn its own lane. Most-used CLI tools from shell history: docker (83), topgrade (57),
btop (47), lazydocker (30), git, nmap, ssh, fastfetch, gh, curl.

| ID | Tools | Lane | State |
| --- | --- | --- | --- |
| C1 | git, gh, btop, fastfetch, nmap, 7zip, chezmoi, topgrade, restic | image | proposed: keep |
| C2 | lazydocker, cosign, bluebuild | follows E4 / E8 | proposed: keep |
| C3 | Homebrew | — | proposed: drop (three tools; move them to C1/C2) |

### 3.7 Development environments

| ID | Need | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| E1 | Claude Code CLI | box:claude, or host native installer into `$HOME` | day-1 | used; a native host install exists alongside the box | question: box or host |
| E2 | Python data-science / ML (Jupyter, PyTorch, scikit-learn, Hugging Face, spaCy, Optuna) | user (`uv` venvs per project) or box:ml | week-1 | large `pip --user` stack, including CUDA wheels that do nothing on this AMD laptop | proposed: keep, per-project venvs, never `pip --user` |
| E3 | GPU compute (ROCm on the 780M) | box:rocm | later | tried a few times | question |
| E4 | Containers: Docker workloads (Open WebUI + SearXNG + Tailscale sidecar compose stack; Hermes sandbox; buildx for BlueBuild) | image: Docker Engine, or podman + compose | week-1 | docker is the most-used command (83), lazydocker 30, `./start.sh` 47 | proposed: keep; engine question |
| E5 | Hermes agent (gateway user service, sandbox container) | user + E4 | week-1 | 46 uses, 15 GB state, user unit enabled | proposed: keep |
| E6 | Other AI CLIs: Gemini CLI, OpenCode, browser-use, cua-driver | user | later | installed; little use in history | question |
| E7 | Java (Temurin) | box:dev | ? | repo enabled | question |
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
| I4 | Password manager on the laptop (which one, which lane?) | ? | question |

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
   restored file to start. Order inside it is explicit: e.g. the Brewfile exists before
   `brew bundle` runs.
3. **Migration** is a one-time **checklist**, not a script inside the image: data, VM
   disk, identities (Syncthing, Tailscale, SSH). Each item has its own check, and nothing
   is marked done until its check passes.
4. Each layer is tested alone, in this order: image (on the 2TB), then user layer (on that
   bare image), then migration.
5. Acceptance = every **Check** in section 3 passes on the 2TB; then the same on the 4TB
   with no changes.

## 6. Acceptance checklist

Generated from the Check columns once the tables are confirmed.

## 7. Open questions

From the Workstation inventory; each needs a yes/no or a choice:

1. **VPNs:** Cisco Secure Client (N4) and Windscribe (N5): still needed on the laptop?
   For Cisco, does NetworkManager's OpenConnect (AnyConnect protocol) work with that
   server, or is the vendor client required?
2. **Containers (E4):** Docker Engine layered in the image, or podman with a Docker-compatible
   socket + compose? Does the Hermes sandbox require Docker?
3. **Claude Code CLI (E1):** in the `claude` box with Claude Desktop, or host-native in `$HOME`?
4. **Vendor apps:** DaVinci Resolve (A9), Xilinx tools (A10), PyCharm (A6), Java (E7): still used?
5. **Windows apps (A11):** which ones run under Wine today; do they need Bottles or the VM?
6. **Email/calendar (A15)** and **password manager (I4):** which apps?
7. **Not visible in the truncated package list:** LibreOffice, Signal, VLC, Inkscape (A16).
8. **Hardware extras:** TPM2 LUKS unlock (P9), printing (P10), monitor brightness (P11).
9. **GPU compute (E3)** and **other AI CLIs (E6):** needed on the laptop?
10. **Backup schedule (S2):** by hand as today, or a timer?

## Change log

- 2026-10-03: draft after the first test run; F1 (COSMIC) and F2 (hibernation) confirmed
  as hard requirements; L1 confirmed: stock ISO + `bootc switch`.
- 2026-10-03: Workstation inventory added as evidence; candidates turned into proposals
  and questions; Homebrew lane proposed for removal; Zotero and Zen dropped.
