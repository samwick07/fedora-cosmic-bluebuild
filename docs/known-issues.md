# Known issues and caveats

Standing caveats of the image and the scripts. Bugs found while using the
image go to GitHub issues (template: "Bug in the image or scripts"); an entry
moves here when it is a lasting limitation rather than something to fix.

## Open — verify on the test drive

- **Restore into the read-only Atomic root.** The allowlist restore writes
  `/home/<user>/…` with `--target /`; restic follows the `/home -> var/home`
  symlink (tested). Not yet seen on a real install: whether restic warns when
  it restores the metadata of `/home` itself. Fallback if it fails:
  `restic restore … --target /var` (lands in `/var/home/<user>/…`).
- **Flatpak browsers and the CAC.** Native Firefox loads OpenSC through p11-kit;
  whether the Chrome flatpak sees the card through `--socket=pcsc` must be tested.
- **Rechunking / zstd.** Not enabled: per-update download size not measured yet
  (`--build-chunked-oci` is a CI dispatch option); zstd untested with `bootc upgrade`.
- **Desktop image (`recipe-dsktp.yml`).** Builds and validates; never installed.

## Lasting caveats (worked around)

- **BlueBuild CLI 0.9.37 local builds sign for `localhost/<image>`.** `bluebuild
  build` drops `--registry` before generating the Containerfile.
  `fix-signing-registry.sh` rewrites the policy; CI builds are unaffected.
- **DoD PKI bundle is signed with SHA-1**, which Fedora's OpenSSL refuses.
  `setup-cac.sh` allows SHA-1 for that one verification only; the root is pinned.
- **The base image has no `openssl` CLI** (only the libraries); the recipe adds it.
- **Hibernation needs Secure Boot off** (kernel lockdown blocks resume from an
  unsigned image). See `docs/hibernation-setup.md`.
- **`podman pull` of `:latest` replaces the local manifest list** with a plain
  image; before a local `--push`: `podman manifest exists … || podman untag …`.
- **bootupd rewrites the firmware's boot entries.** With `--update-firmware`, which `bootc install`
  passes, it deletes every NVRAM entry labelled "Fedora" — including the running system's — and
  creates one for the target (install runs 4 and 5). bootc 1.16 runs it inside the new deployment,
  so stubbing `efibootmgr` in the container did not help. `install-atomic.sh` now installs with
  `--bootloader none`, runs `bootupctl backend install --component EFI` itself without
  `--update-firmware`, mounts `/sys/firmware/efi/efivars` read-only in both containers (refusing to
  start otherwise) and stops if the entries differ afterwards. The target boots through its ESP
  fallback (`EFI/BOOT/BOOTX64.EFI` → `fbx64.efi` creates the entry on first boot) or once via F12.
- **`install-atomic.sh` needs a disk prepared by `prepare-disk.sh` or Anaconda**
  (ESP, ext4 /boot, LUKS swap, LUKS root). It never repartitions.
