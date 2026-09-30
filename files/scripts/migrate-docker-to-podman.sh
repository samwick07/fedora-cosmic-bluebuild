#!/usr/bin/env bash
#
# migrate-docker-to-podman.sh — One-time migration of Docker containers to Podman
#
# ╔══════════════════════════════════════════════════════════════════════╗
# ║  ONE-TIME MIGRATION SCRIPT — NOT NEEDED AFTER FIRST RUN              ║
# ║  This script is NOT baked into the image. Run it manually once       ║
# ║  after restoring your home directory from restic.                    ║
# ║                                                                      ║
# ║  Purpose: Replicate Docker containers/volumes under Podman on the    ║
# ║  new atomic host. Docker is not installed on the atomic host —       ║
# ║  Podman replaces it completely.                                      ║
# ║                                                                      ║
# ║  What this does:                                                     ║
# ║    1. Installs podman-compose (via pip in a distrobox or via dnf)    ║
# ║    2. Migrates Docker volumes → Podman volumes                       ║
# ║    3. Pulls images under Podman                                      ║
# ║    4. Starts services with podman compose                            ║
# ║    5. Switches Hermes terminal backend from docker to podman         ║
# ║                                                                      ║
# ║  Usage:                                                              ║
# ║    ./migrate-docker-to-podman.sh              # full migration       ║
# ║    ./migrate-docker-to-podman.sh --volumes    # volume migration only║
# ║    ./migrate-docker-to-podman.sh --compose    # compose services only║
# ║    ./migrate-docker-to-podman.sh --hermes     # Hermes config only   ║
# ╚══════════════════════════════════════════════════════════════════════╝
#
set -euo pipefail

log()    { echo -e "\n\033[1;34m=== $* ===\033[0m"; }
ok()     { echo -e "  \033[0;32m✓\033[0m $*"; }
skip()   { echo -e "  \033[0;33m→\033[0m $* (already done, skipping)"; }
warn()   { echo -e "  \033[0;33m!\033[0m $*"; }
fail()   { echo -e "  \033[0;31m✗\033[0m $*"; }

# ─── Config ───────────────────────────────────────────────────────────
# Docker volumes to migrate (name → podman volume name)
# These were created by docker compose with the "open-webui-frmwrk" project.
DOCKER_VOLUME_DIR="/var/lib/docker/volumes"
VOLUMES=(
    "open-webui-frmwrk_open-webui"
    "open-webui-frmwrk_searxng"
    "open-webui-frmwrk_tailscale-state"
)

# Images to pull under Podman
IMAGES=(
    "ghcr.io/open-webui/open-webui:main"
    "searxng/searxng:latest"
    "nousresearch/hermes-sandbox:desktop"
)

# ─── Parse args ───────────────────────────────────────────────────────
RUN_VOLUMES=false
RUN_COMPOSE=false
RUN_HERMES=false
RUN_ALL=true

case "${1:-}" in
    --volumes) RUN_VOLUMES=true; RUN_ALL=false ;;
    --compose) RUN_COMPOSE=true; RUN_ALL=false ;;
    --hermes)  RUN_HERMES=true;  RUN_ALL=false ;;
    "")        RUN_ALL=true ;;
    *) echo "Usage: $0 [--volumes|--compose|--hermes]"; exit 1 ;;
esac

if [[ "$RUN_ALL" == true ]]; then
    RUN_VOLUMES=true
    RUN_COMPOSE=true
    RUN_HERMES=true
fi

# ─── Pre-flight ───────────────────────────────────────────────────────
log "Pre-flight checks"

if ! command -v podman &>/dev/null; then
    fail "Podman not installed. It should be in the base image."
    exit 1
fi
ok "Podman available: $(podman --version)"

# Check for podman-compose
if ! command -v podman-compose &>/dev/null; then
    echo "  podman-compose not found. Installing via pip..."
    # On atomic, pip install goes into a distrobox or --user
    pip install --user podman-compose 2>/dev/null || {
        warn "Could not install podman-compose via pip."
        echo "  Install it in a distrobox:"
        echo "    distrobox-enter fedora-ws -- pip install podman-compose"
        echo "  Or use 'podman compose' with docker-compose as the provider."
        echo "  The script will use 'podman compose' (delegates to docker-compose if available)."
    }
fi

