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
| F4 | Fedora 44 Atomic, **custom image** built with BlueBuild, signed, on public GHCR. **Nightly build in GitHub Actions** (free for public repositories); local builds to test a change before pushing | Reproducible system, rebuilt daily on the newest base; failures happen in CI, not on the laptop; laptop and dsktp get the same declared system; `/usr` changes (login workaround, DoD roots) need an image | Nothing personal in the image or this repo (`check-leaks.sh`); personal values in `site.env`, private `/etc` files and the private dotfiles repo. The signing key lives in the repo's Actions secrets. **Revisit** (stock image + a few layered packages) only if the layered set shrinks to libvirt + Tailscale **and** upstream COSMIC fixes the login bug. |
| F5 | Encrypted disk (LUKS2: root and swap) | Laptop leaves the house | One passphrase at boot and at resume. |
| F6 | Test on the 2TB drive first; the 4TB Workstation is untouched until this spec's acceptance checks pass | The Workstation is the daily driver | Two installs of the same spec; the second must need no fixes. |
| F8 | **Backups follow 3-2-1**: local copy as plain files on the DAS (later a NAS), off-site copy encrypted (block-level) in the cloud | Data safety without lock-in to one target | Two tools, one trigger: the daily update routine (S2). Targets are configuration, so a NAS can replace the DAS. |
| F9 | **Base image as close to stock as possible.** An RPM is layered only when it needs the host kernel or a host service, when the root nightly job (J1) runs it (root must never execute files the user can write), or when it belongs to the virtualization stack, which is layered **whole, as Bluefin DX does** (V1, A14); configuration files are fine. CLI tools come from **Homebrew** (C1), shipped as files by the BlueBuild `brew` module, not as an RPM. Everything else is a flatpak or a distrobox | Fewer layered packages: smaller image, fewer update conflicts, closer to what Fedora and Universal Blue test | Layered: the virtualization stack incl. virt-manager, virt-viewer and SPICE USB redirection (V1), Tailscale (N3), restic and distrobox (J1), the CAC stack pcsc-lite/CCID/OpenSC (V3, already in the base) and, during the VPN trial, NetworkManager-openconnect (N4). Not layered: Ghostty, starship, topgrade, chezmoi, Syncthing, `openssl`, other NetworkManager VPN plugins. |
| F7 | Names: images `fedora-cosmic-frmwrk` / `-dsktp`; hosts `frmwrk` / `dsktp` | "cosmic-desktop" reads as the DE | The desktop (dsktp) is out of scope until the laptop has run 3–6 months. |

## 2. How to read the requirement tables

- **Lane**: where it is declared.
  - `image` = recipe (needs the kernel, systemd, `/dev`, or must exist before the user layer)
  - `flatpak` = GUI app
  - `box:<name>` = a distrobox: `dev` (Fedora, rootless, daily work), `claude` (Ubuntu), `rocm`, `vpn` (rootful, see N4)
  - `brew` = a Homebrew formula in `~/.Brewfile` (dotfiles), installed by the user layer with `brew bundle`; Homebrew itself ships in the image (C1)
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
| P11 | External monitor brightness (DDC/CI) | image: i2c udev rule + `i2c-dev` module-load (config files); `ddcutil` from brew (the uaccess rule works for any binary) | later | installed | confirmed | `ddcutil detect` lists the monitor |

