#!/usr/bin/env bash
# fix-signing-registry.sh — run right after the `signing` module.
#
# BlueBuild CLI 0.9.37 `bluebuild build` does not pass --registry /
# --registry-namespace to its generate step (src/commands/build.rs), so a local
# build bakes IMAGE_REGISTRY=localhost and the signing module writes a policy
# for localhost/<image>. bootc then pulls ghcr.io/samwick07/<image> under the
# "" fallback (insecureAcceptAnything): updates are never verified.
# Rewrite the entries to the published name. CI builds already have it: no-op.
set -euo pipefail

PUBLISHED="ghcr.io/samwick07"
POLICY=/etc/containers/policy.json
REGD=/etc/containers/registries.d

for f in "$REGD"/localhost-*.yaml; do
    [[ -e "$f" ]] || continue
    name="${f#"$REGD"/localhost-}"; name="${name%.yaml}"
    sed -i "s#localhost/${name}:#${PUBLISHED}/${name}:#" "$f"
    mv "$f" "$REGD/${PUBLISHED##*/}-${name}.yaml"     # the signing module's own naming (CI builds)
    sed -i "s#\"localhost/${name}\"#\"${PUBLISHED}/${name}\"#" "$POLICY"
    echo "signing policy: localhost/${name} -> ${PUBLISHED}/${name}"
done

# Fail the build if anything still points at localhost.
if grep -q '"localhost/' "$POLICY" || compgen -G "$REGD/localhost-*.yaml" >/dev/null; then
    echo "ERROR: localhost signing entries remain"; exit 1
fi
python3 -m json.tool "$POLICY" >/dev/null
