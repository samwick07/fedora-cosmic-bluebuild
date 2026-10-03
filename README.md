# fedora-cosmic-bluebuild

Declarative Fedora COSMIC Atomic images for two AMD machines, built with
[BlueBuild](https://blue-build.org) on `quay.io/fedora-ostree-desktops/cosmic-atomic:44`,
signed with cosign and published to GHCR.

| Image | Machine |
| --- | --- |
| `ghcr.io/samwick07/fedora-cosmic-frmwrk` | Framework 13 AMD laptop — hibernation, fingerprint, CAC, Win11 VM |
| `ghcr.io/samwick07/fedora-cosmic-dsktp` | Desktop (Ryzen 9 / RX 9070 XT, VFIO) — recipe only, not yet migrated |

## Documentation

| I want to … | Read |
| --- | --- |
| know what the system must be, and why | [docs/end-state.md](docs/end-state.md) (the spec) |
| install a machine | [docs/install.md](docs/install.md) |
| get a file back, or the whole machine as of yesterday | [docs/restore.md](docs/restore.md) |
| replace a dead drive or laptop | [docs/disaster-recovery.md](docs/disaster-recovery.md) |
| the daily routine, change the system, shipped tools | [docs/operations.md](docs/operations.md) |
| build, test, sign or publish an image; how CI works | [docs/local-build.md](docs/local-build.md) |
| check hibernation | [docs/hibernation-setup.md](docs/hibernation-setup.md) |
| know about the bootloader choice | [docs/bootloader.md](docs/bootloader.md) |
| see open caveats, or report a bug | [docs/known-issues.md](docs/known-issues.md) · [issues](../../issues) |
| see where the work stands | [docs/HANDOFF.md](docs/HANDOFF.md) |

## Layout

```
recipes/       image definitions (common-modules.yml + one recipe per machine)
install/       kickstart for the stock COSMIC Atomic ISO (docs/install.md)
files/         everything copied into the image (see files/README.md)
scripts/       CI and check helpers (smoke test, leak check, build decision, Workstation inventory);
               targets/site.example.env = template for the private site.env
backup/        the Workstation's restic script (retired once the nightly job runs on the laptop)
docs/          the documentation above
.github/       nightly CI build gated by scripts/smoke-test.sh; issue template
cosign.pub     verifies the images
```

Personal values (user, disks, DAS) live only in the gitignored
`scripts/targets/site.env`; `scripts/check-leaks.sh` keeps them out of the repo
and the image. User configuration (Brewfile, distroboxes, shell) lives in a separate,
private chezmoi repo; one-time migration steps live there too.
