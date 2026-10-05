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
| F8 | **Backups follow 3-2-1**: local copy as plain files on the DAS (later a NAS), off-site copy encrypted (block-level) in the cloud | Data safety without lock-in to one target | Two tools, one trigger: the daily update routine (S2). Targets are configuration, so a NAS can replace the DAS. **The DAS stays an ordinary data disk** (it holds other things too). What this project does on it: the old restic repository is a stale backup — never written, read during the migration, deleted only after the migration is complete and the new backups have proven themselves (M11, M12, a month of good nightly reports; MIGRATION part C). New writes go only to `migration/` (W1, W4) and `frmwrk-snapshots/` (J1). It stays encrypted at rest (it will hold `/etc/shadow`, Wi-Fi keys, the B2 key) on a file system with hard links and xattrs (ext4, XFS, btrfs). |
| F9 | **Base image as close to stock as possible.** An RPM is layered only when it needs the host kernel or a host service, when the root nightly job (J1) runs it (root must never execute files the user can write), or when it belongs to the virtualization stack, which is layered **whole, as Bluefin DX does** (V1, A14); configuration files are fine. CLI tools come from **Homebrew** (C1), shipped as files by the BlueBuild `brew` module, not as an RPM. Everything else is a flatpak or a distrobox | Fewer layered packages: smaller image, fewer update conflicts, closer to what Fedora and Universal Blue test | Layered: the virtualization stack incl. virt-manager, virt-viewer and SPICE USB redirection (V1), Tailscale (N3), restic and distrobox (J1), the CAC stack pcsc-lite/CCID/OpenSC (V3, already in the base) and, during the VPN trial, NetworkManager-openconnect (N4). Not layered: Ghostty, starship, topgrade, chezmoi, Syncthing, `openssl`, other NetworkManager VPN plugins. |
| F7 | **The machine name is the key everywhere:** `frmwrk` (laptop), `dsktp` (desktop) = hostname = BlueBuild recipe `recipe-<name>.yml` = image `fedora-cosmic-<name>` = the image's `VARIANT_ID` = the dotfiles' `.machine`. **One dotfiles repo for both**: per-machine values in `.chezmoidata/machines.yaml`, per-machine files via `.chezmoiignore`, the one-time migration in `.migration-prep/<name>/` | "cosmic-desktop" read as the DE; most of the user layer is shared, so a second repo would only duplicate it and drift | The desktop (dsktp) is out of scope until the laptop has run 3–6 months; when it comes: a spec section for its differences, its recipe, its `machines.yaml` entry, its migration folder. |
| F10 | **Software comes from its publisher, at its latest version, never from a copy on a disk.** Each package is fetched from where its maker hosts it (repository, registry, release page, stable download URL) when it is installed and again when it updates; no installer is carried over from the Workstation. What carries over is data and settings | A kept installer ages, and nobody remembers where it came from | **One noted exception: Cisco Secure Client** (N4). Cisco publishes it only behind a login and work IT cannot provide a download (2026-10-03), so the web-deploy installer the Workstation holds (`cisco-secure-client-linux64-<version>-core-vpn-webdeploy-k9.sh`, from the work VPN portal) is kept, privately, on the DAS and on the laptop (never in this repo or the image). It only bootstraps: the headend upgrades the client on connect. The exception ends when a download from Cisco or work IT exists. |
| F11 | **The spec decides lanes and capabilities; the declaration files hold the lists.** Adding another formula to the Brewfile, a package to a box's `additional_packages` or an app to `flatpaks.list` needs a reason in the drift ledger (O2), not a new row. A row is needed only for what fits no existing row: a new box, lane, host service or capability | Keeps the spec about decisions, and keeps adopting a CLI tool down to one sentence | The drift ledger (`.drift/ledger.toml`, dotfiles) is the record of why each list entry exists; `docs/drift-engine.md` |

## 2. How to read the requirement tables

