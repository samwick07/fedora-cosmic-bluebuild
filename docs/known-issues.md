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
- **Hibernation after suspend on the Framework 13 AMD.** Some owners reported lock-ups when
  suspend-then-hibernate moves from suspend to hibernate (kernels 6.9–6.14,
  [Framework forum](https://community.frame.work/t/responded-fw-13-amd-lockup-on-hibernate-only-after-suspend-battery-drains-on-suspend-then-hibernate/53860)).
  Acceptance P2 runs 10 cycles on the 2TB. Upstream work to allow encrypted hibernation with
  Secure Boot on is under review (2026); F2 keeps Secure Boot off until it lands.
- **CAC reader in the VM** (V2). `win11-cac attach` (default) stops host pcscd and hands
  the reader over; `detach` gives it back. SPICE redirection (fallback) may fail while host
  pcscd holds the reader: close the host's browsers or `sudo systemctl stop pcscd` first.
  Either way the host sees no card until it is given back.
- **Cisco Secure Client in the rootful `net` box** (N4b). Cisco documents the client on a
  plain host; the one public report of it in a rootful distrobox
  ([distrobox#1536](https://github.com/89luca89/distrobox/issues/1536), 5.1.5, Ubuntu, `--init`)
  failed with "unable to create the interprocess communication depot" and is unresolved (the
  maintainer suggested `--unshare-ipc`). Also open: whether `vpnagentd` in the box can hand
  the VPN's DNS servers to the host's resolver (the box has its own `/etc/resolv.conf`).
  `cosmic-acceptance` checks that the agent answers (`vpn state`), and every tunnel's record
  shows the DNS servers in use; if either fails, method (a), NetworkManager-openconnect, is
  the fallback the trial already carries. The web-deploy `.sh` is non-interactive (it asks
  for the license only when a `license.txt` sits beside it); Cisco dropped the `.sh` from
  5.1.15, and `cosmic-net-box` takes the `.deb` that replaced it.
- **CAC in Chrome (dev distrobox).** Chrome is the RPM in the `dev` box. Tested on the
  Workstation (2026-10-02, throwaway box, no reader attached): the box reaches the host's
  pcscd through the /run/pcscd symlink (SCardEstablishContext ok; without the symlink
  0x8010001D), p11-kit loads OpenSC, ~/.pki/nssdb (shared home) has the DoD certs, and
  Chrome's renderers run in their own user/pid namespaces with seccomp. Untested: a real
  card + PIN + a CAC login site. pcsc-lite in the box (fedora:44) and on the host must speak
  the same protocol; both are Fedora 44 today.
- **Rechunking / zstd.** Not enabled: the nightly job records each night's download size
  (`/var/lib/cosmic-nightly/download-size.log`, spec L6; shown by `cosmic-acceptance`;
  `--build-chunked-oci` is a CI dispatch option); zstd untested with `bootc upgrade`.
- **Homebrew inside boxes is read-only.** `dev` and `claude` mount `/home/linuxbrew`
  read-only (distrobox mounts only `$HOME`); `brew install` works on the host only.
- **Desktop image (`recipe-dsktp.yml`).** Builds and validates; never installed.

## Lasting caveats (worked around)

- **restic `latest` means "newest of any host".** Test-drive backups (`<name>-test`) are newer than
  the real machine's, and VM disks are snapshots of their own (tag `vm-disk`); restores and
  docs always use `latest --host <SITE_HOSTNAME> --tag nightly`.

- **BlueBuild CLI 0.9.37 local builds sign for `localhost/<image>`.** `bluebuild
  build` drops `--registry` before generating the Containerfile.
  `fix-signing-registry.sh` rewrites the policy; CI builds are unaffected.
- **DoD PKI bundle is signed with SHA-1**, which Fedora's OpenSSL refuses.
  `install-dod-roots.sh` allows SHA-1 for that one verification only; the root is pinned.
- **The base image has no `openssl` CLI** (only the libraries); `install-dod-roots.sh`
  installs it for its build step and removes it again (F9).
- **Hibernation needs Secure Boot off** (kernel lockdown blocks resume from an
  unsigned image). See `docs/hibernation-setup.md`.
- **`podman pull` of `:latest` replaces the local manifest list** with a plain
  image; before a local `--push`: `podman manifest exists … || podman untag …`.
- **Retired with the custom installer (2026-10-03):** the bootupd/NVRAM and prepared-disk
  caveats of `install-atomic.sh`. The stock installer (spec L1) does not have them; the
  history is in git and the private journal.