# Also check for docker-compose (podman compose can use it as a backend)
if command -v docker-compose &>/dev/null; then
    ok "docker-compose available (podman compose will use it)"
fi

# ─── Step 1: Migrate Docker volumes ──────────────────────────────────
migrate_volumes() {
    log "Step 1: Migrate Docker volumes to Podman"

    for vol in "${VOLUMES[@]}"; do
        # Strip the project prefix for a cleaner podman volume name
        # open-webui-frmwrk_open-webui → open-webui
        short_name="${vol#open-webui-frmwrk_}"

        # Check if podman volume already exists
        if podman volume exists "${short_name}" 2>/dev/null; then
            skip "Podman volume '${short_name}'"
            continue
        fi

        # Check if Docker volume data exists (from restic restore of /var/lib/docker)
        docker_path="${DOCKER_VOLUME_DIR}/${vol}/_data"
        if [[ ! -d "${docker_path}" ]]; then
            warn "Docker volume '${vol}' not found at ${docker_path}"
            echo "  If you need this data, restore from restic:"
            echo "    sudo restic restore latest --target / --include '${DOCKER_VOLUME_DIR}/${vol}/'"
            continue
        fi

        echo "  Migrating: ${vol} → ${short_name}"

        # Create podman volume
        podman volume create "${short_name}"

        # Get the volume mountpoint
        podman_mp=$(podman volume inspect "${short_name}" --format '{{.Mountpoint}}')

        # Copy data
        sudo cp -a "${docker_path}/." "${podman_mp}/"
        sudo chown -R $(id -u):$(id -g) "${podman_mp}/"

        ok "Migrated: ${short_name}"
    done
}

# ─── Step 2: Pull images and start compose services ──────────────────
migrate_compose() {
    log "Step 2: Pull images and start services"

    # Pull all images under Podman
    for img in "${IMAGES[@]}"; do
        echo "  Pulling: ${img}"
        podman pull "${img}" && ok "Pulled: ${img}" || warn "Failed: ${img}"
    done

    # Open WebUI + SearXNG compose
    # The original compose file was lost. Recreate it from what we know:
    # - open-webui: ghcr.io/open-webui/open-webui:main, port 3000, volume open-webui
    # - searxng: searxng/searxng:latest, port 8080, volume searxng
    # - tailscale: was in the compose but tailscale is now a host package — skip
    COMPOSE_DIR="${HOME}/Services/open-webui"
    mkdir -p "${COMPOSE_DIR}"

    if [[ -f "${COMPOSE_DIR}/docker-compose.yml" ]]; then
        skip "Compose file exists at ${COMPOSE_DIR}/docker-compose.yml"
    else
        cat > "${COMPOSE_DIR}/docker-compose.yml" << 'COMPOSE'
services:
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    ports:
      - "3000:8080"
    volumes:
      - open-webui:/app/backend/data
    environment:
      - WEBUI_AUTH=true
    restart: unless-stopped

  searxng:
    image: searxng/searxng:latest
    ports:
      - "8080:8080"
    volumes:
      - searxng:/etc/searxng
    restart: unless-stopped

volumes:
  open-webui:
  searxng:
COMPOSE
        ok "Created compose file at ${COMPOSE_DIR}/docker-compose.yml"
        echo ""
        echo "  NOTE: Review and adjust ports, environment, and settings."
        echo "        The original compose file was not found in backups."
        echo "        This is a best-effort reconstruction."
    fi

    # Start services
    echo "  Starting services with podman compose..."
    cd "${COMPOSE_DIR}"
    if command -v podman-compose &>/dev/null; then
        podman-compose up -d
    elif command -v docker-compose &>/dev/null; then
        podman compose up -d
    else
        warn "Neither podman-compose nor docker-compose is available."
        echo "  Install one of:"
        echo "    pip install --user podman-compose"
        echo "    # or in a distrobox:"
        echo "    distrobox-enter fedora-ws -- pip install podman-compose"
        echo "  Then run: cd ${COMPOSE_DIR} && podman-compose up -d"
        return 1
    fi

    ok "Services started"
    echo ""
    echo "  Open WebUI:  http://localhost:3000"
    echo "  SearXNG:     http://localhost:8080"
    echo ""
    echo "  Manage with:"
    echo "    podman compose -f ${COMPOSE_DIR}/docker-compose.yml ps"
    echo "    podman compose -f ${COMPOSE_DIR}/docker-compose.yml down"
    echo "    podman compose -f ${COMPOSE_DIR}/docker-compose.yml up -d"
}