- **Lane**: where it is declared.
  - `image` = recipe (needs the kernel, systemd, `/dev`, or must exist before the user layer)
  - `flatpak` = GUI app
  - `box:<name>` = a distrobox (the declared set; boxes for a single project come later, declared with that project): `dev` (Fedora, rootless, daily work), `claude` (Ubuntu, rootless), `rocm` (rootless, GPU compute) — all three from the dotfiles — and `net` (rootful: VPN clients and network tools that need real root; created by the image, N4)
  - `brew` = a Homebrew formula in `~/.config/homebrew/Brewfile` (dotfiles, D10), installed by the user layer with `brew bundle`; Homebrew itself ships in the image (C1)
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
| P1 | Boots to a LUKS prompt, then the COSMIC greeter, unattended | image + install | day-1 | — | confirmed | 3 boots in the journal, each with the LUKS volumes unlocked and the greeter started (evidence, L5) |
| P2 | Hibernation per F2 | image + install | day-1 | Workstation runs this way today: Secure Boot off, 96 GB LUKS swap partition | confirmed | a hibernate → resume (`cosmic-acceptance --exercise` does one by RTC alarm); a lid close that went on to hibernate; 10 suspend cycles, battery drain per cycle (journal + `cosmic-evidence-sleep`, L5) |
| P3 | Suspend on lid close (s2idle); Bluetooth after resume | image | day-1 | s2idle | confirmed | a lid close → suspend → resume in the journal; a Bluetooth device connected before a suspend is connected again 45 s after resume (`cosmic-evidence-sleep`) |
| P4 | Wi-Fi (MediaTek), Bluetooth, audio, webcam, USB-C displays | base image | day-1 | devices present | confirmed | Wi-Fi connected once; Bluetooth controller powered; an audio sink that is not the dummy; the webcam answers a capture query; an external display connected and enabled once (checked live, remembered once seen) |
| P5 | Firmware updates (fwupd / LVFS) | base image | week-1 | fwupd installed | confirmed | `fwupdmgr get-updates` answers (no error); applying firmware stays your choice (it reboots) |
| P6 | Fingerprint for login and sudo, enrolled at setup | image (`fprintd`, `fprintd-pam`) + `sudo cosmic-enroll` (the finger is physical input; it also turns on authselect's `with-fingerprint`) | week-1 | Goodix reader; `sudo` asks for the finger daily | confirmed | `sudo` and the COSMIC lock screen accept the finger |
| P7 | Ambient light / rotation (`iio-sensor-proxy`) | — | — | no sign of use | drop | — |
| P8 | Power profiles, thermal | base image | day-1 | tuned-ppd + thermald enabled | confirmed | `powerprofilesctl` switches profiles (`--exercise`) |
| P9 | TPM2 unlock of LUKS (root and swap) **with a PIN** | image (dracut `tpm2-tss`) + `sudo cosmic-enroll`: enrols every LUKS device in `/etc/crypttab` with `--tpm2-device=auto --tpm2-with-pin=yes` and adds `rd.luks.options=tpm2-device=auto` (the passphrase and the PIN are typed) | week-1 | clevis-luks + clevis-pin-tpm2 installed on the Workstation | confirmed | boot and resume ask for the short PIN; the passphrase still works |
| P10 | Printing (CUPS, network and Bluetooth printers) | base image | week-1 | cups enabled | confirmed | a print job completed (CUPS history; `--exercise` prints one test page if none has) |
| P11 | External monitor brightness (DDC/CI) | image: i2c udev rule + `i2c-dev` module-load (config files); `ddcutil` from brew (the uaccess rule works for any binary) | later | installed | confirmed | `ddcutil detect` (as the user) lists the external monitor while one is connected |

### 3.2 Desktop and shell

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| D1 | COSMIC session starts on every login (no black screen) | image | day-1 | — | confirmed | 10 logins logged by `cosmic-session-wait` (it logs every login), none timed out, no `Backend initialized without output` from cosmic-comp |
| D2 | Terminal: **Ghostty in box:dev** (COPR inside the box, exported to the menu; opens a shell in `dev`, where daily work happens). COSMIC Terminal (stock) for host administration | box:dev | day-1 | Ghostty autostarted daily; no official flatpak | confirmed | Ghostty opens from the launcher into `dev`; COSMIC Terminal opens a host shell |
| D3 | bash + starship prompt | brew + dotfiles | day-1 | starship in use | confirmed | prompt renders on the host and in boxes |
| D4 | tmux | — | — | not in shell history | drop | — |
| D5 | topgrade for a manual update run (the nightly job J1 does the scheduled one) | brew + dotfiles | later | 57 uses | confirmed | `topgrade` updates image (staged), flatpaks, boxes |
| D6 | Default browser: Google Chrome (box:dev); Firefox (base) as fallback | A2 | day-1 | Chrome is the https/html handler | confirmed | links open in Chrome |
| D7 | Window tiling | COSMIC built-in | day-1 | GNOME Tactile extension | confirmed | COSMIC's default shortcuts include the tiling toggle |
| D8 | PDF viewer: Chrome's built-in viewer; a flatpak only if annotation is missed | A2 | day-1 | Evince is the PDF handler | confirmed | a PDF opens |
| D9 | COSMIC settings (keybindings, panel, theme) | dotfiles | week-1 | — | confirmed | fresh login looks right |
| D10 | **A tidy home:** what the dotfiles manage lives under `~/.config` and `~/.local` (XDG) wherever the tool allows it: git → `~/.config/git/config`, the Brewfile → `~/.config/homebrew/Brewfile`, bash history → `~/.local/state/bash/history`. Only what a tool hardcodes stays in `~` itself, and it is accepted rather than fought: `.bashrc` and `.bash_profile` (bash), `.ssh` (OpenSSH), `.gnupg` (a non-default `GNUPGHOME` moves gpg-agent's sockets), `.pki` (Chrome/NSS; V3 depends on it), `.var` (Flatpak), and app state such as `.claude*` and `.hermes` | dotfiles | week-1 | home root before the refactor: `.bashrc`, `.bash_profile`, `.gitconfig`, `.Brewfile`, `.bash_history` | confirmed | `chezmoi managed` lists nothing in `~` itself except `.bashrc` and `.bash_profile`; an interactive shell's `HISTFILE` is `~/.local/state/bash/history` |

### 3.3 Network and remote access

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| N1 | Network at first boot, or every first-boot job retries | image (retry drop-ins) | day-1 | first test install failed here | confirmed | flatpaks install without manual action |
| N2 | Wi-Fi profiles migrate (~20 saved networks) | migration (M1) | day-1 | many saved profiles | confirmed | known networks connect |
| N3 | Tailscale: this machine's own node | image (needs the host daemon; F9 exception) + manual | day-1 | in daily use | confirmed | `tailscale status` |
| N4 | Cisco VPN for work (AnyConnect) — **trial of two methods, keep the one that works and suits the workflow**: (a) **NetworkManager-openconnect** layered (F9 exception for the trial), connected from COSMIC's network menu or `nmcli --ask connection up`; (b) **Cisco Secure Client in box:net**, a rootful distrobox (Ubuntu 24.04 with systemd) that the image creates on its own (`cosmic-net-box.service`); installed there from the **kept web-deploy installer** (the F10 exception) in the root-only `/var/lib/net-box/installers/`, run once per installer file inside the box (it writes `/usr` and its own systemd unit, which the read-only host does not allow), never on the host or in the public image (proprietary). The migration puts it there (W2 copies it from the Workstation's Downloads to the DAS, M10 to the laptop); the nightly backups keep it (`/var` state, S2d). Once installed, the headend upgrades the client and pushes its profile on connect. Launchers appear in the app menu. Risk: one report of the client failing in a rootful distrobox (distrobox #1536, IPC error, unresolved); method (a) is the fallback. Boxes share the host network, so either way the tunnel reaches the host, `dev`, `claude` and podman containers. The method not chosen leaves the image or the box | image (trial) + box:net | week-1 | Cisco Secure Client installed, service enabled, autostarts | trial | per method: connects (the login is yours); then automatically, whenever a tunnel comes up (`cosmic-evidence-tunnel@`): routes and DNS from the host, `dev` and a podman container are recorded; the posture check (if the server runs one) passes; COSMIC's menu shows state (a) |
| N6 | Work-internal names over the VPN, including a `.local` one | — | — | the `.local` name moves to a real domain soon (work IT) | postponed: revisit only if the move does not happen | — |
| N5 | Windscribe: **native WireGuard profiles in NetworkManager** (built in, no plugin; in COSMIC's network menu) **and** the Windscribe app in box:net (the image fetches the vendor's `.deb` from its stable download URL and refreshes it nightly) — both kept for the trial; decide after use | NetworkManager config + box:net | later | installed, helper service enabled | trial | connects both ways; the tunnel record shows the DNS servers in use (no leak) |

### 3.4 Data, sync, backup

| ID | Need | Lane | When | Evidence | State | Check |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | Syncthing with dsktp: Documents, Music, Pictures, Videos, Downloads, Desktop, Public, Templates, Applications, VMs, Sync | brew (binary) + dotfiles (user unit) | day-1 | 11 folders; started from an autostart entry today; one malformed folder entry (empty id, path `~`) to fix | confirmed | folders Up to Date |
| S2a | Local backup to the DAS as **plain files**: `rsync --link-dest` hard-link snapshots (unchanged files cost no space; restore = copy from a dated folder). Keep 7 daily, 4 weekly, 12 monthly. VM disk images are copied separately, only when changed and the VM is off, last 2 kept. Skipped (and reported) when the DAS is not attached | image (J1) + private config | week-1 | today: restic to the DAS, run by hand | confirmed | a file from yesterday's snapshot opens directly from the DAS |
| S2b | Off-site: **restic to Backblaze B2**, encrypted on the laptop before upload; same scope (S2d) and retention. VM disks uploaded under the same rule as S2a (VM off, disk changed). The laptop's B2 key cannot delete; the bucket keeps hidden versions 30 days; `forget --prune` only with a separate admin key; monthly `restic check --read-data-subset=5%` | image (J1) + private config | week-1 | none today (an off-site design from 2026-10-01 was postponed until now) | confirmed | `restic snapshots` lists today's; J1's daily restore probe: one random home file and the manifest come back identical from the DAS and from B2 (`restic dump`) |
| S2c | Trigger: the nightly job (J1); an hourly catch-up repeats a copy that is older than 24 h as soon as its target is reachable (R1) | image (J1) | week-1 | — | confirmed | J1's report shows a backup within the last 26 h |
| S2d | Scope: all of `$HOME` (dotfiles and Downloads included; minus `~/.cache`, Trash and container image layers — container **volumes** are included); **all of `/etc`**; **`/var` state** — everything in `/var` except `/var/home` (backed up as `$HOME`), caches, `/var/tmp`, logs, installed flatpaks, container image layers and the VM disks (S2a/S2b) — so Bluetooth pairings, fingerprints, libvirt NVRAM and swtpm, rootful container volumes, `/var/roothome`, `/usr/local` and `/opt` come back; the machine manifest (R1). Targets are configuration in a private `/etc` file (DAS → NAS later; B2 bucket and keys). The old restic repo on the DAS stays read-only for the migration | image (J1) + private config | week-1 | home ≈ 750 GB + VM disks | confirmed | a VM restores from backup and boots; a Bluetooth device pairs again without re-pairing after a restore |
| S2e | **One local snapshot a day:** the nightly job takes a read-only btrfs snapshot of `/var/home` (`/var/home/.snapshots/<date>`, the last 7 kept; you can open your own files there without sudo) and both backups read from it, so they hold your files as they were at one instant. Covers mistakes between backups and away from the DAS; not a backup (same disk). Needs `/var/home` to be its own btrfs subvolume (L1); otherwise the backups read the live files | image (J1) | week-1 | — | confirmed | yesterday's version of a file opens from `/var/home/.snapshots/<date>/`; J1's log says "backing up from …/.snapshots/<date>" |
| S2f | **One off-site repository for every machine.** frmwrk and dsktp back up into the **same** restic repository in the B2 bucket (a generic path, never a machine name); snapshots are told apart by host (F7) and tag (`nightly`, `vm-disk`, `win-disk`). restic deduplicates by content across the whole repository, so what Syncthing keeps identical on both machines (S1) is stored and paid for once. Each machine has its own restic key (`restic key add` on the shared repository, never a second `init`) and its own B2 application key that cannot delete; the admin key prunes per host and tag. Syncthing's `.stversions/` folders are excluded on both machines (restic's own history covers them). Decided before the first upload: two repositories cannot be merged later without uploading everything again | image (J1) + private config | week-1 | frmwrk home ≈ 750 GB, most of it in folders synced with dsktp | proposed | `restic snapshots` lists both hosts in one repository; the first backup of the second machine reports "Added to the repository" far below its scanned size (the synced folders are already there) |
| S2g | **dsktp's off-site copy starts now, before its migration** (interim; retired when dsktp runs its own image, whose J1 takes over S2f and S2h). A root systemd timer on dsktp's current Fedora Workstation, installed once with `sudo` from the private dotfiles (`.migration-prep/dsktp/`), runs nightly with `Persistent=true` (a night spent in Windows or asleep runs at the next Linux boot): restic to the S2f repository, `--host dsktp --tag nightly`, scope as S2d where it applies to a Workstation (`$HOME` with the same excludes, `/etc`, `/var/lib/libvirt` without disk images), then S2h. Its first run initialises the shared repository; frmwrk joins at M11. Pruning as S2b (admin key, by hand) | manual (one install) + dotfiles (private) | day-1 | dsktp has no off-site copy today; its migration is months away (after frmwrk has proven itself) | proposed | `restic snapshots --host dsktp --tag nightly` shows one younger than 26 h whenever Linux ran that day; monthly `restic check --read-data-subset=5%` clean |
| S2h | **dsktp's physical Windows drive comes back whole and bootable.** Its work applications cannot be reinstalled from their vendors (no F10 path), so the disk is backed up as an image, not as files. Taken from Linux while Windows is not running, nightly after S2g: the partition table (`sfdisk -d`), the small partitions (ESP, MSR, recovery) raw, and the Windows partition with `ntfsclone --save-image` (used clusters only), each streamed into restic (`--stdin-from-command`, `--host dsktp --tag win-disk`); an unchanged region costs nothing, so a night with no Windows use adds almost nothing. Kept 7 daily + 4 weekly. **If the Windows partition is BitLocker-encrypted**, ntfsclone cannot read it: that partition goes raw instead (the whole partition is uploaded once, later nights only the blocks that changed), and the BitLocker recovery key is in the password manager (I3). Set once in Windows: Fast Startup off (a hibernated volume is not consistent and ntfsclone refuses it) and the page file cleared at shutdown (`ClearPageFileAtShutdown`; otherwise its churn is uploaded every night) | dotfiles (private, with S2g); later the dsktp image's J1 | day-1 | booted daily; work-specific Windows applications | proposed | quarterly rehearsal: the newest `win-disk` snapshot is restored to a sparse file and boots to the Windows sign-in in a throwaway VM with networking off; nightly: a `win-disk` snapshot from every night Linux ran |
| R1 | **Restore point within a day.** A restore or rebuild returns to the previous day's state; at worst one day of work or configuration drift is lost. Each night J1 first writes a **machine manifest** (booted image digest, kernel arguments, layered packages, `/etc` changes, enabled units, flatpaks with origin and branch, Homebrew versions, the packages in every box, disk layout), then backs up S2d. Restore rules: `docs/restore.md`. Not covered: what a vendor package put inside a box (the `net` box is rebuilt from its manifest, Windscribe's current `.deb` and the kept Cisco installer, F10; the Cisco headend upgrades the client and pushes its profile on connect), and a VM disk while its VM keeps running (copied the first night it is off — accepted: a file copy of a shut-down VM is enough) | image (J1) + private config | week-1 | today: home only, restored by allowlist | confirmed | J1's report: restore point < 26 h; a test restore brings back yesterday's `/etc` file, a Bluetooth pairing and a box's package list |
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
| A14 | virt-manager and virt-viewer | image (RPMs, the whole stack as in Bluefin DX). Not the flatpak: SPICE click-to-redirect of USB devices is the required CAC fallback (V2) and does not work reliably from the sandbox | day-1 | follows V1; used daily | confirmed |
| A15 | Mail, calendar, contacts: Google, in Chrome only; nothing from GNOME on COSMIC | A2 | day-1 | all Google via Chrome today | confirmed |
| A16 | Office: **Collabora Office** (`com.collaboraoffice.Office`) instead of LibreOffice | flatpak | week-1 | preferred over plain LibreOffice | confirmed |
| A16b | Signal, VLC, Inkscape | flatpak | later | used now and then | confirmed |
| A17 | Steam | — | — | ~40 KB of data: never used | drop |
| A18 | Zotero, Zen browser | — | — | leftovers | drop |

