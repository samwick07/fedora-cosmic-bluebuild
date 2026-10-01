#!/usr/bin/env bash
#
# syncthing-2tb-check.sh — ONE-TIME connection test for the 2TB test install.
#
# Lives in scripts/test/ — nothing under scripts/ is copied into the image, so
# this never ships in a build. Delete it after the test passes:
#   git rm scripts/test/syncthing-2tb-check.sh && git commit -m "Remove 2TB Syncthing test"
#
# What it proves: the restored device identity comes up as frmwrk and reaches
# dsktp (directly over Tailscale, ideally). What it guarantees: NO file moves in
# either direction during the test:
#   1. you confirm every folder is paused on dsktp (typed confirmation)
#   2. every folder is paused LOCALLY in config.xml before the daemon starts
#   3. at the end the daemon is stopped and disabled, so swapping the 4TB back
#      in never has two copies of frmwrk talking to dsktp
#
# Run as your user on the TEST system after `post-install-setup.sh`:
#   ~/migration-prep/fedora-cosmic-bluebuild/scripts/test/syncthing-2tb-check.sh
#
set -euo pipefail

ST_DIR="$HOME/.local/state/syncthing"
CONFIG="$ST_DIR/config.xml"
PEER_MATCH="${PEER_MATCH:-dsktp}"     # substring of the desktop's device name
WAIT_SECS="${WAIT_SECS:-90}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*"; FAIL=1; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
FAIL=0

# ── 0. Are we on the test system? ──────────────────────────────────────
say "Checking this is the Cosmic Atomic test install"
command -v bootc >/dev/null || die "bootc not found — this is not the Atomic system. Do NOT run on the 4TB Workstation."
grep -q '^VARIANT_ID=.*frmwrk' /usr/lib/os-release || die "os-release VARIANT_ID is not frmwrk"
if [[ -r /etc/fedora-cosmic-atomic/install-target.env ]] && \
   ! grep -q '^TEST_INSTALL=1' /etc/fedora-cosmic-atomic/install-target.env; then
    die "install-target.env says this is NOT a test install (TEST_INSTALL!=1). This script is for the 2TB test only."
fi
[[ -f "$ST_DIR/cert.pem" && -f "$ST_DIR/key.pem" && -f "$CONFIG" ]] \
    || die "no restored Syncthing identity in $ST_DIR — run post-install-setup.sh step 2 first"
ok "Atomic frmwrk image, restored identity present"

# ── 1. Human gate: dsktp must be paused ────────────────────────────────
cat <<'EOF'

  BEFORE CONTINUING, on dsktp:
    Open the Syncthing GUI there and confirm EVERY folder shared with
    "brknwg@frmwrk" shows "Paused" (Actions > Pause All Folders is fine).
    Leave them paused until you are back on the 4TB Workstation.

EOF
read -rp "  Type PAUSED once every folder on dsktp is paused: " answer
[[ "$answer" == "PAUSED" ]] || die "not confirmed — nothing was started"

# ── 2. Stop the daemon, pause every folder locally ─────────────────────
say "Stopping Syncthing (if running) and pausing every folder locally"
systemctl --user stop syncthing.service 2>/dev/null || true
pkill -u "$USER" -x syncthing 2>/dev/null || true
sleep 1
cp -a "$CONFIG" "$CONFIG.pre-2tb-test"
python3 - "$CONFIG" <<'PY'
import sys, xml.etree.ElementTree as ET
p = sys.argv[1]; t = ET.parse(p); r = t.getroot()
n = 0
for f in r.findall('folder'):
    f.set('paused', 'true'); n += 1
t.write(p, encoding='utf-8', xml_declaration=False)
print(f"  paused {n} folders in config.xml")
PY
ok "backup: $CONFIG.pre-2tb-test"

# ── 3. Start and query the REST API ────────────────────────────────────
read -r API_KEY GUI_ADDR < <(python3 - "$CONFIG" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot(); g = r.find('gui')
print(g.findtext('apikey') or '', g.findtext('address') or '127.0.0.1:8384')
PY
)
[[ -n "$API_KEY" ]] || die "no GUI API key in config.xml"
API="http://${GUI_ADDR}/rest"
api() { curl -fsS -H "X-API-Key: $API_KEY" "$API/$1"; }

say "Starting Syncthing (folders paused)"
systemctl --user start syncthing.service
for _ in $(seq 1 30); do api system/ping >/dev/null 2>&1 && break; sleep 1; done
api system/ping >/dev/null 2>&1 || die "Syncthing API did not come up at $API"

MY_ID=$(api system/status | python3 -c 'import json,sys; print(json.load(sys.stdin)["myID"])')
ok "local device ID: ${MY_ID:0:7}…  (should match frmwrk's ID on dsktp)"

UNPAUSED=$(api config/folders | python3 -c 'import json,sys; print(sum(1 for f in json.load(sys.stdin) if not f.get("paused")))')
[[ "$UNPAUSED" == 0 ]] && ok "all local folders paused" || bad "$UNPAUSED local folder(s) NOT paused"

PEER_ID=$(api config/devices | python3 -c "
import json,sys
for d in json.load(sys.stdin):
    if '$PEER_MATCH' in d.get('name',''): print(d['deviceID']); break")
[[ -n "$PEER_ID" ]] || die "no device named *$PEER_MATCH* in config"
ok "peer: ${PEER_ID:0:7}… ($PEER_MATCH)"

say "Waiting up to ${WAIT_SECS}s for $PEER_MATCH to connect"
CONN=""
for _ in $(seq 1 "$WAIT_SECS"); do
    CONN=$(api system/connections | python3 -c "
import json,sys
c = json.load(sys.stdin)['connections'].get('$PEER_ID', {})
print('yes' if c.get('connected') else 'no', c.get('address','-'), c.get('type','-'))")
    [[ "$CONN" == yes* ]] && break
    sleep 1
done
read -r C_OK C_ADDR C_TYPE <<<"$CONN"
if [[ "$C_OK" == yes ]]; then
    ok "connected to $PEER_MATCH via $C_TYPE at $C_ADDR"
    [[ "$C_TYPE" == *relay* ]] && bad "connection is RELAYED — set dsktp's address to tcp://<tailscale-ip>:22000 (docs/clean-room.md rule 7)"
    [[ "$C_ADDR" == 100.* ]] && ok "direct over Tailscale" || echo "  (address is not a 100.x Tailscale IP — works, but consider pinning it)"
else
    bad "did not connect within ${WAIT_SECS}s (tailscale status? is Syncthing running on dsktp?)"
fi

# ── 4. Always leave Syncthing off on the test system ───────────────────
say "Stopping and disabling Syncthing on the test system"
systemctl --user stop syncthing.service
systemctl --user disable syncthing.service 2>/dev/null || true
ok "stopped + disabled — safe to swap the 4TB back in"

echo
if [[ "$FAIL" == 0 ]]; then
    printf '\033[1;32mPASS\033[0m — identity and connection work; no data was exchanged.\n'
    echo "Keep dsktp's folders paused until the 4TB Workstation is booted again, then resume them there."
    echo "After the 2TB test is complete, delete this script (see header)."
else
    printf '\033[1;31mFAIL\033[0m — see ✗ lines above. Nothing was synced either way.\n'
    exit 1
fi