### 3.2 Desktop and shell

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | COSMIC session starts on every login (no black screen) | image | day-1 | — | confirmed | 10 logins; `journalctl -t cosmic-session-wait` |
| D2 | Terminal: **Ghostty in box:dev** (COPR inside the box, exported to the menu; opens a shell in `dev`, where daily work happens). COSMIC Terminal (stock) for host administration | box:dev | day-1 | Ghostty autostarted daily; no official flatpak | confirmed | Ghostty opens from the launcher into `dev`; COSMIC Terminal opens a host shell |
| D3 | bash + starship prompt | brew + dotfiles | day-1 | starship in use | confirmed | prompt renders on the host and in boxes |
| D4 | tmux | — | — | not in shell history | drop | — |
| D5 | topgrade for a manual update run (the nightly job J1 does the scheduled one) | brew + dotfiles | later | 57 uses | confirmed | `topgrade` updates image (staged), flatpaks, boxes |
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
| N4 | Cisco VPN for work (AnyConnect) — **trial of two methods, keep the one that works and suits the workflow**: (a) **NetworkManager-openconnect** layered (F9 exception for the trial), connected from COSMIC's network menu or `nmcli --ask connection up`; (b) **Cisco Secure Client in box:vpn**, a rootful distrobox (Ubuntu 24.04 with systemd), its window/tray icon exported. Boxes share the host network, so either way the tunnel reaches the host, `dev`, `claude` and podman containers. The method not chosen leaves the image or the box | image (trial) + box:vpn | week-1 | Cisco Secure Client installed, service enabled, autostarts | trial | per method: connects; the posture check (if the server runs one) passes; routes and DNS work from the host, `dev` (Chrome, Ghostty) and a podman container (Hermes); COSMIC's menu shows state (a) and can log in, incl. SSO if used |
| N6 | Work-internal names over the VPN, including a `.local` one | — | — | the `.local` name moves to a real domain soon (work IT) | postponed: revisit only if the move does not happen | — |
| N5 | Windscribe: **native WireGuard profiles in NetworkManager** (built in, no plugin; in COSMIC's network menu) **and** the Windscribe app in box:vpn — both kept for the trial; decide after use | NetworkManager config + box:vpn | later | installed, helper service enabled | trial | connects both ways; no DNS leak |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp: Documents, Music, Pictures, Videos, Downloads, Desktop, Public, Templates, Applications, VMs, Sync | brew (binary) + dotfiles (user unit) | day-1 | 11 folders; started from an autostart entry today; one malformed folder entry (empty id, path `~`) to fix | confirmed | folders Up to Date |
| S2a | Local backup to the DAS as **plain files**: `rsync --link-dest` hard-link snapshots (unchanged files cost no space; restore = copy from a dated folder). Keep 7 daily, 4 weekly, 12 monthly. VM disk images are copied separately, only when changed and the VM is off, last 2 kept. Skipped (and reported) when the DAS is not attached | image (J1) + private config | week-1 | today: restic to the DAS, run by hand | confirmed | a file from yesterday's snapshot opens directly from the DAS |
| S2b | Off-site: **restic to Backblaze B2**, encrypted on the laptop before upload; same scope (S2d) and retention. VM disks uploaded under the same rule as S2a (VM off, disk changed). The laptop's B2 key cannot delete; the bucket keeps hidden versions 30 days; `forget --prune` only with a separate admin key; monthly `restic check --read-data-subset=5%` | image (J1) + private config | week-1 | none today (an off-site design from 2026-10-01 was postponed until now) | confirmed | `restic snapshots` lists today's; a single file and a whole folder restore from B2 |
| S2c | Trigger: the nightly job (J1); an hourly catch-up repeats a copy that is older than 24 h as soon as its target is reachable (R1) | image (J1) | week-1 | — | confirmed | J1's report shows a backup within the last 26 h |
| S2d | Scope: all of `$HOME` (dotfiles and Downloads included; minus `~/.cache`, Trash and container image layers — container **volumes** are included); **all of `/etc`**; **`/var` state** — everything in `/var` except `/var/home` (backed up as `$HOME`), caches, `/var/tmp`, logs, installed flatpaks, container image layers and the VM disks (S2a/S2b) — so Bluetooth pairings, fingerprints, libvirt NVRAM and swtpm, rootful container volumes, `/var/roothome`, `/usr/local` and `/opt` come back; the machine manifest (R1). Targets are configuration in a private `/etc` file (DAS → NAS later; B2 bucket and keys). The old restic repo on the DAS stays read-only for the migration | image (J1) + private config | week-1 | home ≈ 750 GB + VM disks | confirmed | a VM restores from backup and boots; a Bluetooth device pairs again without re-pairing after a restore |
| S2e | **Local snapshots on the laptop:** a read-only btrfs snapshot of `/var/home` every hour, the last 48 kept in `/var/home/.snapshots/` (you can open your own files there without sudo). Covers deletions and mistakes between nightly runs and away from the DAS; not a backup (same disk). The nightly backups also read from a fresh read-only snapshot, so both copies hold your files as they were at one instant. Needs `/var/home` to be its own btrfs subvolume (checked at install, L1); otherwise the backups read the live files | image (J1 + catch-up timer) | week-1 | — | confirmed | a file deleted an hour ago opens from `/var/home/.snapshots/<date_hour>/`; J1's log says "backing up from …/.cosmic-nightly-source" |
| R1 | **Restore point within a day.** A restore or rebuild returns to the previous day's state; at worst one day of work or configuration drift is lost. Each night J1 first writes a **machine manifest** (booted image digest, kernel arguments, layered packages, `/etc` changes, enabled units, flatpaks with origin and branch, Homebrew versions, the packages in every box, disk layout), then backs up S2d. Restore rules: `docs/restore.md`. Not covered: files a vendor installer put inside a box beyond what N4's `vpn` box keeps outside it (installers in `$HOME`, Cisco profiles in `/var/lib/vpn-box/`), and a VM disk while its VM keeps running (copied the first night it is off; V5) | image (J1) + private config | week-1 | today: home only, restored by allowlist | confirmed | J1's report: restore point < 26 h; a test restore brings back yesterday's `/etc` file, a Bluetooth pairing and a box's package list |
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
| A14 | virt-manager and virt-viewer | image (RPMs, the whole stack as in Bluefin DX). Not the flatpak: SPICE click-to-redirect of USB devices is the daily CAC path (V2) and does not work reliably from the sandbox | day-1 | follows V1; used daily | confirmed |
| A15 | Mail, calendar, contacts: Google, in Chrome only; nothing from GNOME on COSMIC | A2 | day-1 | all Google via Chrome today | confirmed |
| A16 | Office: **Collabora Office** (`com.collaboraoffice.Office`) instead of LibreOffice | flatpak | week-1 | preferred over plain LibreOffice | confirmed |
| A16b | Signal, VLC, Inkscape | flatpak | later | used now and then | confirmed |
| A17 | Steam | — | — | ~40 KB of data: never used | drop |
| A18 | Zotero, Zen browser | — | — | leftovers | drop |

### 3.6 CLI tools

Homebrew is the CLI lane, as on Universal Blue (decided 2026-10-03, reversing the earlier
drop): one declarative `~/.Brewfile`, upgraded by J1 as the user, visible on the host and
in every box through `/home`. Earlier evidence: Homebrew held only three tools. Most-used CLI tools from shell history: docker (83), topgrade (57),
btop (47), lazydocker (30), git, nmap, ssh, fastfetch, gh, curl.

| ID | Tools | Lane | State |
| --- | --- | --- | --- |
| C1 | chezmoi, starship, topgrade, gh, btop, fastfetch, syncthing, uv, lazydocker (against the user podman socket), cosign, sevenzip, ddcutil, podman-compose | brew | confirmed |
| C1a | restic, distrobox | image (run as root by J1; the user uses the same copies) | confirmed |
| C1b | git | base image if present, else box:dev | confirmed |
| C1c | nmap (raw scans need root; brew binaries never run under sudo) | box:dev | confirmed |
| C2 | Claude Code CLI | box:claude (E1); the official `claude-code` cask supports Linux if it ever moves to brew | confirmed |
| C3 | Homebrew itself | image (BlueBuild `brew` module: unpacked to `/home/linuxbrew` at first boot, offline; analytics off; its update timers off, J1 upgrades) | confirmed |

### 3.7 Development environments

| ID | Need | Lane | When | Evidence | State |
| --- | --- | --- | --- | --- | --- |
| E1 | Claude Code CLI, exported with `distrobox-export` | box:claude (Ubuntu, beside Claude Desktop); **not** on the host | day-1 | a native host install exists today | confirmed |
| E2 | Python data-science / ML (Jupyter, PyTorch, scikit-learn, Hugging Face, spaCy, Optuna): `uv` (brew) projects in `$HOME` for CPU work, box:rocm for GPU; never `pip --user` | user + box:rocm | week-1 | large `pip --user` stack incl. useless CUDA wheels | confirmed |
| E3 | GPU compute (ROCm on the 780M) | box:rocm | later | mainly for dsktp; useful on the laptop | confirmed |
| E4 | Containers: **podman only** (base); `podman-compose` (brew); user `podman.socket` for Docker-API tools. No Docker Engine | base + brew | week-1 | Docker workloads migrate (M6) | confirmed | the Open WebUI stack and the Hermes sandbox run under podman |
| E5 | Hermes agent (gateway user service, sandbox in podman); reaches the work VPN (N4 check) | user + E4 | week-1 | 46 uses, 15 GB state | confirmed |
| E6 | Other AI CLIs: Gemini CLI, OpenCode, browser-use | box:dev (Node, uv), bins exported to the host | later | installed on the host today | confirmed |
| E7 | Java (Temurin) | — | — | repo enabled | drop |
| E8 | Image builds: nightly in GitHub Actions; local test builds with the BlueBuild CLI container + podman + cosign | CI + user | week-1 | in use | confirmed |
| E9 | General dev toolchain (Node, uv, gcc, ShellCheck), AI CLIs (E6) | box:dev | week-1 | VS Code + Antigravity live there | confirmed |

### 3.8 Virtualization and CAC

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| V1 | Win11 VM (virtio, Secure Boot + TPM in the guest), same disk as today | image (the whole virtualization stack, A14; libvirt group for wheel members and an SELinux relabel of `/var/lib/libvirt` at boot, as Bluefin DX) + migration (M7) | week-1 | the old Windows dev-eval VM and the Fedora COSMIC test VM are dropped | confirmed | boots, no BitLocker prompt |
| V2 | **CAC in the Win11 VM (must):** the reader is passed into the VM; the Windows app that needs the VM also needs the card. **Daily path: SPICE click-to-redirect** of the reader in virt-manager / virt-viewer (needs `qemu-device-usb-redirect` and the SPICE USB ACL helper, both in the image). Fallback without a SPICE window: `sudo win11-cac attach` (host-side hostdev) | image (virtualization stack, `win11-cac`) | day-1 | SPICE redirection in daily use on the Workstation | confirmed | redirect the reader from the VM window → `certutil -scinfo` lists the card → the Windows app signs in with the card → un-redirect returns it to the host; the same with `win11-cac attach`/`detach` |
| V3 | **CAC on the host (must), in two browsers:** (a) **Chrome in box:dev** — opensc in the box reaches the host's `pcscd` through the socket; DoD certs and the OpenSC module in `~/.pki/nssdb`, set up by the user layer with a timeout; (b) **Firefox (base)** — OpenSC through p11-kit (Fedora's Firefox loads it), DoD roots from the system trust (V4). If the 2TB test shows OpenSC missing in Firefox, the image adds a Firefox enterprise policy (`SecurityDevices`); not shipped by default, to avoid the card appearing twice | image + box:dev + dotfiles | day-1 | user NSS db and a smart-card script in use today | confirmed | PIN prompt and successful login on a DoD site in Chrome **and** in Firefox; `cac-status` |
| V4 | **DoD PKI roots baked into the image** at build time: the public DoD bundle is downloaded and verified against a pinned root in CI, the roots go into the system trust (`/usr/share/pki/ca-trust-source/anchors`); the nightly build keeps them current | image (build step) | day-1 | today: fetched at runtime by `setup-cac.sh --system` (needed network and the `openssl` CLI) | confirmed | `trust list` shows the DoD roots on a fresh install with no network |
| V5 | **A running VM is backed up too:** when the Win11 VM has been running through a night, J1 takes a consistent copy of its disk while it runs (`virsh backup-begin`, push mode) instead of waiting for a night it is off | image (J1) | later | multi-day sessions keep the VM up | confirmed: build after M7, against the real VM | the report shows a disk copy dated last night while the VM was running; that copy boots |

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
| L2 | Updates: the nightly job (J1) runs `bootc upgrade` without `--apply`: the new image is **staged** and applies at the next reboot you choose. **Nothing ever reboots the machine automatically.** J1 is the only updater (the old stage-only timer retires) | image (J1) | confirmed |
| L3 | Rollback: previous deployment in the GRUB menu | built in | confirmed |
| J1 | **One nightly job** (systemd timer, ~04:30, after the CI build; `Persistent=true` so a run missed during sleep or hibernation happens at the next wake; idle CPU/IO priority): **0** machine manifest (R1) → **1** backup (S2a if the DAS is attached, S2b if online) → **2** drift report (O1) → **3** upgrades: `bootc upgrade` staged (never `--apply`, never reboots), flatpaks, Homebrew (as the user), distroboxes (incl. the rootful `vpn`), firmware metadata → **4** report: a desktop notification at the next login and a log, failures first, with the age of the restore point. Runs as a system service; user-level steps run as the user. Each step runs even if an earlier one failed, and the report says which. An hourly catch-up timer runs steps 0–1 only, and only when a copy is older than 24 h and its target is reachable (R1); one run at a time | image (script + timers) + private config | week-1 | today: backup and updates by hand | confirmed | after a night: the report lists backup, drift and upgrade results; `bootc status` shows a staged image; uptime unchanged |
| O1 | Drift report: what is on the machine that the spec and the dotfiles do not declare — `/etc` changes against the image (`ostree admin config-diff`), packages layered by hand (`rpm-ostree status`), flatpaks outside the list, Homebrew formulae missing from or not in `~/.Brewfile`, boxes: packages added or removed since each box was created from `distrobox.ini` (a baseline recorded at creation), and on the 1st of each month every rootless box without such changes and not in use is rebuilt from `distrobox.ini` (proves the manifest still builds it; the `vpn` box is never rebuilt), `chezmoi status`, enabled units. Prints only differences | image (J1 step 2) | week-1 | design agreed in principle 2026-10-01 | confirmed | a hand-made change (e.g. an `/etc` edit) appears in the next report |
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

