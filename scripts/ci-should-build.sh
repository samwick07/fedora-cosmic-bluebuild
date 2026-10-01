#!/usr/bin/env bash
#
# ci-should-build.sh — decide whether the nightly CI build has anything to do.
#
#   scripts/ci-should-build.sh recipes/recipe-frmwrk.yml   >> "$GITHUB_OUTPUT"
#
# Builds when the base image digest differs from the one the published image
# was built on, when no published image carries this commit's tag
# (<sha7>-<version>, as BlueBuild tags it), or when FORCE=true.
# Prints name=, image=, build=, reason= lines. Needs skopeo + python3.
#
set -euo pipefail

recipe="${1:?usage: ci-should-build.sh recipes/<recipe>.yml}"
field() { sed -nE "s/^$1:[[:space:]]*\"?([^\"#[:space:]]+)\"?.*/\1/p" "$recipe" | head -1; }
name=$(field name); base=$(field base-image); ver=$(field image-version)
[[ -n "$name" && -n "$base" && -n "$ver" ]] || { echo "cannot read name/base-image/image-version from $recipe" >&2; exit 1; }

image="ghcr.io/${REGISTRY_NAMESPACE:-samwick07}/$name"
sha="${GITHUB_SHA:-$(git rev-parse HEAD)}"; tag="${sha:0:7}-$ver"
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

base_now=$(skopeo inspect --no-tags "docker://$base:$ver" | json 'd["Digest"]')
published=$(skopeo inspect --no-tags "docker://$image:latest" 2>/dev/null \
    | json 'd.get("Labels",{}).get("org.opencontainers.image.base.digest","")' 2>/dev/null || true)
tags=$(skopeo list-tags "docker://$image" 2>/dev/null | json '" ".join(d["Tags"])' 2>/dev/null || true)

build=false; reason="up to date (base ${base_now:7:12}, tag $tag published)"
if [[ "${FORCE:-false}" == true ]]; then build=true; reason="forced"
elif [[ -z "$published" ]]; then build=true; reason="no published image (or no base label)"
elif [[ "$published" != "$base_now" ]]; then build=true; reason="base changed ${published:7:12} -> ${base_now:7:12}"
elif [[ " $tags " != *" $tag "* ]]; then build=true; reason="repo changed (no $tag on $image)"
fi

echo "name=$name"
echo "image=$image"
echo "build=$build"
echo "reason=$reason"
