# Building and publishing the images locally

Images are built on the laptop (or desktop) with the BlueBuild CLI and pushed
to GHCR from there. GitHub Actions (`.github/workflows/build.yml`) does the
same nightly when something changed — the base image digest, or a commit with
no published `<sha7>-44` tag (`scripts/ci-should-build.sh`) — and only pushes
after `scripts/smoke-test.sh` passes. Run it by hand from the Actions tab with
`force` or `chunked_oci` (rechunk trial). Setup: secret `SIGNING_SECRET`
(= `cosign.key`), and the package's "Manage Actions access" granting this repo
Write (or a `GHCR_TOKEN` PAT secret).

Pinned on purpose: the BlueBuild CLI (installer `v0.9.37`), the GitHub actions
(by commit), and the BlueBuild modules (`type: dnf@v1`, `script@v2`,
`default-flatpaks@v2`, … = what `latest` was on 2026-10-01). Bump them
deliberately. Not enabled: zstd push compression (`--compression-format zstd`)
— untested with `bootc upgrade` from this registry; try it on the test drive
first. Rechunking (`--build-chunked-oci`) is a dispatch option until two runs
show the per-update download vs `logs/compare-layers.log` (1.63 GB custom vs
0.80 GB stock).

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
bluebuild build -B podman recipes/recipe-frmwrk.yml   # ~10–25 min; layers cached after the first run
podman images localhost/fedora-cosmic-frmwrk          # -> localhost/fedora-cosmic-frmwrk:latest
```

`-B podman` matters: without it BlueBuild picks Docker whenever Docker is
installed, the image lands in Docker's storage, and `install-atomic.sh` (which
only looks in podman storage) stops with "image not found". To move an image
that was built with Docker: `docker save localhost/fedora-cosmic-frmwrk:latest | podman load`.

Smoke-test the image before installing or pushing (the same script gates the
CI push; it needs network for the DoD PKI check):

```bash
scripts/smoke-test.sh ghcr.io/samwick07/fedora-cosmic-frmwrk:latest_linux_amd64
```

It checks bootc, the shipped scripts (executable, parse), file modes, the
package set, the base fallbacks (firefox, toolbox), the lid/hibernation config
(frmwrk), the signing policy (published name, key = `cosign.pub`), the DoD PKI
download + verification, and runs `scripts/check-leaks.sh` on the repo and the
image (with `scripts/targets/site.env`'s exact values when that file exists).

## Publish to GHCR (signed)

```bash
cd ~/migration-prep/fedora-cosmic-bluebuild     # cosign.key must be in the cwd
bluebuild build -B podman --push \
  --registry ghcr.io --registry-namespace samwick07 \
  recipes/recipe-frmwrk.yml
```

First push only: the package `ghcr.io/samwick07/fedora-cosmic-frmwrk` is
created **private**. Make it public (GitHub → your profile → Packages → the
package → Package settings → Change visibility), otherwise `bootc upgrade`
on the installed machine gets a 401. The alternative is an auth file at
`/etc/ostree/auth.json` on every machine; public is simpler.

Both recipes at once:

```bash
for r in recipe-frmwrk.yml recipe-dsktp.yml; do
  bluebuild build -B podman --push --registry ghcr.io --registry-namespace samwick07 recipes/$r || break
done
```

## Consume

| Situation | Command on the machine |
| --- | --- |
| Fresh install of a disk | `sudo scripts/install-atomic.sh scripts/targets/<disk>.env` (uses the `localhost/` image, sets GHCR as update source) |
| Routine update | `sudo bootc upgrade` (or `rpm-ostree upgrade`) then reboot |
| Test a local build without pushing | `sudo bootc switch --transport containers-storage localhost/fedora-cosmic-frmwrk:latest` — the image must be in **root's** podman storage (`sudo podman images`); copy with `podman save … \| sudo podman load` if you built rootless |
| Go back to GHCR after a local test | `sudo bootc switch ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` |
| Enforce signatures | `sudo rpm-ostree rebase ostree-image-signed:docker://ghcr.io/samwick07/fedora-cosmic-frmwrk:latest` — only after a signed push |
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
