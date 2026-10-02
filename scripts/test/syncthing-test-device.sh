#!/usr/bin/env bash
#
# syncthing-test-device.sh — run the TEST install as its own Syncthing device,
# receive-only, beside the real machine (extended test, decided 2026-10-02).
#
# Lives in scripts/test/ — nothing under scripts/ is copied into the image.
# Delete it once the test install is retired.
#
# Run as your user on the TEST system after post-install-setup.sh:
#   ~/migration-prep/fedora-cosmic-bluebuild/scripts/test/syncthing-test-device.sh
# Before it: step 2 staged the real machine's config.xml (never its keys) at
# ~/.local/state/syncthing-source-config.xml; step 6 (chezmoi run_once_50)
# generated a NEW identity and started Syncthing with no folders and no peers.
#
# What it does (idempotent; safe to rerun):
#   1. refuses unless this is the test install and its device ID is NOT one the
#      real machine's config knows (never a second "frmwrk")
#   2. adds the peer (*dsktp*) with the addresses the real machine uses
#   3. adds every folder the real machine shares with the peer — same folder ID,
#      label and path — as Receive Only, shared with the peer only
#   4. prints the commands to run ON dsktp, waits for the connection, shows
#      each folder's state
#
# Receive Only: this disk gets the live data but never changes or deletes
# anything on dsktp or the real machine. Local edits show as "Locally Changed";
# the GUI's "Revert Local Changes" restores dsktp's version. Folders can move to
# Send & Receive later, one at a time (turn on versioning on dsktp first).
#
# PEER_MATCH  substring of the peer's device name   (default dsktp)
# WAIT_SECS   how long to wait for the connection    (default 120; 0 = don't wait)
#
set -euo pipefail

ST_DIR="$HOME/.local/state/syncthing"
SRC="${SRC:-$HOME/.local/state/syncthing-source-config.xml}"
export PEER_MATCH="${PEER_MATCH:-dsktp}"
export WAIT_SECS="${WAIT_SECS:-120}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

say "Checking this is the Cosmic Atomic test install"
command -v bootc >/dev/null || die "bootc not found — this is not the Atomic system. Do NOT run on the 4TB Workstation."
grep -q '^VARIANT_ID=.*frmwrk' /usr/lib/os-release || die "os-release VARIANT_ID is not frmwrk"
grep -qs '^TEST_INSTALL=1' /etc/fedora-cosmic-atomic/install-target.env \
    || die "not a test install (TEST_INSTALL=1 missing in /etc/fedora-cosmic-atomic/install-target.env)"
[[ -s "$SRC" ]] || die "no staged config at $SRC — run: sudo post-install-setup.sh --step 2"
[[ -f "$ST_DIR/config.xml" && -f "$ST_DIR/cert.pem" ]] \
    || die "no Syncthing identity in $ST_DIR — run chezmoi apply (run_once_50-syncthing) first"

export ST_CONFIG="$ST_DIR/config.xml" SRC
python3 - <<'PY'
import json, os, sys, time, urllib.request, urllib.error
import xml.etree.ElementTree as ET

def ok(m):  print(f"  \033[0;32m✓\033[0m {m}")
def bad(m): print(f"  \033[0;31m✗\033[0m {m}")
def die(m): print(f"\033[1;31mERROR:\033[0m {m}", file=sys.stderr); sys.exit(1)

peer_match = os.environ["PEER_MATCH"]
wait_secs = int(os.environ["WAIT_SECS"])

gui = ET.parse(os.environ["ST_CONFIG"]).getroot().find("gui")
key = gui.findtext("apikey") or die("no GUI API key in config.xml")
addr = gui.findtext("address") or "127.0.0.1:8384"
base = f"http{'s' if gui.get('tls') == 'true' else ''}://{addr}/rest/"