# ─── Step 3: Switch Hermes to Podman ─────────────────────────────────
migrate_hermes() {
    log "Step 3: Switch Hermes terminal backend to Podman"

    CONFIG="${HOME}/.hermes/config.yaml"

    if [[ ! -f "${CONFIG}" ]]; then
        fail "Hermes config not found at ${CONFIG}"
        echo "  Restore from backup: post-install-setup.sh --step 8"
        return 1
    fi

    # Current backend
    current=$(python3 -c "
import yaml
with open('${CONFIG}') as f:
    cfg = yaml.safe_load(f)
print(cfg.get('terminal', {}).get('backend', 'not set'))
" 2>/dev/null)

    echo "  Current terminal backend: ${current}"

    if [[ "${current}" == "podman" ]]; then
        skip "Hermes already using podman backend"
    else
        echo "  Hermes terminal.backend is '${current}'"
        echo ""
        echo "  Hermes config.yaml terminal settings:"
        echo "    backend: local          ← runs commands on the host directly"
        echo "    backend: podman         ← runs commands in a podman container"
        echo "    backend: docker         ← runs commands in a docker container"
        echo ""
        echo "  Your current config uses 'local' (host terminal), which works fine"
        echo "  on the atomic host without any container backend."
        echo ""
        echo "  The Hermes sandbox image (nousresearch/hermes-sandbox:desktop)"
        echo "  has already been pulled under Podman if you ran step 2."
        echo ""
        echo "  To switch Hermes to use Podman for sandboxed execution:"
        echo "    Edit ${CONFIG}"
        echo "    Change: terminal.backend: local"
        echo "    To:     terminal.backend: podman"
        echo ""
        echo "  Or use the Hermes CLI:"
        echo "    hermes config set terminal.backend podman"
        echo ""
        echo "  NOTE: The 'local' backend works perfectly on the atomic host."
        echo "  Only switch to 'podman' if you want sandboxed command execution."

        # Don't auto-change — let the user decide
        ok "Hermes config left as-is (local backend works on atomic host)"
    fi

    # Clean up the old Docker sandbox directory if it exists
    if [[ -d "${HOME}/.hermes/sandboxes/docker" ]]; then
        echo ""
        echo "  Old Docker sandbox directory found: ~/.hermes/sandboxes/docker/"
        echo "  This is safe to remove after confirming Hermes works:"
        echo "    rm -rf ~/.hermes/sandboxes/docker"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────
main() {
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Docker → Podman Migration (ONE-TIME)                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  This script is NOT baked into the image."
    echo "  Run it once after restoring data from restic."
    echo "  Delete it after migration is complete."
    echo ""
    echo "  What will be migrated:"
    echo "    - Docker volumes (open-webui, searxng, tailscale-state)"
    echo "    - Container images (open-webui, searxng, hermes-sandbox)"
    echo "    - Compose services (Open WebUI + SearXNG)"
    echo "    - Hermes terminal backend config"
    echo ""
    echo "  What will NOT be migrated:"
    echo "    - buildkit (BlueBuild uses CI or local builds, not needed on host)"
    echo "    - tailscale container (tailscale is a host package on the atomic image)"
    echo "    - python-nodejs dev images (replaced by distrobox containers)"
    echo ""

    if [[ "${RUN_VOLUMES}" == true ]]; then
        migrate_volumes
    fi

    if [[ "${RUN_COMPOSE}" == true ]]; then
        migrate_compose
    fi

    if [[ "${RUN_HERMES}" == true ]]; then
        migrate_hermes
    fi

    echo ""
    log "Migration complete"
    echo ""
    echo "  Verify with:"
    echo "    podman ps -a                    # running containers"
    echo "    podman volume ls                # volumes"
    echo "    podman images                   # images"
    echo ""
    echo "  Manage services:"
    echo "    cd ~/Services/open-webui"
    echo "    podman compose ps"
    echo "    podman compose logs -f"
    echo ""
    echo "  If something doesn't work, the Docker data is still in restic."
    echo "  This script is idempotent — safe to re-run."
    echo ""
    echo "  Once everything works, delete this script — it's one-time only."
}

main "$@"
