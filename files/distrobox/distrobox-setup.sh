#!/usr/bin/env bash
# distrobox-setup.sh — Recreate all distrobox containers from declarative config.
#
# This script is baked into the BlueBuild image at /usr/local/bin/distrobox-setup.sh.
# Run it after first boot (or after any rebase/reinstall) to recreate containers.
#
# Containers are defined in /usr/local/share/distrobox/*.ini (also baked in).
# To add a new container, drop a new .ini file there and re-run this script.
#
# Usage:
#   distrobox-setup.sh              # create all containers (skips existing)
#   distrobox-setup.sh --recreate   # destroy and recreate all containers
#   distrobox-setup.sh --list       # list defined containers
#
# Updates: `distrobox upgrade --all` updates all containers in place.

set -euo pipefail

CONFIG_DIR="/usr/local/share/distrobox"
CONTAINERS_DIR="${HOME}/.local/share/distrobox-exports"

RECREATE=false
LIST_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recreate) RECREATE=true; shift ;;
        --list)     LIST_ONLY=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "${CONTAINERS_DIR}"

# Find all container definitions
mapfile -t CONFIGS < <(find "${CONFIG_DIR}" -name '*.ini' -type f 2>/dev/null | sort)

if [[ ${#CONFIGS[@]} -eq 0 ]]; then
    echo "No container definitions found in ${CONFIG_DIR}"
    exit 1
fi

if [[ "${LIST_ONLY}" == true ]]; then
    echo "Defined distrobox containers:"
    for cfg in "${CONFIGS[@]}"; do
        source "${cfg}"
        echo "  - ${CONTAINER_NAME}: ${CONTAINER_IMAGE} ($(echo ${PACKAGES} | wc -w) packages)"
    done
    exit 0
fi

for cfg in "${CONFIGS[@]}"; do
    echo "========================================"
    # Reset vars from previous iteration
    unset CONTAINER_NAME CONTAINER_IMAGE CONTAINER_HOSTNAME ADDITIONAL_PACKAGES PACKAGES INIT_HOOKS CREATE_FLAGS
    source "${cfg}"

    echo "Container: ${CONTAINER_NAME} (${CONTAINER_IMAGE})"

    # Check if container already exists
    if distrobox-list 2>/dev/null | grep -qw "${CONTAINER_NAME}"; then
        if [[ "${RECREATE}" == true ]]; then
            echo "  Destroying existing container..."
            distrobox-rm --name "${CONTAINER_NAME}" --force
        else
            echo "  Already exists. Use --recreate to rebuild. Skipping."
            continue
        fi
    fi

    echo "  Creating container..."

    # Build the distrobox-create command.
    # CREATE_FLAGS (optional) allows passing extra flags like device passthrough:
    #   CREATE_FLAGS="--additional-flags --device=/dev/kfd --additional-flags --device=/dev/dri"
    CREATE_CMD=(distrobox-create \
        --name "${CONTAINER_NAME}" \
        --image "${CONTAINER_IMAGE}" \
        --hostname "${CONTAINER_HOSTNAME:-distrobox}" \
        --yes)

    if [[ -n "${ADDITIONAL_PACKAGES:-}" ]]; then
        CREATE_CMD+=(--additional-packages "${ADDITIONAL_PACKAGES}")
    fi

    if [[ -n "${CREATE_FLAGS:-}" ]]; then
        echo "  Using create flags: ${CREATE_FLAGS}"
        # shellcheck disable=SC2086
        CREATE_CMD+=(${CREATE_FLAGS})
    fi

    "${CREATE_CMD[@]}"

    echo "  Running init hooks..."
    distrobox-enter --name "${CONTAINER_NAME}" -- bash -c "${INIT_HOOKS}"

    echo "  Installing packages..."
    if [[ -n "${PACKAGES}" ]]; then
        distrobox-enter --name "${CONTAINER_NAME}" -- bash -c "${PACKAGES}"
    fi

    echo "  Done: ${CONTAINER_NAME}"
done

echo "========================================"
echo "All containers created."
echo "Update with: distrobox upgrade --all"
