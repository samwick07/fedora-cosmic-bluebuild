# Known issues and caveats

Standing caveats of the image and the scripts. Bugs found while using the
image go to GitHub issues (template: "Bug in the image or scripts"); an entry
moves here when it is a lasting limitation rather than something to fix.

## Open — verify on the test drive

- **Black screen after login (COSMIC handover race).** Upstream
  [pop-os/cosmic-comp#2690](https://github.com/pop-os/cosmic-comp/issues/2690) (also
  [cosmic-greeter#513](https://github.com/pop-os/cosmic-greeter/issues/513)); since COSMIC 1.5.0, still in 1.8.0.
  greetd starts the session while the greeter's cosmic-comp still holds `/dev/dri/cardN`; the session's
  cosmic-comp gets EBUSY ("Failed to add device /dev/dri/card1 … Device or resource busy", then "Backend
  initialized without output") and exits. Hit on every login of the test drive (Framework 13, Ryzen 7040).
  Workaround in the image: `cosmic.desktop` runs `/usr/bin/cosmic-session-wait`, which waits (max 10 s) until
  the greeter's compositor and logind session are gone. Untested on hardware until the next image is booted.
  If it still goes black: Ctrl+Alt+F3 (NOT Ctrl+Alt+Del, which reboots), log in, `sudo systemctl restart
  cosmic-greeter`. Remove the workaround once upstream fixes it (candidate: cosmic-comp PR #2670).
- **First real restore.** `post-install-setup.sh` restores home paths into `/var/home` (restoring
  through the `/home` symlink on the read-only root makes restic exit 1 on `lchown`, reproduced in a
  container) and only from host `SITE_HOSTNAME`'s newest snapshot. Tested in containers; the first
  real run is Phase 4 on the test drive.
- **CAC in Chrome (dev distrobox).** Chrome is the RPM in the `dev` box. Tested on the
  Workstation (2026-10-02, throwaway box, no reader attached): the box reaches the host's
  pcscd through the /run/pcscd symlink (SCardEstablishContext ok; without the symlink
  0x8010001D), p11-kit loads OpenSC, ~/.pki/nssdb (shared home) has the DoD certs, and
  Chrome's renderers run in their own user/pid namespaces with seccomp. Untested: a real
  card + PIN + a CAC login site. pcsc-lite in the box (fedora:44) and on the host must speak
  the same protocol; both are Fedora 44 today.
- **Rechunking / zstd.** Not enabled: per-update download size not measured yet
  (`--build-chunked-oci` is a CI dispatch option); zstd untested with `bootc upgrade`.
- **Desktop image (`recipe-dsktp.yml`).** Builds and validates; never installed.

## Lasting caveats (worked around)

- **restic `latest` means "newest of any host".** Test-drive backups (`<name>-test`) are newer than
  the real machine's; restores and docs always use `latest --host <SITE_HOSTNAME>`.

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
