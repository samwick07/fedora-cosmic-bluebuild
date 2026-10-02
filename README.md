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
| understand the model (image / chezmoi / Syncthing / restic) | [docs/clean-room.md](docs/clean-room.md) |
| migrate a machine: install → first boot → restore → validate | [docs/migration-guide.md](docs/migration-guide.md) |
| replace a dead or new drive | [docs/disaster-recovery.md](docs/disaster-recovery.md) |
| update, add software, find a tool, see why things are the way they are | [docs/operations.md](docs/operations.md) |
| build, test, sign or publish an image; how CI works | [docs/local-build.md](docs/local-build.md) |
| check hibernation | [docs/hibernation-setup.md](docs/hibernation-setup.md) |
| know about the bootloader choice | [docs/bootloader.md](docs/bootloader.md) |
| see open caveats, or report a bug | [docs/known-issues.md](docs/known-issues.md) · [issues](../../issues) |

## Layout

```
recipes/       image definitions (common-modules.yml + one recipe per machine)
files/         everything copied into the image (see files/README.md)
scripts/       install, check and CI helpers; targets/site.example.env = template for the private site.env
backup/        restic backup script + excludes (the copy on the DAS is deployed from here)
docs/          the documentation above
.github/       nightly CI build gated by scripts/smoke-test.sh; issue template
cosign.pub     verifies the images
```

Personal values (user, disks, DAS) live only in the gitignored
`scripts/targets/site.env`; `scripts/check-leaks.sh` keeps them out of the repo
and the image. User configuration lives in a separate (private) chezmoi repo.