## 5a. Migration (one-time, layer 3)

The checklist lives in the private dotfiles repo (`.migration-prep/MIGRATION.md`): it is
one-time and full of personal details, while this repo keeps what is reused (image, spec,
install and recovery docs). It has two parts: **on the Workstation first** (export the
Docker volumes while Docker exists, record the Cisco facts and how the internal names
resolve, copy the Notepad++ settings, last backup), then **on the laptop** (Wi-Fi
profiles, keys, Syncthing and Tailscale identities, data outside Syncthing, Docker →
podman, the Win11 VM, Bottles, fingerprint and TPM2+PIN enrollment, the VPNs, backups).
Each item has a check; the rules of section 5 apply.

## 6. Acceptance checklist

Generated from the Check columns once the tables are confirmed.

## 7. Open questions

1. **N4/N5 VPN method:** decided after the trial on the 2TB (results in the journal); the
   losing method is removed.

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
- 2026-10-03: D2 confirmed (Ghostty in box:dev). N4: Cisco Secure Client and the
  Windscribe app in a rootful box:vpn; COSMIC's network menu drives only NetworkManager
  connections, so Windscribe's WireGuard profiles appear there and Cisco does not. N6 added
  (internal and `.local` names over the VPN). B2 key model added to S2b. Migration checklist
  moved to the dotfiles repo. O1 (drift report) carried over from 2026-10-01 as a proposal.