def api(method, path, body=None):
    req = urllib.request.Request(base + path, method=method,
                                 data=None if body is None else json.dumps(body).encode(),
                                 headers={"X-API-Key": key, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        data = r.read()
        return json.loads(data) if data.strip() else None

for _ in range(30):
    try:
        api("GET", "system/ping"); break
    except (urllib.error.URLError, OSError):
        time.sleep(1)
else:
    die(f"Syncthing API not reachable at {base} — systemctl --user status syncthing.service")

# ── 1. Identity: must be new ───────────────────────────────────────────
src = ET.parse(os.environ["SRC"]).getroot()
src_devices = {d.get("id"): d for d in src.findall("device")}
my_id = api("GET", "system/status")["myID"]
if my_id in src_devices:
    die(f"this device ID ({my_id[:7]}…) is in the real machine's config — a copy of a real identity. "
        "Stop Syncthing, move ~/.local/state/syncthing away, `syncthing generate`, start it, rerun.")
ok(f"new device identity {my_id[:7]}… (not one the real machine knows)")

# ── 2. Peer ────────────────────────────────────────────────────────────
peers = [d for d in src_devices.values() if peer_match in (d.get("name") or "")]
if len(peers) != 1:
    die(f"expected exactly one device named *{peer_match}* in {os.environ['SRC']}, found {len(peers)}")
peer = peers[0]; peer_id = peer.get("id"); peer_name = peer.get("name")
peer_addrs = [a.text for a in peer.findall("address") if a.text] or ["dynamic"]
have_devices = {d["deviceID"] for d in api("GET", "config/devices")}
if peer_id in have_devices:
    ok(f"peer {peer_name} ({peer_id[:7]}…) already configured")
else:
    dev = api("GET", "config/defaults/device")
    dev.update(deviceID=peer_id, name=peer_name, addresses=peer_addrs)
    api("PUT", f"config/devices/{peer_id}", dev)
    ok(f"added peer {peer_name} ({peer_id[:7]}…), addresses {', '.join(peer_addrs)}")

# ── 3. Folders shared with the peer: same ID/label/path, receive-only ──
wanted = [f for f in src.findall("folder")
          if any(d.get("id") == peer_id for d in f.findall("device"))]
skipped = [f.get("id") for f in src.findall("folder") if f not in wanted]
have = {f["id"]: f for f in api("GET", "config/folders")}
for f in wanted:
    fid, label, path = f.get("id"), f.get("label") or f.get("id"), f.get("path")
    if fid in have:
        cur = have[fid]
        devs = cur["devices"]
        if not any(d["deviceID"] == peer_id for d in devs):
            devs.append({"deviceID": peer_id, "introducedBy": "", "encryptionPassword": ""})
        api("PATCH", f"config/folders/{fid}", {"type": "receiveonly", "devices": devs})
        note = "" if cur["path"] == path else f"  (path here {cur['path']}, real machine {path} — left as is)"
        ok(f"folder {fid} '{label}': receive-only, shared with {peer_name}{note}")
    else:
        fol = api("GET", "config/defaults/folder")
        fol.update(id=fid, label=label, path=path, type="receiveonly",
                   devices=[{"deviceID": peer_id, "introducedBy": "", "encryptionPassword": ""}])
        api("PUT", f"config/folders/{fid}", fol)
        exists = os.path.isdir(os.path.expanduser(path))
        ok(f"folder {fid} '{label}' -> {path}: added receive-only"
           + ("" if exists else "  (path not restored — Syncthing downloads it)"))
if skipped:
    print(f"  (not shared with {peer_name} on the real machine, left out: {', '.join(skipped)})")
bad_type = [f["id"] for f in api("GET", "config/folders")
            if f["id"] in {w.get("id") for w in wanted} and f["type"] != "receiveonly"]
if bad_type: die(f"folders not receive-only after configuring: {bad_type}")

# ── 4. dsktp side ──────────────────────────────────────────────────────
name = api("GET", f"config/devices/{my_id}").get("name") or os.uname().nodename
print(f"""
\033[1;34m==>\033[0m ON {peer_name}: add this device and share the folders with it (GUI or CLI):
    syncthing cli config devices add --device-id {my_id} --name {name}""")
for f in wanted:
    print(f"    syncthing cli config folders {f.get('id')} devices add --device-id {my_id}")
print(f"""    Nothing else changes on {peer_name}; its link to the real machine stays as it is.
    Optional before any folder goes Send & Receive later: File Versioning (Staggered) on {peer_name}.
""")

if wait_secs <= 0:
    sys.exit(0)
try:
    input(f"  Press Enter once that is done on {peer_name} (Ctrl+C to stop here) ")
except EOFError:
    pass
print(f"  waiting up to {wait_secs}s for {peer_name} …")
conn = {}
for _ in range(wait_secs):
    conn = api("GET", "system/connections")["connections"].get(peer_id, {})
    if conn.get("connected"): break
    time.sleep(1)
if not conn.get("connected"):
    bad(f"{peer_name} did not connect (tailscale status? device added on {peer_name}?) — rerun to check again")
    sys.exit(1)
ok(f"connected to {peer_name} via {conn.get('type')} at {conn.get('address')}")
if "relay" in (conn.get("type") or ""):
    bad("connection is RELAYED — pin the peer's address to tcp://<tailscale-ip>:22000")
time.sleep(3)
for f in wanted:
    fid = f.get("id")
    s = api("GET", f"db/status?folder={fid}")
    print(f"    {fid:<12} {s.get('state','?'):<10} need {s.get('needFiles',0)} files, "
          f"locally changed {s.get('receiveOnlyChangedFiles',0)}")
print("  Locally changed > 0 after the first scan = restored files differ from dsktp's:"
      " GUI -> folder -> Revert Local Changes.")
PY
