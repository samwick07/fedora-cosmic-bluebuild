# Declarative Fedora Atomic COSMIC — BlueBuild Setup

## Overview

Two-machine declarative setup using BlueBuild custom OCI images built from
a single shared repository. Both machines run Fedora Atomic COSMIC with
systemd-boot as the bootloader.

## Machines

### Framework 13 AMD (laptop)
  - CPU: AMD Ryzen 7040U (Phoenix, Zen 4)
  - GPU: Integrated Radeon 780M (RDNA3, gfx1036)
  - Image: ghcr.io/USERNAME/fedora-cosmic-framework:latest

### Desktop (ROG STRIX X870-I)
  - CPU: AMD Ryzen 9 9950X (Granite Ridge, Zen 5, 16-core)
  - GPU: AMD Radeon RX 9070 XT (Navi 48, RDNA 4, discrete)
  - RAM: 96GB DDR5-5600 (2x 48GB)
  - Storage: 4TB + 2TB Crucial T700 NVMe
  - Network: Intel I226-V Ethernet + MediaTek MT7927 Wi-Fi 7
  - Image: ghcr.io/USERNAME/fedora-cosmic-desktop:latest

Both machines are all-AMD, so they share the same ROCm stack and GPU
driver approach. The differences are laptop-specific (power management,
fingerprint, ambient light sensor) vs desktop-specific (smart card reader,
ASUS ROG features).

## Repository structure

```
fedora-cosmic-framework/          ← GitHub repo
├── .github/workflows/
│   └── build.yml                 ← Builds BOTH images in parallel
├── recipes/
│   ├── common-modules.yml        ← 90% shared: packages, flatpaks, scripts
│   ├── recipe-framework.yml      ← Laptop-specific: power, fingerprint, APU GPU
│   └── recipe-desktop.yml        ← Desktop-specific: ASUS, smart card, dGPU
├── scripts/
│   ├── configure-amd-gpu-framework.sh   ← ROCm env for RDNA3 APU
│   ├── configure-amd-gpu-desktop.sh     ← ROCm env for RDNA 4 dGPU
│   └── enable-flathub.sh                ← Shared: Flathub remote setup
├── system/                       ← Static config files → /etc, /usr
├── docs/
│   └── systemd-boot-setup.md     ← How to switch from GRUB to systemd-boot
├── cosign.pub                    ← Public key for image verification
└── README.md
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  GitHub Repo (single repo, two recipes)             │
│                                                     │
│  common-modules.yml ──┐                             │
│                       ├──> recipe-framework.yml     │
│                       │              │              │
│                       │              ▼              │
│                       │   ghcr.io/.../framework     │
│                       │              │              │
│                       └──> recipe-desktop.yml       │
│                             │         │              │
│                             │         ▼              │
│                             │   ghcr.io/.../desktop  │
│                             │                       │
│  GitHub Actions builds both in parallel             │
│  (matrix strategy in build.yml)                     │
└─────────────────────────────────────────────────────┘
         │                          │
         ▼                          ▼
   Framework 13                Desktop
   rebase to framework         rebase to desktop
   image                       image
```

## Three-layer separation

  Layer 1: OS Image (recipe.yml + GitHub Actions)
    - System packages, drivers, system configs, default flatpaks
    - Edit recipe → push → Actions rebuilds → machines pull on next boot
    - Two images from one repo, sharing common-modules.yml

  Layer 2: Dotfiles (YADM or chezmoi)
    - .bashrc, .config/starship.toml, .config/ghostty/config,
      .gitconfig, .ssh/config, etc.
    - Same dotfiles repo on both machines
    - yadm clone https://github.com/USERNAME/dotfiles.git

  Layer 3: Data (restic backup)
    - /home/<user>/Documents, Pictures, Videos, etc.
    - Per-machine restic repos (or shared repo with different tags)

## Setup sequence (Oct 1 target)

### Phase 1: Install Fedora Atomic COSMIC (Oct 1)
1. Boot Fedora COSMIC Atomic ISO on the 4TB NVMe (Framework 13)
2. Install with LUKS encryption
3. Boot into the new system, verify it works

### Phase 2: Switch to systemd-boot
1. Follow docs/systemd-boot-setup.md
2. Verify bootctl status shows systemd-boot
3. Verify rpm-ostree status still shows deployments
4. Verify boot menu shows rollback entries

### Phase 3: Set up BlueBuild
1. Fork https://github.com/blue-build/template
2. Copy recipes, scripts, system dirs from this directory
3. Set up cosign signing (secrets in GitHub repo)
4. Push and wait for Actions to build both images (~15-30 min)

### Phase 4: Rebase to custom image
1. sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/USERNAME/fedora-cosmic-framework:latest
2. sudo systemctl reboot
3. sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/USERNAME/fedora-cosmic-framework:latest
4. sudo systemctl reboot

### Phase 5: Restore data
1. Set up YADM: yadm clone https://github.com/USERNAME/dotfiles.git
2. Restore from restic: restic -r <repo> restore latest --target / --include /home/<user>/
3. Reinstall flatpak data from .var/app/ (included in restic backup)

### Phase 6: Desktop (when ready)
1. Install Fedora COSMIC Atomic on desktop 4TB NVMe
2. Switch to systemd-boot (same steps)
3. Rebase to desktop image:
   sudo rpm-ostree rebase ostree-unverified-registry:ghcr.io/USERNAME/fedora-cosmic-desktop:latest
4. Same YADM and restic restore

## Daily workflow

### Add a package to both machines:
  Edit common-modules.yml → add package → git push
  Both images rebuild. Both machines get it on next rpm-ostree upgrade.

### Add a package to one machine only:
  Edit recipe-framework.yml or recipe-desktop.yml → add package → git push
  Only that image rebuilds.

### Major Fedora version upgrade (F44 → F45):
  Edit image-version: 44 → 45 in BOTH recipe files → git push
  Both images rebuild against Fedora 45 base.
  Machines get it on next rpm-ostree upgrade + reboot.
  Rollback: rpm-ostree rollback + reboot.

### New hardware setup:
  1. Boot Fedora COSMIC Atomic ISO → install
  2. Switch to systemd-boot
  3. Rebase to the appropriate image (framework or desktop)
  4. yadm clone
  5. restic restore
  Full environment in under 30 minutes.

## Key decisions documented

  - Bootloader: systemd-boot (BLS-native, Fedora's direction, clean ostree integration)
  - Image base: quay.io/fedora-ostree-desktops/cosmic-atomic (official upstream)
  - Version pin: Fedora 44 (upgrade to 45 when ready, weeks after release)
  - Both machines all-AMD: shared ROCm stack, no NVIDIA driver complexity
  - Dotfiles: YADM (separate repo, not in the image)
  - Data: restic (separate from the image)
  - Development tools: toolbox/distrobox containers (not in the image)