- 2026-10-03: VPN trial: NetworkManager-openconnect layered (F9 exception while the trial
  runs), Cisco Secure Client and the Windscribe app in box:vpn, Windscribe also as native
  NetworkManager WireGuard; keep what works. N6 postponed (the `.local` name moves to a
  real domain). Rebuild plan added (`docs/rebuild-plan.md`).
- 2026-10-03: custom image kept (F4, with a revisit condition). One nightly job (J1):
  backup, drift report (O1, confirmed), staged upgrades; never reboots. CAC is a must in
  three places: Win11 VM (V2), Chrome in box:dev and base Firefox (V3); DoD roots baked
  into the image (V4).
- 2026-10-03: restic and distrobox are layered after all (J1 runs them as root, and root
  must never execute user-writable files); Firefox gets OpenSC through p11-kit, the
  enterprise policy only if the test shows it missing. Implementation: PR #7.
- 2026-10-03: R1 added: a restore or rebuild returns to the previous day's state. Backup scope (S2d) now all of `/etc` and the state in `/var`; a nightly machine manifest; VM disks off-site under the same rule as the local copy; an hourly catch-up keeps the restore point within a day.
- 2026-10-03: the whole virtualization stack is layered like Bluefin DX, incl. virt-manager and virt-viewer (A14): SPICE click-to-redirect is the daily CAC path into the VM (V2), and the flatpak cannot do it reliably. Homebrew becomes the CLI lane (C1–C3, reversing the earlier drop); J1 upgrades it as the user, O1 and R1 cover it.
- 2026-10-03: approved from the design review: S2e (hourly read-only snapshots of `/var/home`; nightly backups read from a snapshot), O1 box drift against a creation baseline plus a monthly rebuild, V5 (live VM backup, built after M7), the `vpn` box keeps installers and Cisco profiles where the backups reach them (R1).