### 3.6 CLI tools

Homebrew is the CLI lane, as on Universal Blue (decided 2026-10-03, reversing the earlier
drop): one declarative Brewfile (`~/.config/homebrew/Brewfile`, D10), upgraded by J1 as the user, visible on the host and
in every box through `/home`. Earlier evidence: Homebrew held only three tools. Most-used CLI tools from shell history: docker (83), topgrade (57),
btop (47), lazydocker (30), git, nmap, ssh, fastfetch, gh, curl.

| ID | Tools | Lane | State |
| --- | --- | --- | --- |
| C1 | chezmoi, starship, topgrade, gh, btop, fastfetch, syncthing, uv, lazydocker (against the user podman socket), cosign, sevenzip, ddcutil, podman-compose | brew | confirmed |
| C1a | restic, distrobox | image (run as root by J1; the user uses the same copies) | confirmed |
| C1b | git | base image if present, else box:dev | confirmed |
| C1c | nmap, mtr, tcpdump (raw sockets on the host network need real root: a rootless box cannot have it, and brew binaries never run under sudo) | box:net, with root-owned wrappers in `/usr/local/bin` that run them there (`sudo` once) | confirmed |
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
| V2 | **CAC in the Win11 VM (must):** the reader is passed into the VM; the Windows app that needs the VM also needs the card. **Default: `sudo win11-cac attach`** (host-side hostdev; stops host pcscd while attached) and `detach`. **Fallback that must also work: SPICE click-to-redirect** of the reader in virt-manager / virt-viewer (needs `qemu-device-usb-redirect` and the SPICE USB ACL helper, both in the image) | image (virtualization stack, `win11-cac`) | day-1 | SPICE redirection in daily use on the Workstation | confirmed | `cosmic-acceptance --exercise`: `win11-cac attach` → the guest sees the reader (guest agent `certutil -scinfo`, else QEMU's USB list) → `detach` → the host's pcscd sees it again; then the same through SPICE (`virt-viewer --spice-usbredir-redirect-on-connect` for class 0x0b, then closed). Yours: the Windows app signs in with the card (PIN) |
| V3 | **CAC on the host (must), in two browsers:** (a) **Chrome in box:dev** — opensc in the box reaches the host's `pcscd` through the socket; DoD certs and the OpenSC module in `~/.pki/nssdb`, set up by the user layer with a timeout; (b) **Firefox (base)** — OpenSC through p11-kit (Fedora's Firefox loads it), DoD roots from the system trust (V4). If the 2TB test shows OpenSC missing in Firefox, the image adds a Firefox enterprise policy (`SecurityDevices`); not shipped by default, to avoid the card appearing twice | image + box:dev + dotfiles | day-1 | user NSS db and a smart-card script in use today | confirmed | automatic up to the PIN: the card's certificates are readable through p11-kit (Firefox's path) and through OpenSC in `dev` (Chrome's path), `cac-status`. Yours: a DoD site login in each browser (PIN) |
| V4 | **DoD PKI roots baked into the image** at build time: the public DoD bundle is downloaded and verified against a pinned root in CI, the roots go into the system trust (`/usr/share/pki/ca-trust-source/anchors`); the nightly build keeps them current | image (build step) | day-1 | today: fetched at runtime by `setup-cac.sh --system` (needed network and the `openssl` CLI) | confirmed | `trust list` shows the DoD roots on a fresh install with no network |
| V6 | **The Win11 VM disk stays cheap to back up** (S2a, S2b upload only what changed): the system disk is attached with `discard='unmap'` so blocks Windows frees become holes instead of stale data, and Windows retrims it rather than defragmenting; the disk file is never rewritten in bulk (`qemu-img convert`, compaction, internal snapshots), which would make restic see most of it as new | migration (M7, the domain XML) | week-1 | disk in `/var/lib/libvirt/images`, 512 GB virtual | proposed | `virsh dumpxml Win11VM` shows `discard='unmap'` on the system disk; J1's `vm-disk` upload after an ordinary week of use is a small fraction of the disk's allocated size |

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
| L1 | Install path | **Stock Fedora COSMIC Atomic ISO driven by this repo's kickstart** (`install/frmwrk.ks`, `docs/install.md`): add `inst.ks=<raw URL> cosmic.disk=<name in /dev/disk/by-id>` to the boot line. The kickstart declares the partitioning (ESP, ext4 `/boot`, LUKS2 swap ≥ RAM, LUKS2 btrfs with `/` and `/home` subvolumes, S2e) on that one disk and refuses a disk holding a protected LUKS volume (hashes of the 4TB's and the DAS's UUIDs); it installs the image directly (`ostreecontainer`). Typed at install: the LUKS passphrase, the user. At first boot the image finishes alone: `cosmic-signed-origin.service` moves the origin to `ostree-image-signed` (every later update verified), `cosmic-hibernation.service` adds `resume=` and `rd.luks.uuid` (both staged; one reboot applies them). Physical: Secure Boot off in the firmware (F2). Fallback without the kickstart: Anaconda's custom partitioning by hand, then `bootc switch`; the same first-boot services finish it. Retires `install-atomic.sh`, `prepare-disk.sh`, `make-target-env.sh`, `install-to-disk.sh`. | **confirmed** 2026-10-03 |
| L2 | Updates: the nightly job (J1) runs `bootc upgrade` without `--apply`: the new image is **staged** and applies at the next reboot you choose. **Nothing ever reboots the machine automatically.** J1 is the only updater (the old stage-only timer retires) | image (J1) | confirmed |
| L3 | Rollback: previous deployment in the GRUB menu, or `sudo bootc rollback`. Known-good is pinned automatically: when acceptance is complete (J1 runs it daily) and no deployment is pinned, the booted one is pinned; a newer deployment that has stayed complete for 7 days replaces the pin. `sudo cosmic-acceptance --pin` pins the booted one by hand. A dated image tag or digest can be switched to as well (`docs/restore.md`) | image | confirmed |
| J1 | **One nightly job** (systemd timer, ~04:30, after the CI build; `Persistent=true` so a run missed during sleep or hibernation happens at the next wake; idle CPU/IO priority): **0** machine manifest (R1) → **1** backup (S2a if the DAS is attached, S2b if online) and a restore probe (one file back from each copy, compared) → **2** drift report (O1) → **3** upgrades: `bootc upgrade` staged (never `--apply`, never reboots; the download size is recorded, L6), flatpaks, Homebrew (as the user), distroboxes (incl. the rootful `net` and its vendor apps), firmware metadata → **4** acceptance (`cosmic-acceptance --record`, L5; pins known-good, L3) → **5** report: a desktop notification at the next login and a log, failures first, with the age of the restore point. Runs as a system service; user-level steps run as the user. Each step runs even if an earlier one failed, and the report says which. An hourly catch-up timer runs the manifest and the backups only, and only when a copy is older than 24 h and its target is reachable (R1); one run at a time | image (script + timers) + private config | week-1 | today: backup and updates by hand | confirmed | after a night: the report lists backup, drift and upgrade results; `bootc status` shows a staged image; uptime unchanged |
| O1 | Drift report: what is on the machine that the spec and the dotfiles do not declare — `/etc` changes against the image (`ostree admin config-diff`), packages layered by hand (`rpm-ostree status`), flatpaks outside the list, Homebrew formulae missing from or not in the Brewfile, boxes: packages added or removed since each box was created from `distrobox.ini` (a baseline recorded at creation), and on the 1st of each month every rootless box without such changes and not in use is rebuilt from `distrobox.ini` (proves the manifest still builds it; the rootful `net` box is never rebuilt), `chezmoi status`, enabled units. Prints only differences | image (J1 step 2) | week-1 | design agreed in principle 2026-10-01 | confirmed | a hand-made change (e.g. an `/etc` edit) appears in the next report |
| O2 | **Drift engine (`cosmic-drift`)**, replacing O1's report: every difference between the machine and its declarations becomes an item that needs a verdict — **adopt** (the engine edits the declaration and commits it with the reason), **revert**, **except** (reason + expiry, ≤ 365 days) or **propose** (a leak-checked issue for the image, or a saved draft). Every verdict takes a key and a typed reason, and applies to this machine unless widened. Detected by the nightly scan (the authority, including the rootful `net` box) and, while you remember, by watchers: dnf5/apt hooks in the rootless boxes and a shell prompt hook (no command is wrapped). Reasons live in the dotfiles' ledger and in commit trailers; daily snapshots kept 90 days, watcher events 12 months. Design: `docs/drift-engine.md` | image (`cosmic-drift`, J1 step 2) + dotfiles (prompt hook, box hooks, ledger) | later (sprints after the 2TB user layer) | O1 reports but records no intent | confirmed | acceptance: PASS with nothing open; WAIT inside the 3-day grace; FAIL for an undecided, expired or unknown item older than 3 days, a draft older than 7 days, an adoption not applied after 1 day, or an unreadable ledger (stops the L3 pin from advancing) |
| L4 | **Warm spare:** the 2TB stays in the DAS enclosure and is refreshed **weekly** from the primary (4TB): the same image deployed onto it, plus home, `/etc` (minus install-specific files) and `/var` state from the latest daily snapshot; so it is about a week behind and boots as a working laptop. It is booted only when the primary is lost, or for the quarterly rehearsal with networking off (it carries the primary's Tailscale and Syncthing identities). Unlocked for the refresh with a keyfile kept on the primary (root only). Built after the 4TB install, against the real spare | image (J1 weekly step) + private config | confirmed |
| L5 | Acceptance on the machine, with nothing to tick by hand: `sudo cosmic-acceptance` checks live state and **evidence** — the journal (boots, logins, sleeps), records written by the image as things happen (`cosmic-evidence-sleep.service` around every sleep: battery energy, Bluetooth devices; `cosmic-evidence-tunnel@` when a VPN tunnel comes up: routes, DNS), CUPS history, J1's restore probe. Each check says PASS, FAIL, WAIT (evidence still to come from normal use, and what produces it) or YOU (a secret only you can type). Evidence once seen is remembered (`/var/lib/cosmic-acceptance/`). `--user` adds the user layer; `--exercise` runs the active trials once with you present (suspend and hibernate by RTC alarm, a power-profile switch, one test page, the CAC into the VM both ways, every GUI app started for a few seconds); J1 runs the checks daily (`--record`) and reports regressions. The CI smoke test checks the image as a container; this checks the installed machine | image (`/usr/bin/cosmic-acceptance`, `cosmic-evidence`) | confirmed |
| L6 | Download size: J1 records the size `bootc upgrade` fetched each night (`/var/lib/cosmic-nightly/download-size.log`, shown by `cosmic-acceptance`); if a day's update is most of the image, turn on rechunking in CI (`--rechunk`) | J1 + CI (later) | confirmed |

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

The checklist lives in the private dotfiles repo (`.migration-prep/frmwrk/MIGRATION.md`, run by `migrate.sh` beside it): it is
one-time and full of personal details, while this repo keeps what is reused (image, spec,
install and recovery docs). It has two parts: **on the Workstation first** (export the
Docker volumes while Docker exists, record the Cisco facts and how the internal names
resolve, copy the Notepad++ settings, last backup), then **on the laptop** (Wi-Fi
profiles, keys, Syncthing and Tailscale identities, data outside Syncthing, Docker →
podman, the Win11 VM, Bottles, fingerprint and TPM2+PIN enrollment, the VPNs, backups).
Each item has a check; the rules of section 5 apply.

## 6. Acceptance checklist

A layer is done when its checks pass, in this order, first on the 2TB and then on the 4TB
with no changes. Nothing is ticked by hand (L5): `sudo cosmic-acceptance` reads live state
and the evidence the machine records as it is used, and J1 runs it every night. The row's
Check column is the definition.

- **auto** — live state, checked on every run.
- **evidence** — appears with normal use and is remembered once seen; until then the check
  says WAIT and what produces it (a reboot, closing the lid, plugging in the monitor).
- **exercise** — `sudo cosmic-acceptance --exercise`, once, with you present: it suspends and
  hibernates the machine (RTC alarm; press the power button if the firmware cannot wake from
  hibernation), switches power profiles, prints one test page, passes the CAC into the VM
  both ways, starts every GUI app for a few seconds.
- **yours** — a secret only you can type; everything up to it is automatic.

| Layer | auto | evidence | exercise | yours |
| --- | --- | --- | --- | --- |
| Image (fresh install, nothing restored) | L1 signed origin, first-boot services · F2 Secure Boot off · P2 lockdown none, kargs, swap ≥ RAM, lid → suspend-then-hibernate, SELinux module · P1 `rhgb quiet` · S2e `/var/home` subvolume · J1 timers, dry run · L2 no second updater · N1 flatpaks · N3 Tailscale · V1 libvirt sockets, group, virt-manager, SPICE USB redirection · V3/V4 pcscd, DoD roots · C1 Homebrew unpacked · C1c wrappers · N4 net box · P4 devices · P5 fwupd · P8 power profiles · P9/P6 enrolled (after `cosmic-enroll`) · D7 tiling | P1 3 boots · P2 a lid close that hibernated, 10 suspends, drain · P3 Bluetooth back after resume · P4 Wi-Fi, external display · P10 a completed print job · P11 `ddcutil detect` · D1 10 logins | P2 hibernate/resume · P3 suspend/resume · P8 profile switch · P10 test page | P6/P9 `sudo cosmic-enroll` (finger, PIN) |
| User layer (`chezmoi init --apply` on that image) | C1 Brewfile satisfied · D9 `chezmoi status` empty · D10 nothing managed in `~` itself but bash's two files, history in `~/.local/state` · E9 boxes exist · S1 Syncthing enabled · V3 OpenSC in Chrome's NSS db · D2 Ghostty exported from `dev`, COSMIC Terminal · D3 starship on the host and in `dev` · D6 Chrome is the default browser · A-rows present · E2 `uv` runs a project · E3 ROCm sees the GPU in `rocm` | — | A-rows: each GUI app starts | — |
| Migration (`MIGRATION.md`, `migrate.sh` checks each step) | N2 · N3 · S1 · S3 · E4/E5 · V1 · S2 first backups · R1 restore test (M12) · S2 restore probe (nightly) | N4/N5 tunnel records (routes, DNS from host, `dev`, a container) | V2 CAC by `win11-cac` and by SPICE | V2 the Windows app signs in (PIN) · V3 a DoD site login in Chrome and Firefox (PIN) · N4/N5 the VPN logins; which method stays is your call |
| After acceptance | L3 pinned automatically · L6 download size recorded nightly | — | — | L4 the warm spare (built after the 4TB install) |

## 7. Open questions

1. **N4/N5 VPN method:** decided after the trial on the 2TB (results in the journal); the
   losing method is removed.
2. **S2f–S2h, V6 (proposed 2026-10-05):** one shared B2 repository, dsktp's interim
   upload and its Windows drive image. Two facts about dsktp choose the S2h mechanics:
   does it dual-boot the Windows drive or run it as a whole-disk VM, and is the Windows
   partition BitLocker-encrypted? Confirmed when the PR that proposes them merges.

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
- 2026-10-03: section 6 written; L1 spelled out (disk confirmation, subvolumes, signed rebase) with `docs/install.md`; L3 pin after acceptance; L4 rehearsal and quarterly restore test; L5 `cosmic-acceptance`; L6 rechunk if downloads are large; F8 DAS write rule.
- 2026-10-03 (night): user corrections. V2: `win11-cac` is the default, SPICE redirect the required fallback. S2e: one snapshot a day, not hourly. F8: the DAS stays an ordinary disk; only the old restic repo is frozen, and it is deleted after the migration and the new backups have proven themselves. L4: the 2TB becomes a warm spare refreshed weekly. V5 dropped (a copy of a shut-down VM is enough). Automation: the rootful `vpn` box becomes `net`, created by the image (N4, C1c); L1 by kickstart plus first-boot services; P6/P9 by `cosmic-enroll`; L3 by `cosmic-acceptance --pin`.
- 2026-10-03 (night): F7 — one dotfiles repo for both machines, keyed by the machine name (= recipe, image, `VARIANT_ID`); per-machine values in `.chezmoidata/machines.yaml`; migration in `.migration-prep/<name>/`.
- 2026-10-03 (late night): F10 — software from its publisher at its latest version, never a kept installer. N4: Cisco as a `.deb` installed with apt in box:net from a private URL (the `.sh` path and the Workstation copy are dropped; the headend pushes profiles). Boxes: `dev`, `claude`, `rocm` (rootless) and `net` (rootful); project boxes later, with their projects.
- 2026-10-03 (late): acceptance without manual checks (L5): evidence from the journal and from two small recorders in the image (`cosmic-evidence-sleep.service`, `cosmic-evidence-tunnel@`), an `--exercise` mode for the active trials, a nightly `--record` run, automatic pinning (L3), J1's restore probe (S2b) and download-size record (L6). N4: Cisco's web-deploy `.sh` installer goes into box:net (it needs a writable `/usr` and systemd); Windscribe's `.deb` is fetched by the image.
- 2026-10-03 (night): work IT cannot provide the Cisco `.deb`. F10 gets one noted exception: Cisco Secure Client is installed in box:net from the web-deploy `.sh` kept from the Workstation (private, on the DAS and in `/var/lib/net-box/installers/`); the headend upgrades it on connect. `CISCO_DEB_URL` retires.
- 2026-10-04: D10 (a tidy home): git config, the Brewfile and bash history move to their XDG locations; hardcoded locations (bash's rc files, `.ssh`, `.gnupg`, `.pki`, `.var`, app state) are accepted. Moved before the user layer has run anywhere, so nothing needs migrating.
- 2026-10-04: O2 (drift engine) and F11 (lists live in the declaration files) proposed; design in `docs/drift-engine.md`. Existing tools surveyed (metapac, homebrew-file, aconfmgr, home-manager): none records intent or covers `/etc`, boxes and dotfiles together.
- 2026-10-05: O2 revised after review: watchers instead of command wrappers; adopt costs the same as except (key + reason); this machine by default; the `net` box covered (names only, vendor patterns); guided proposal for image-lane items; no login notification; retention defined; Bottles left open (design section 16).
- 2026-10-05: O2 and F11 confirmed (design `docs/drift-engine.md`); Bottles prefixes left out of v1. Built later in planned sprints, after the 2TB user layer; O1 stays until then.
- 2026-10-05: S2f–S2h and V6 proposed: one restic repository on B2 for both machines (content synced by Syncthing is stored once), dsktp's off-site copy started now from its Workstation, its daily-booted Windows drive backed up as a bootable image (work applications cannot be reinstalled), the Win11 VM disk kept trim-friendly.
