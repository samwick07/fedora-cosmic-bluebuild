#!/usr/bin/bash
# cosmic-signed-origin — make every future update of this machine signature-verified
# (spec L1). An install from the kickstart (ostreecontainer) or a plain `bootc switch`
# leaves the origin at ostree-unverified-registry:…; the image already carries the
# signing policy, so this moves the origin to ostree-image-signed:docker://… for the
# same image. Staged only: it applies at the next reboot. Nothing happens when the origin
# is already signed or is not one of this project's images.
set -euo pipefail
ref=$(rpm-ostree status --booted --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["deployments"][0].get("container-image-reference",""))')
case "$ref" in
    ostree-image-signed:*) echo "origin already signed: $ref"; exit 0 ;;
    *ghcr.io/samwick07/fedora-cosmic-*) ;;
    *) echo "not this project's image ($ref): nothing to do"; exit 0 ;;
esac
image=${ref#*:}               # drop the transport (ostree-unverified-registry: / ostree-remote-image:…)
image=${image#docker://}
image=${image#registry:}
# Already staged by an earlier run?
if rpm-ostree status --json | python3 -c 'import json,sys; d=json.load(sys.stdin)["deployments"]; sys.exit(0 if any(x.get("staged") and x.get("container-image-reference","").startswith("ostree-image-signed:") for x in d) else 1)'; then
    echo "signed origin already staged; applies at the next reboot"; exit 0
fi
echo "moving the origin to ostree-image-signed:docker://$image (applies at the next reboot)"
rpm-ostree rebase "ostree-image-signed:docker://$image"
