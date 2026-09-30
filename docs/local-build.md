# Building and publishing the images locally

Images are built on the laptop (or desktop) with the BlueBuild CLI and pushed
to GHCR from there. GitHub Actions is a fallback only (`workflow_dispatch`);
it has no schedule and no push/PR triggers, so it costs nothing unless you
click Run.

## One-time setup on the build machine

```bash
# 1. BlueBuild CLI (rootful podman is used for the build)
podman run --pull always --rm ghcr.io/blue-build/cli:latest-installer | bash
#    -> /usr/local/bin/bluebuild   (on an Atomic host that is /var/usrlocal/bin — fine, it is host-local)
bluebuild --version

# 2. Registry login (a classic PAT with write:packages, or `gh auth token`)
podman login ghcr.io -u samwick07

# 3. Cosign key pair — regenerate it ONCE, now, unencrypted.
#    The current cosign.key is encrypted ("ENCRYPTED SIGSTORE PRIVATE KEY"). BlueBuild's
#    docs are explicit: "Do NOT put in a password … the signing key will not work if it is
#    encrypted." Nothing is deployed yet, so re-keying costs nothing.
cd ~/migration-prep/fedora-cosmic-bluebuild
mv cosign.key cosign.key.encrypted-old && mv cosign.pub cosign.pub.encrypted-old
cosign generate-key-pair          # press Enter twice (empty password)
git add cosign.pub                # cosign.key stays gitignored
#    If you keep the GitHub Actions fallback, paste the new cosign.key into the
#    SIGNING_SECRET repository secret too.
```

BlueBuild finds `cosign.key` in the repo root automatically (or takes the key
contents from `COSIGN_PRIVATE_KEY`), so no flag is needed when building from
the repo directory.

Keep `cosign.key` and `~/.restic/frmwrk-repo.pass` somewhere
that is NOT the laptop and NOT inside the restic repo (password manager, USB
stick). Without the cosign key you can still build and push, but machines
pinned to `ostree-image-signed:` refuse the new image until you re-key
(regenerate the pair, commit the new `cosign.pub`, rebuild, rebase unsigned once).

## Build

```bash
cd ~/migration-prep/fedora-cosmic-bluebuild
bluebuild build -B podman recipes/recipe-framework.yml   # ~10–25 min; layers cached after the first run
podman images localhost/fedora-cosmic-framework          # -> localhost/fedora-cosmic-framework:latest
```

`-B podman` matters: without it BlueBuild picks Docker whenever Docker is
installed, the image lands in Docker's storage, and `install-atomic.sh` (which
only looks in podman storage) stops with "image not found". To move an image
that was built with Docker: `docker save localhost/fedora-cosmic-framework:latest | podman load`.

Smoke-test the image before installing or pushing:

```bash
IMG=localhost/fedora-cosmic-framework:latest
podman run --rm $IMG bootc --version
podman run --rm $IMG ls -l /usr/bin/post-install-setup.sh /usr/bin/setup-cac.sh /usr/bin/enable-hibernation.sh /usr/share/distrobox/distrobox.ini /etc/fedora-cosmic-atomic/restore-allowlist.txt
podman run --rm $IMG rpm -q tailscale restic syncthing chezmoi age ghostty starship swtpm edk2-ovmf NetworkManager-openvpn fprintd
podman run --rm $IMG cat /etc/systemd/logind.conf.d/10-lid.conf
podman run --rm $IMG bash -c 'ls / | grep -vE "^(afs|bin|boot|dev|etc|home|lib|lib64|media|mnt|opt|ostree|proc|root|run|sbin|srv|sys|sysroot|tmp|usr|var)$"'   # must print nothing (/ostree -> sysroot/ostree comes from the base)
podman run --rm $IMG stat -c '%a %n' /usr/share/distrobox/distrobox.ini /etc/profile.d/amd-common.sh /etc/environment.d/50-amd-common.conf   # all 644
```

## Publish to GHCR (signed)

```bash
cd ~/migration-prep/fedora-cosmic-bluebuild     # cosign.key must be in the cwd
bluebuild build -B podman --push \
  --registry ghcr.io --registry-namespace samwick07 \
  recipes/recipe-framework.yml
```

First push only: the package `ghcr.io/samwick07/fedora-cosmic-framework` is
created **private**. Make it public (GitHub → your profile → Packages → the
package → Package settings → Change visibility), otherwise `bootc upgrade`
on the installed machine gets a 401. The alternative is an auth file at
`/etc/ostree/auth.json` on every machine; public is simpler.

Both recipes at once:

```bash
for r in recipe-framework.yml recipe-desktop.yml; do
  bluebuild build -B podman --push --registry ghcr.io --registry-namespace samwick07 recipes/$r || break
done
```

## Consume

| Situation | Command on the machine |
| --- | --- |
| Fresh install of a disk | `sudo scripts/install-atomic.sh scripts/targets/<disk>.env` (uses the `localhost/` image, sets GHCR as update source) |
| Routine update | `sudo bootc upgrade` (or `rpm-ostree upgrade`) then reboot |
| Test a local build without pushing | `sudo bootc switch --transport containers-storage localhost/fedora-cosmic-framework:latest` — the image must be in **root's** podman storage (`sudo podman images`); copy with `podman save … \| sudo podman load` if you built rootless |
| Go back to GHCR after a local test | `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-framework:latest` |
| Enforce signatures | `sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-framework:latest` — only after a signed push |
| Roll back | `sudo bootc rollback` (or pick the previous entry in the GRUB menu) |

## Fedora version bump (44 → 45)

1. Wait ~2–4 weeks after release for the COPRs (ghostty, starship, topgrade) to have F45 builds.
2. `image-version: 45` in **both** recipe files. Commit.
3. Build locally, smoke-test, `bootc switch --transport containers-storage …` on the test drive or laptop, reboot, live with it a day.
4. Push. `bootc upgrade` everywhere else.

## Housekeeping

- `podman image prune` after a few builds; each layer set is several GB.
- The two GitHub repos (`fedora-cosmic-atomic`, `fedora-cosmic-bluebuild`) hold
  the same tree. Keep **one** (this one — the template fork) and archive the
  other so nothing builds twice.
- `dependabot.yml` was removed: its PRs used to trigger builds.
