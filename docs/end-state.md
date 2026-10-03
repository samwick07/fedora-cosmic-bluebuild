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
  - `brew` = a CLI binary you type
  - `box:<name>` = needs its own distro (IDE, toolchain, vendor stack)
  - `dotfiles` = user config (chezmoi)
  - `data` = restored or synced, never installed
  - `manual` = a documented one-time step
- **When**:
  - `day-1` = blocks daily use
  - `week-1` = needed soon
  - `later` = nice to have
  - `drop` = decided against
- **State**:
  - `confirmed` = decided
  - `candidate` = carried over from the old plan or the Workstation; keep, change or drop it
- **Check**: the acceptance test. Section 6 collects them.

## 3. Requirements

### 3.1 Platform and hardware

| ID | Need | Lane | When | State | Check |
| --- | --- | --- | --- | --- | --- |
| P1 | Boots to a LUKS prompt, then the COSMIC greeter, unattended | image + install | day-1 | confirmed | cold boot ×3 |
| P2 | Hibernation per F2 | image + install | day-1 | confirmed | `systemctl hibernate` → resume; lid closed 5 min → hibernates |
| P3 | Suspend on lid close (s2idle), Bluetooth works after resume | image | day-1 | confirmed | lid close/open; BT device reconnects |
| P4 | Wi-Fi, Bluetooth, audio, webcam, both USB-C displays | base image | day-1 | confirmed | manual pass |
| P5 | Firmware updates (fwupd / LVFS) | base image | week-1 | candidate | `fwupdmgr get-updates` |
| P6 | Fingerprint login and sudo (`fprintd`) | image | week-1 | confirmed (in daily use for sudo on the Workstation) | `sudo` prompts for the finger |
| P7 | Ambient light / auto brightness (`iio-sensor-proxy`) | image | later | candidate | — does COSMIC use it? |
| P8 | Power profiles / battery charge limit | base image | week-1 | candidate | `powerprofilesctl` |

### 3.2 Desktop and shell

| ID | Need | Lane | When | State | Check |
| --- | --- | --- | --- | --- | --- |
| D1 | COSMIC session starts on every login (no black screen) | image | day-1 | confirmed | 10 logins, `journalctl -t cosmic-session-wait` |
| D2 | Terminal: Ghostty | image | day-1 | candidate | — or COSMIC Terminal? |
| D3 | Shell: bash + starship prompt, tmux | image + dotfiles | day-1 | candidate | |
| D4 | Default browser (which, and is CAC required in it? see V3) | ? | day-1 | candidate | |
| D5 | COSMIC settings (keybindings, panels, theme) in dotfiles | dotfiles | week-1 | candidate | fresh login looks right |

### 3.3 Network and remote access

| ID | Need | Lane | When | State | Check |
| --- | --- | --- | --- | --- | --- |
| N1 | Wi-Fi profiles available at first boot (a network-free first boot broke flatpak setup) | manual / data | day-1 | confirmed | first boot has network, or every first-boot job retries |
| N2 | Tailscale: this machine's own node | image + manual | week-1 | candidate | `tailscale status` |
| N3 | VPN: OpenVPN / OpenConnect profiles (which sites?) | image + data | ? | candidate | |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | State | Check |
| --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp, folders as today; hardware-specific config not synced | image + dotfiles | day-1 | confirmed | folders Up to Date; edits on both sides are safe |
| S2 | restic backup of this machine to the DAS, on a schedule or by hand? | image + dotfiles | week-1 | confirmed (schedule TBD) | `restic snapshots --host frmwrk` |
| S3 | Which data is restored from restic at migration (vs. arrives by Syncthing) | data | day-1 | candidate | migration checklist (section 5) |

### 3.5 Applications (GUI)

Candidates from the old plan; mark keep, drop or later.

| ID | App | Lane | State |
| --- | --- | --- | --- |
| A1 | Claude Desktop, in an Ubuntu distrobox until an RPM/flatpak exists | box:claude | confirmed |
| A2 | Firefox (base RPM) | image (base) | candidate |
| A3 | Google Chrome (RPM in the dev box, CAC capable) | box:dev | candidate |
| A4 | VS Code, Antigravity | box:dev | candidate |
| A5 | LibreOffice | flatpak | candidate |
| A6 | Signal | flatpak | candidate |
| A7 | VLC | flatpak | candidate |
| A8 | GIMP, Inkscape, Darktable | flatpak | candidate |
| A9 | Calibre | flatpak | candidate |
| A10 | Steam | flatpak | candidate |
| A11 | Bottles (Windows apps) | flatpak | candidate |
| A12 | Remmina (RDP/VNC) | flatpak | candidate |
| A13 | Flatseal, Gear Lever (AppImages) | flatpak | candidate |
| A14 | virt-manager | image | follows V1 |

### 3.6 CLI tools

Candidates (Brewfile of the old plan): eza bat fd ripgrep fzf zoxide jq yq btop fastfetch
micro superfile gh uv shellcheck shfmt lazydocker opencode tesseract ocrmypdf nmap mtr.
Image candidates: git, restic, chezmoi, age, topgrade, gdisk, smartmontools, lm_sensors.
**To decide:** the list, and whether Homebrew earns its own lane, or the handful in daily
use go into the image and the rest into the dev box.

### 3.7 Development environments

| ID | Need | Lane | When | State |
| --- | --- | --- | --- | --- |
| E1 | Claude Code CLI next to Claude Desktop | box:claude | day-1 | confirmed |
| E2 | General dev toolchain (Node 22, Java 25, Python, gcc, ShellCheck) | box:dev | ? | candidate: which languages are actually used? |
| E3 | ROCm compute on the 780M | box:rocm | later | candidate: used for what? |
| E4 | Containers: podman (base); Docker workloads (Open WebUI, SearXNG) | ? | ? | candidate: still wanted on the laptop? |
| E5 | Hermes agent | ? | ? | candidate |

### 3.8 Virtualization and CAC

| ID | Need | Lane | When | State | Check |
| --- | --- | --- | --- | --- | --- |
| V1 | Win11 VM (virtio, Secure Boot + TPM in the guest), same disk as today | image + data | week-1 | confirmed | boots, no BitLocker prompt |
| V2 | CAC reader passed into the Win11 VM | image (`win11-cac`) | week-1 | confirmed | `certutil -scinfo` in Windows |
| V3 | CAC on the host (which browser, which sites?) | image + box/flatpak | ? | candidate | PIN prompt on a DoD site |

### 3.9 Identity and secrets (how they reach a new machine)

| ID | Item | Lane | State |
| --- | --- | --- | --- |
| I1 | SSH key for GitHub (the restored key was rejected; a new key per machine?) | manual | to decide |
| I2 | GPG keys, `gh` auth, password manager | manual / data | to decide |
| I3 | Restic password, cosign key: in the password manager only (no plaintext copies) | manual | confirmed |

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

Answered from the Workstation inventory and by you:

- Which apps and CLI tools are used weekly? (D2–D4, 3.5, 3.6)
- Which dev languages and stacks? Docker workloads on the laptop at all? (E2–E5)
- Host CAC: needed, in which browser? (V3)
- VPN profiles still in use? (N3)
- Fingerprint, ambient light? (P6, P7)
- SSH and identity policy for a new machine (I1, I2)

## Change log

- 2026-10-03: draft after the first test run; F1 (COSMIC) and F2 (hibernation) confirmed
  as hard requirements; L1 confirmed: stock ISO + `bootc switch`.
