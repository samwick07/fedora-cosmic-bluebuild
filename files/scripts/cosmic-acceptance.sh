#!/usr/bin/env bash
#
# cosmic-acceptance — spec section 6 on the installed machine, with nothing to tick by hand
# (spec L5). It reads live state and the evidence the machine records as it is used: the
# journal (boots, logins, sleeps), cosmic-evidence records (battery and Bluetooth around
# every sleep; routes and DNS whenever a VPN tunnel comes up), CUPS history, the nightly
# restore probe.
#
#   sudo cosmic-acceptance              image layer, and the user layer once chezmoi has run
#   sudo cosmic-acceptance --exercise   first the active trials, with you present: the machine
#                                       SUSPENDS and HIBERNATES (an RTC alarm wakes it), switches
#                                       power profiles, prints one test page, hands the CAC to
#                                       the VM and back both ways, starts every GUI app briefly
#   sudo cosmic-acceptance --record     quiet, for the nightly job: the result goes to
#                                       /var/lib/cosmic-acceptance/latest.txt, and known-good
#                                       deployments are pinned (spec L3)
#   sudo cosmic-acceptance --pin        pin the booted deployment now (if nothing FAILs)
#
# PASS / FAIL; WAIT = evidence still to come from normal use (the line says what produces
# it); YOU = a secret only you can type (everything before it is checked); INFO = a figure.
# Evidence once seen is remembered for this installation. Exit 1 if anything FAILed.
set -uo pipefail

[[ $EUID -eq 0 ]] || { echo "run with sudo (reads the journal, bootc, btrfs and LUKS state)" >&2; exit 2; }
EXERCISE=0; RECORD=0; PIN=0; USER_LAYER=auto
for a in "$@"; do
    case $a in
        --user) USER_LAYER=1 ;; --exercise) EXERCISE=1 ;; --record) RECORD=1 ;; --pin) PIN=1 ;;
        *) echo "usage: cosmic-acceptance [--exercise] [--record] [--pin] [--user]" >&2; exit 2 ;;
    esac
done
U="${SUDO_USER:-$(getent passwd 1000 | cut -d: -f1)}"
UID_U=$(id -u "$U")
UHOME=$(getent passwd "$U" | cut -d: -f6)
BREW_PREFIX=/home/linuxbrew/.linuxbrew
STATE=/var/lib/cosmic-acceptance
SEEN="$STATE/seen/$(cat /etc/machine-id)"     # evidence is per installation
NSTATE=/var/lib/cosmic-nightly
VM="${WIN11_VM:-Win11VM}"
MSG_START=6bbd95ee977941e497c48be27c254128     # systemd-sleep: SD_MESSAGE_SLEEP_START
MSG_STOP=8811e6df2a8e40f58a94cea26f8ebf14      #                SD_MESSAGE_SLEEP_STOP
mkdir -p "$SEEN" "$STATE/clean"
# shellcheck disable=SC1091
. /usr/lib/os-release
NPASS=0; NFAIL=0; NWAIT=0; NYOU=0
OUT=$(mktemp); trap 'rm -f "$OUT"' EXIT

# ── output ───────────────────────────────────────────────────────────
emit() {
    local line; line=$(printf '%-5s %-6s %s' "$1" "$2" "$3")
    echo "$line" >> "$OUT"; [[ $RECORD == 1 ]] || echo "$line"
}
detail() { sed -e 's/^/             /' | head -8 | while IFS= read -r l; do echo "$l" >> "$OUT"; [[ $RECORD == 1 ]] || echo "$l"; done; }
section() { echo >> "$OUT"; echo "== $*" >> "$OUT"; [[ $RECORD == 1 ]] || { echo; echo "== $*"; }; }
pass()  { emit PASS "$1" "$2"; NPASS=$((NPASS + 1)); }
fail()  { emit FAIL "$1" "$2"; NFAIL=$((NFAIL + 1)); }
wait_() { emit WAIT "$1" "$2 — $3"; NWAIT=$((NWAIT + 1)); }
you()   { emit YOU "$1" "$2"; NYOU=$((NYOU + 1)); }
info()  { emit INFO "$1" "$2"; }

# check ID DESC CMD... — live state: exit 0 = PASS, else FAIL (output shown)
check() {
    local id="$1" desc="$2" out; shift 2
    if out=$("$@" 2>&1); then pass "$id" "$desc"; else fail "$id" "$desc"; [[ -n "$out" ]] && detail <<<"$out"; fi
}
# evidence ID DESC HOW CMD... — exit 0 = seen (remembered from then on), 1 = not yet (WAIT,
# HOW says what produces it), 2 = seen and wrong (FAIL). First output line = the figure.
evidence() {
    local id="$1" desc="$2" how="$3" out rc key; shift 3
    key="$SEEN/$id-$(printf %s "$desc" | md5sum | cut -c1-8)"
    if [[ -f "$key" ]]; then pass "$id" "$desc (seen $(head -1 "$key"))"; return; fi
    out=$("$@" 2>&1); rc=$?
    case $rc in
        0) { date +%F; echo "$out"; } > "$key"; pass "$id" "$desc${out:+ — $(head -1 <<<"$out")}" ;;
        2) fail "$id" "$desc"; [[ -n "$out" ]] && detail <<<"$out" ;;
        *) wait_ "$id" "$desc" "$how${out:+ [$(head -1 <<<"$out")]}" ;;
    esac
}

as_user() {
    runuser -u "$U" -- env HOME="$UHOME" USER="$U" XDG_RUNTIME_DIR="/run/user/$UID_U" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_U/bus" \
        PATH="$UHOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$BREW_PREFIX/bin" "$@"
}
# The user's graphical session (for apps and virt-viewer): its Wayland socket.
WAYLAND=$(find "/run/user/$UID_U" -maxdepth 1 -name 'wayland-[0-9]' -printf '%f\n' 2>/dev/null | head -1)
as_session() {
    as_user env WAYLAND_DISPLAY="$WAYLAND" XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=COSMIC \
        XDG_DATA_DIRS="$UHOME/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share" "$@"
}
enabled() { local u; for u in "$@"; do [[ "$(systemctl is-enabled "$u" 2>/dev/null)" == enabled ]] || { echo "$u is not enabled"; return 1; }; done; }
age_h() { local f="$NSTATE/last-$1"; [[ -r "$f" ]] && echo $(( ($(date +%s) - $(cat "$f")) / 3600 )) || echo 9999; }
journal_since() { journalctl -q --no-pager -o cat --since "@$1" "${@:2}" 2>/dev/null; }

# ── what the journal says about sleep (one pass, parsed in Python) ───
# Cycles = systemd-sleep START…STOP pairs (sub-operations from START's text: a
# suspend-then-hibernate logs 'suspend', then 'hibernate'); lid events from logind;
# battery and Bluetooth records from cosmic-evidence.
declare -A SL=()
read_sleep_facts() {
    local k v
    while IFS='=' read -r k v; do [[ -n "$k" ]] && SL[$k]="$v"; done < <(
    journalctl -o json --no-pager -q "MESSAGE_ID=$MSG_START" + "MESSAGE_ID=$MSG_STOP" \
        + SYSLOG_IDENTIFIER=systemd-logind + SYSLOG_IDENTIFIER=cosmic-evidence 2>/dev/null |
    python3 -c '
import json, re, statistics, sys, time
START, STOP = sys.argv[1], sys.argv[2]
ev = []
for line in sys.stdin:
    try: e = json.loads(line)
    except ValueError: continue
    m = e.get("MESSAGE")
    if isinstance(m, list): m = bytes(m).decode("utf-8", "replace")
    if not m: continue
    t = int(e["__REALTIME_TIMESTAMP"]) / 1e6
    mid = e.get("MESSAGE_ID", "")
    if mid == START:
        r = re.search(r"operation .([a-z-]+).", m); ev.append((t, "start", r.group(1) if r else "?"))
    elif mid == STOP:
        ev.append((t, "stop", "ok" if int(e.get("PRIORITY", 6)) > 3 else "failed"))
    elif e.get("SYSLOG_IDENTIFIER") == "systemd-logind":
        if m.startswith("Lid closed"): ev.append((t, "lid", "closed"))
        elif m.startswith("Lid opened"): ev.append((t, "lid", "opened"))
    elif e.get("SYSLOG_IDENTIFIER") == "cosmic-evidence":
        ev.append((t, "evi", m))
ev.sort(key=lambda x: x[0])
cycles, cur, lid_closed_at = [], None, None
for t, kind, val in ev:
    if kind == "lid":
        lid_closed_at = t if val == "closed" else None
    elif kind == "start":
        if cur is None: cur = {"t0": t, "ops": [], "lid": lid_closed_at is not None and t - lid_closed_at < 120}
        cur["ops"].append(val)
    elif kind == "stop" and cur is not None:
        cur["t1"], cur["ok"] = t, val == "ok"; cycles.append(cur); cur = None
ok = [c for c in cycles if c["ok"]]
recent_fail = [c for c in cycles if not c["ok"] and c["t1"] > time.time() - 14 * 86400]
print("suspends=%d" % sum(1 for c in ok if "suspend" in c["ops"]))
print("hibernates=%d" % sum(1 for c in ok if "hibernate" in c["ops"]))
print("lid_suspend=%d" % sum(1 for c in ok if c["lid"] and "suspend" in c["ops"]))
print("lid_hibernate=%d" % sum(1 for c in ok if c["lid"] and "hibernate" in c["ops"]))
print("failed_recent=%s" % ",".join(time.strftime("%F %R", time.localtime(c["t1"])) for c in recent_fail))
# Battery drain per sleep, on battery only, sleeps of 10 min or more.
def kv(m): return dict(x.split("=", 1) for x in m.split()[1:] if "=" in x)
pre, d_susp, d_hib = None, [], []
for t, kind, val in ev:
    if kind != "evi": continue
    if val.startswith("sleep-pre "): pre = kv(val)
    elif val.startswith("sleep-post ") and pre:
        post = kv(val)
        try:
            e0, e1, full, slept = int(pre["energy"]), int(post["energy"]), int(post["full"]), int(post["slept"])
        except (KeyError, ValueError): pre = None; continue
        if pre.get("ac") == "0" and post.get("ac") == "0" and slept >= 600 and full > 0:
            rate = (e0 - e1) / full * 100 / (slept / 3600)
            hib = any(c["ops"] and "hibernate" in c["ops"] and int(pre["t"]) <= c["t0"] <= int(post["t"]) for c in cycles)
            (d_hib if hib else d_susp).append(rate)
        pre = None
if d_susp: print("drain_suspend=%.2f %%/h (median of %d)" % (statistics.median(d_susp), len(d_susp)))
if d_hib:  print("drain_hibernate=%.2f %%/h (median of %d, suspend phase included)" % (statistics.median(d_hib), len(d_hib)))
bt = [v for t, k, v in ev if k == "evi" and v.startswith("bt-recheck ")]
bt = [b for b in bt if kv(b).get("wanted", "0") != "0"]
if bt: print("bt_last=%s" % bt[-1])
print("bt_ok=%d" % sum(1 for b in bt if kv(b)["wanted"] == kv(b)["back"]))
print("bt_last3_bad=%d" % (len(bt) >= 3 and all(kv(b)["wanted"] != kv(b)["back"] for b in bt[-3:])))
tun = [v for t, k, v in ev if k == "evi" and v.startswith("tunnel ") and "gone within" not in v]
print("tunnels=%d" % len(tun))
good = [x for x in tun if all(kv(x).get(p) in ("ok", "skip") for p in ("host", "dev", "container"))]
full = [x for x in good if kv(x).get("dev") == "ok" and kv(x).get("container") == "ok"]
if tun:  print("tunnel_last=%s" % tun[-1])
if full: print("tunnel_full=%s" % full[-1])
' "$MSG_START" "$MSG_STOP")
}

# ── evidence functions (0 seen, 1 not yet, 2 wrong) ──────────────────
ev_boots() {  # P1: boots in which the LUKS volumes were unlocked and the greeter started
    local id n=0 total=0
    for id in $(journalctl --list-boots -o json 2>/dev/null | python3 -c '
import json, sys
try: boots = json.load(sys.stdin)
except ValueError: boots = []
for b in boots[-15:]: print(b["boot_id"])'); do
        total=$((total + 1))
        journalctl -b "$id" -q -o cat -u 'systemd-cryptsetup@*' 2>/dev/null | grep -q . || continue
        journalctl -b "$id" -q -o cat -u cosmic-greeter.service -u greetd.service 2>/dev/null | grep -q . || continue
        n=$((n + 1))
    done
    echo "$n of the last $total boots"; (( n >= 3 )) && return 0 || return 1
}
ev_logins() {  # D1
    local n t
    n=$(journalctl -q -o cat -t cosmic-session-wait 2>/dev/null | grep -c '^login: ')
    t=$(journalctl -q -o cat -t cosmic-session-wait 2>/dev/null | grep -c 'still active')
    echo "$n logins, $t after the wait timed out"; (( n >= 10 )) && return 0 || return 1
}
no_black_screen() {  # D1, live: the failure mode the workaround exists for
    local n; n=$(journalctl -q -o short-iso --no-pager _COMM=cosmic-comp 2>/dev/null | grep -c 'Backend initialized without output')
    (( n == 0 )) || { echo "$n time(s); journalctl _COMM=cosmic-comp -g 'without output'"; return 1; }
}
sl() { local v="${SL[$1]:-0}"; echo "$v counted"; (( v >= $2 )) && return 0 || return 1; }
ev_bt() {  # P3: the latest reconnect check after a resume
    [[ -n "${SL[bt_last]:-}" ]] || { echo "no resume yet with a Bluetooth device connected"; return 1; }
    # One device switched off during a sleep is normal; three misses in a row are not.
    [[ "${SL[bt_last3_bad]:-0}" == 1 ]] && { echo "the last 3 resumes: ${SL[bt_last]}"; return 2; }
    [[ "${SL[bt_ok]:-0}" -ge 1 ]] || return 1
    echo "${SL[bt_ok]} resume(s) with every device back"; return 0
}
ev_wifi() { nmcli -t -f TYPE,STATE device 2>/dev/null | grep -q '^wifi:connected' && { echo "connected now"; return 0; }; return 1; }
ext_display() {  # an external connector that is connected and lit
    local c
    for c in /sys/class/drm/card*-*; do
        [[ "$c" == *eDP* || ! -r "$c/status" ]] && continue
        [[ "$(cat "$c/status")" == connected && "$(cat "$c/enabled" 2>/dev/null)" == enabled ]] && { echo "${c##*/}"; return 0; }
    done
    return 1
}
ev_webcam() {  # VIDIOC_QUERYCAP: a device that can capture
    python3 - <<'PY'
import fcntl, glob, struct, sys
for dev in sorted(glob.glob("/dev/video*")):
    try:
        with open(dev, "rb") as f:
            buf = bytearray(104); fcntl.ioctl(f, 0x80685600, buf)
    except OSError: continue
    card = buf[16:48].split(b"\0")[0].decode(errors="replace")
    caps = struct.unpack_from("<I", buf, 88)[0]
    if caps & 0x1: print(f"{dev}: {card}"); sys.exit(0)
sys.exit(1)
PY
}
ev_audio() {
    [[ -S /run/user/$UID_U/pipewire-0 ]] || { echo "no session"; return 1; }
    as_user wpctl status 2>/dev/null | awk '/Sinks:/{f=1; next} f && /(Sources|Filters|Streams):/{exit} f && /[0-9]+\./' \
        | grep -vi dummy | grep -q . && { echo "a sink"; return 0; }
    return 2
}
ev_print() { lpstat -W completed -o 2>/dev/null | grep -q . && { lpstat -W completed -o | tail -1 | awk '{print $1}'; return 0; }; return 1; }
ev_restore_probe() {  # J1 compares one home file and the manifest from each copy, nightly
    [[ -r /etc/fedora-cosmic-atomic/nightly.env ]] || { echo "backups not set up yet (M11)"; return 1; }
    local l o; l=$(age_h restore-probe-local); o=$(age_h restore-probe-offsite)
    (( l < 9999 && o < 9999 )) && { echo "DAS ${l} h ago, B2 ${o} h ago"; return 0; }
    echo "DAS $( ((l == 9999)) && echo never || echo "$l h ago"), B2 $( ((o == 9999)) && echo never || echo "$o h ago")"; return 1
}
ev_tunnel() {
    (( ${SL[tunnels]:-0} > 0 )) || return 1
    [[ -n "${SL[tunnel_full]:-}" ]] && { echo "${SL[tunnel_full]#tunnel }"; return 0; }
    echo "${SL[tunnel_last]#tunnel }"; return 2
}
ev_ddc() {  # P11, as the user (brew's ddcutil), while a monitor is connected
    ext_display >/dev/null || { echo "no external display connected now"; return 1; }
    [[ -x $BREW_PREFIX/bin/ddcutil ]] || { echo "ddcutil not installed (Brewfile)"; return 2; }
    as_user "$BREW_PREFIX/bin/ddcutil" detect --terse 2>/dev/null | grep -q '^Display' && { echo "a DDC/CI display"; return 0; }
    echo "connected, but no DDC/CI answer (enable DDC/CI in the monitor's menu)"; return 2
}
card_certs() {  # V3: the card's certificates through a PKCS#11 module (no PIN needed)
    local out; out=$("$@" 2>/dev/null) || true
    grep -q "Certificate Object" <<<"$out" && { echo "$(grep -c 'Certificate Object' <<<"$out") certificate(s)"; return 0; }
    timeout 10 opensc-tool -l 2>/dev/null | grep -q ' Yes ' || { echo "no card in a reader"; return 1; }
    return 2
}

# ── exercise: active trials, with the user present ───────────────────
wait_resume() {  # T0 TIMEOUT: has systemd-sleep logged a return since T0?
    local t0="$1" end=$(( $(date +%s) + $2 ))
    while (( $(date +%s) < end )); do
        journal_since "$t0" "MESSAGE_ID=$MSG_STOP" | grep -q 'returned from sleep' && return 0
        journal_since "$t0" "MESSAGE_ID=$MSG_STOP" | grep -q 'Failed to put' && return 1
        sleep 5
    done
    return 1
}
ex_sleep() {  # ID OP SECONDS
    local id="$1" op="$2" secs="$3" t0 bt
    t0=$(date +%s)
    rtcwake -m no -s "$secs" >/dev/null 2>&1 || { fail "$id" "$op: could not set the RTC alarm"; return; }
    echo "   $op now; the RTC alarm wakes it in ${secs} s$([[ $op == hibernate ]] && echo ' (if it is still off 5 min later, press the power button)')"
    systemctl "$op"
    if wait_resume "$t0" $((secs + 900)); then
        pass "$id" "$op → resume ($(( $(date +%s) - t0 )) s)"
    else
        fail "$id" "$op → resume"; journal_since "$t0" "MESSAGE_ID=$MSG_STOP" | detail
    fi
    rtcwake -m disable >/dev/null 2>&1
    bt=$(journal_since "$t0" -t cosmic-evidence | grep '^sleep-pre' | tail -1 | sed -n 's/.* bt=//p')
    if [[ -n "$bt" && "$bt" != - ]]; then echo "   waiting 50 s for Bluetooth to reconnect"; sleep 50; fi
    sleep 5
}
ex_power() {
    local orig p ok=1 tried=()
    orig=$(powerprofilesctl get 2>/dev/null) || { fail P8 "powerprofilesctl does not answer"; return; }
    for p in $(powerprofilesctl list 2>/dev/null | sed -n 's/^[* ] *\([a-z-]*\):$/\1/p'); do
        powerprofilesctl set "$p" && [[ "$(powerprofilesctl get)" == "$p" ]] || ok=0
        tried+=("$p")
    done
    powerprofilesctl set "$orig"
    (( ok == 1 && ${#tried[@]} >= 2 )) && pass P8 "power profiles switch (${tried[*]}; back to $orig)" || fail P8 "power profile switch (${tried[*]:-none listed})"
}
ex_print() {
    ev_print >/dev/null && return 0
    local dest job end
    dest=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
    [[ -n "$dest" ]] || dest=$(lpstat -e 2>/dev/null | head -1)
    [[ -n "$dest" ]] || { wait_ P10 "test page" "no printer on this network"; return; }
    job=$(lp -d "$dest" -t "cosmic-acceptance test page" /usr/share/cups/data/testprint 2>&1 | grep -o "$dest-[0-9]*")
    [[ -n "$job" ]] || { fail P10 "test page to $dest not accepted"; return; }
    end=$(( $(date +%s) + 180 ))
    while (( $(date +%s) < end )); do
        lpstat -W completed -o "$dest" 2>/dev/null | grep -q "^$job " && { pass P10 "test page printed on $dest ($job)"; return; }
        sleep 5
    done
    fail P10 "test page $job did not complete in 3 min"; lpstat -o "$dest" | detail
}
guest_sees_card() {  # in Win11VM: guest agent certutil, else QEMU's own USB list
    local pid out name="$1"
    if virsh -c qemu:///system qemu-agent-command "$VM" '{"execute":"guest-ping"}' >/dev/null 2>&1; then
        pid=$(virsh -c qemu:///system qemu-agent-command "$VM" \
            '{"execute":"guest-exec","arguments":{"path":"certutil.exe","arg":["-scinfo","-silent"],"capture-output":true}}' \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["return"]["pid"])') || return 1
        sleep 8
        out=$(virsh -c qemu:///system qemu-agent-command "$VM" "{\"execute\":\"guest-exec-status\",\"arguments\":{\"pid\":$pid}}" \
            | python3 -c 'import base64,json,sys; b=base64.b64decode(json.load(sys.stdin)["return"].get("out-data","")); print(b.replace(b"\0", b"").decode("utf-8", "replace"))')
        grep -q SCARD_STATE_PRESENT <<<"$out" && { echo "certutil -scinfo: card present"; return 0; }
        return 1
    fi
    virsh -c qemu:///system qemu-monitor-command "$VM" --hmp 'info usb' 2>/dev/null | grep -qiF "$name" && { echo "in the VM's USB list"; return 0; }
    return 1
}
host_sees_card() { local _; for _ in 1 2 3 4 5 6; do timeout 10 opensc-tool -l 2>/dev/null | grep -q ' Yes ' && return 0; sleep 5; done; return 1; }
ex_cac_vm() {
    local was_running=1 dev name viewer out
    virsh -c qemu:///system dominfo "$VM" >/dev/null 2>&1 || { wait_ V2 "CAC into $VM" "the VM is not defined yet (M7)"; return; }
    dev=$(grep -l '^0b$' /sys/bus/usb/devices/*:*/bInterfaceClass 2>/dev/null | head -1)
    [[ -n "$dev" ]] || { wait_ V2 "CAC into $VM" "plug in the CAC reader with the card and run --exercise again"; return; }
    dev=$(dirname "$dev"); dev=${dev%:*}                      # interface → its USB device
    name=$(cat "$dev/product" 2>/dev/null || echo "Smart Card")
    host_sees_card || { wait_ V2 "CAC into $VM" "insert the card and run --exercise again"; return; }
    if [[ "$(virsh -c qemu:///system domstate "$VM")" != running ]]; then
        was_running=0; echo "   starting $VM (shut down again afterwards)"
        virsh -c qemu:///system start "$VM" >/dev/null; sleep 90
    fi
    # Default: win11-cac (host-side hostdev).
    if win11-cac attach "$VM" >/dev/null 2>&1 && sleep 10 && out=$(guest_sees_card "$name"); then
        pass V2 "win11-cac attach: the guest sees the card ($out)"
    else
        fail V2 "win11-cac attach: the guest does not see the card"
    fi
    win11-cac detach "$VM" >/dev/null 2>&1
    host_sees_card && pass V2 "win11-cac detach: the host's pcscd has the card again" || fail V2 "win11-cac detach: the host does not see the card"
    # Fallback: SPICE redirection, as the click in virt-viewer does it (class 0x0b = smart card).
    if [[ -n "$WAYLAND" ]]; then
        # The host's pcscd holds the reader through libusb; SPICE cannot claim it until pcscd lets go.
        systemctl stop pcscd.socket pcscd.service 2>/dev/null
        as_session virt-viewer -c qemu:///system --spice-usbredir-redirect-on-connect='0x0b,-1,-1,-1,1' "$VM" >/dev/null 2>&1 &
        viewer=$!; sleep 20
        if out=$(guest_sees_card "$name"); then pass V2 "SPICE redirect: the guest sees the card ($out)"; else fail V2 "SPICE redirect: the guest does not see the card"; fi
        kill "$viewer" 2>/dev/null; pkill -u "$U" -f "virt-viewer.*$VM" 2>/dev/null; sleep 5
        systemctl start pcscd.socket
        host_sees_card && pass V2 "SPICE un-redirect (viewer closed): the host has the card again" || fail V2 "SPICE un-redirect: the host does not see the card"
    else
        wait_ V2 "SPICE redirect" "log in to the desktop and run --exercise from there"
    fi
    [[ $was_running == 0 ]] && virsh -c qemu:///system shutdown "$VM" >/dev/null 2>&1
    you V2 "the Windows app signs in with the card (attach with: sudo win11-cac attach; your PIN)"
}
ex_apps() {  # A-rows: every GUI app starts and stays up for 15 s (already running = fine, left alone)
    [[ -n "$WAYLAND" ]] || { wait_ A "GUI apps start" "log in to the desktop and run --exercise from there"; return; }
    local app running box cmd box_cmd
    running=$(flatpak ps --columns=application 2>/dev/null; as_user flatpak ps --columns=application 2>/dev/null)
    while read -r app; do
        [[ -z "$app" || "$app" == \#* ]] && continue
        if grep -qx "$app" <<<"$running"; then pass A "$app (already running)"; continue; fi
        as_session flatpak run "$app" >/dev/null 2>&1 &
        sleep 15
        if as_user flatpak ps --columns=application 2>/dev/null | grep -qx "$app"; then pass A "$app starts"; else fail A "$app does not stay up"; fi
        as_user flatpak kill "$app" >/dev/null 2>&1
    done < /usr/share/fedora-cosmic-atomic/flatpaks.list
    for box_cmd in dev:google-chrome dev:code dev:antigravity dev:ghostty claude:claude-desktop; do
        box=${box_cmd%%:*}; cmd=${box_cmd#*:}
        as_user podman container exists "$box" 2>/dev/null || { fail A "$cmd: box $box missing"; continue; }
        if as_user podman exec "$box" pgrep -f "(^|/)$cmd( |$)" >/dev/null 2>&1; then pass A "$cmd in $box (already running)"; continue; fi
        as_session distrobox enter "$box" -- "$cmd" >/dev/null 2>&1 &
        sleep 20
        if as_user podman exec "$box" pgrep -f "(^|/)$cmd( |$)" >/dev/null 2>&1; then pass A "$cmd starts in $box"; else fail A "$cmd does not stay up in $box"; fi
        as_user podman exec "$box" pkill -f "(^|/)$cmd( |$)" >/dev/null 2>&1
    done
}

# ── run ──────────────────────────────────────────────────────────────
section "$(hostname), VARIANT_ID=${VARIANT_ID:-?}, $(date '+%F %R')$([[ $RECORD == 1 ]] && echo ' (nightly record)')"

if [[ $EXERCISE == 1 ]]; then
    section "exercise (you present; the machine suspends and hibernates)"
    echo "   save your work: suspend in 15 s (Ctrl+C to stop)"; sleep 15
    ex_sleep P3 suspend 60
    ex_sleep P2 hibernate 180
    ex_power
    ex_print
    ex_cac_vm
    ex_apps
fi

read_sleep_facts

section "image layer — live state"
check L1 "booted from the signed image (ostree-image-signed)" sh -c \
    'rpm-ostree status --booted --json | python3 -c "import json,sys; d=json.load(sys.stdin)[\"deployments\"][0]; r=d.get(\"container-image-reference\",\"\"); print(r); sys.exit(0 if r.startswith(\"ostree-image-signed:\") and \"fedora-cosmic-\" in r else 1)"'
check L1 "first-boot services succeeded (signed origin, hibernation kargs, net box)" sh -c \
    'for u in cosmic-signed-origin cosmic-hibernation cosmic-net-box; do systemctl is-failed --quiet $u && { echo "$u failed"; exit 1; }; done; exit 0'
check F2 "Secure Boot off (kernel lockdown would block hibernation; firmware setup F2 → Security)" sh -c \
    'l=$(bootctl status 2>/dev/null | grep -i "secure boot:"); echo "$l" | grep -qi disabled || { echo "${l:-bootctl reports no Secure Boot state}"; exit 1; }'
check P2 "kernel lockdown is none" sh -c 'grep -q "\[none\]" /sys/kernel/security/lockdown 2>/dev/null || { cat /sys/kernel/security/lockdown 2>/dev/null; exit 1; }'
check P2 "resume= and two rd.luks.uuid= on the kernel command line" sh -c \
    'c=$(cat /proc/cmdline); echo "$c" | grep -q "resume=" && [ "$(echo "$c" | grep -o "rd.luks.uuid=" | wc -l)" -ge 2 ] || { echo "$c"; exit 1; }'
check P2 "swap active and at least as large as RAM" sh -c \
    'ram=$(awk "/MemTotal/{print \$2*1024}" /proc/meminfo); sw=$(swapon --show=SIZE --bytes --noheadings | awk "{s+=\$1} END{print s+0}"); [ "$sw" -ge "$ram" ] || { echo "swap $sw < RAM $ram"; exit 1; }'
check P2 "lid closes into suspend-then-hibernate" sh -c 'systemd-analyze cat-config systemd/logind.conf | grep -q "^HandleLidSwitch=suspend-then-hibernate"'
check P2 "SELinux hibernation module loaded" sh -c 'semodule -l | grep -qx systemd_hibernate'
check P2 "sleep recorder enabled (battery, Bluetooth)" enabled cosmic-evidence-sleep.service
check P2 "no failed sleep in the last 14 days" sh -c "[ -z '${SL[failed_recent]:-}' ] || { echo 'failed at: ${SL[failed_recent]:-}'; exit 1; }"
check P1 "graphical LUKS prompt (rhgb quiet)" sh -c 'grep -qw rhgb /proc/cmdline && grep -qw quiet /proc/cmdline'
check D1 "no black screen recorded (cosmic-comp: Backend initialized without output)" no_black_screen
check S2e "/var/home is a btrfs subvolume (daily snapshot, consistent backups)" sh -c \
    '[ "$(stat -f -c %T /var/home)" = btrfs ] && btrfs subvolume show /var/home >/dev/null'
check J1 "nightly job and catch-up timers enabled" enabled cosmic-nightly.timer cosmic-nightly-catchup.timer
check J1 "nightly job dry run" sh -c 'cosmic-nightly --dry-run >/dev/null'
check L2 "no second updater (bootc-fetch-apply-updates, brew timers)" sh -c \
    'for t in bootc-fetch-apply-updates.timer brew-update.timer brew-upgrade.timer; do [ "$(systemctl is-enabled $t 2>/dev/null)" != enabled ] || { echo "$t enabled"; exit 1; }; done'
check N1 "system flatpaks from the image's list installed" bash -c \
    'm=$(comm -13 <(flatpak list --system --app --columns=application | sort -u) <(grep -v "^#" /usr/share/fedora-cosmic-atomic/flatpaks.list | sed "/^$/d" | sort -u)); [ -z "$m" ] || { echo "missing: $m"; exit 1; }'
check N3 "tailscaled running" systemctl is-active --quiet tailscaled
check V1 "libvirt sockets enabled" enabled virtqemud.socket virtnetworkd.socket virtstoraged.socket
check V1 "$U is in the libvirt group" sh -c "id -nG '$U' | tr ' ' '\n' | grep -qx libvirt"
check V1 "virt-manager, virt-viewer, SPICE USB redirection installed" rpm -q virt-manager virt-viewer qemu-device-usb-redirect
check V4 "DoD roots in the system trust (offline)" sh -c 'n=$(trust list | grep -ci dod); [ "$n" -ge 10 ] || { echo "only $n"; exit 1; }'
check V3 "pcscd socket enabled" enabled pcscd.socket
check V3 "Firefox's PKCS#11 path: p11-kit proxy in the system NSS db, OpenSC registered" sh -c \
    'grep -qs p11-kit-proxy /etc/pki/nssdb/pkcs11.txt && test -e /usr/share/p11-kit/modules/opensc.module'
check N4 "net box created by cosmic-net-box" sh -c 'podman container exists net || { systemctl status cosmic-net-box --no-pager -n 5; exit 1; }'
check C1c "nmap, mtr, tcpdump wrappers (run in the net box)" sh -c 'for t in nmap mtr tcpdump; do [ -x /usr/local/bin/$t ] || { echo "missing /usr/local/bin/$t"; exit 1; }; done'
if compgen -G '/var/lib/net-box/installers/cisco-secure-client-*.sh' >/dev/null; then
    check N4 "Cisco agent runs in the net box and answers" sh -c \
        'podman exec net systemctl is-active --quiet vpnagentd && podman exec net /opt/cisco/secureclient/bin/vpn state 2>&1 | grep -qi "state:" || { podman exec net /opt/cisco/secureclient/bin/vpn state 2>&1 | tail -3; exit 1; }'
else
    wait_ N4 "Cisco Secure Client in the net box" "the kept installer in /var/lib/net-box/installers/ (migration M10 puts it there)"
fi
check N5 "Windscribe app in the net box" sh -c 'podman exec net test -x /opt/windscribe/Windscribe || { journalctl -u cosmic-net-box -n 5 --no-pager -o cat; exit 1; }'
check C1 "Homebrew unpacked and owned by $U" sh -c "[ -x $BREW_PREFIX/bin/brew ] && [ \"\$(stat -c %U $BREW_PREFIX)\" = '$U' ]"
check P4 "Bluetooth controller powered" sh -c 'timeout 5 bluetoothctl show | grep -q "Powered: yes"'
check P5 "fwupd answers (fwupdmgr get-updates; applying firmware stays your call)" sh -c \
    'timeout 120 fwupdmgr get-updates --no-unreported-check --no-metadata-check --assume-yes >/dev/null 2>&1; rc=$?; [ $rc = 0 ] || [ $rc = 2 ] || { echo "exit $rc"; exit 1; }'
check P8 "power profiles daemon answers" powerprofilesctl get
check D7 "COSMIC's default shortcuts include the tiling toggle" grep -rqs ToggleTiling /usr/share/cosmic
check P9 "TPM2 module in the initramfs config" test -f /usr/lib/dracut/dracut.conf.d/90-tpm2.conf
check P6 "fingerprint daemon and PAM module installed" rpm -q fprintd fprintd-pam
if enr=$(cosmic-enroll --check 2>&1) && ! grep -qE 'NOT|missing' <<<"$enr"; then
    pass P6 "fingerprint enrolled, PAM uses it; TPM2 + PIN on every LUKS device (P9)"
else
    you P6 "sudo cosmic-enroll — finger on the reader, the LUKS passphrase, a new PIN twice; then reboot"
    grep -E 'NOT|missing' <<<"$enr" | detail
fi

section "image layer — evidence from use"
evidence P1 "3 boots: LUKS unlocked, then the greeter" "reboot (each boot counts)" ev_boots
evidence P2 "a hibernate and its resume" "close the lid for more than 5 minutes, or run --exercise" sl hibernates 1
evidence P2 "a lid close that went on to hibernate" "close the lid for more than 5 minutes" sl lid_hibernate 1
evidence P2 "10 suspend cycles" "every lid close counts" sl suspends 10
[[ -n "${SL[drain_suspend]:-}" ]]   && info P2 "battery drain asleep: ${SL[drain_suspend]}"
[[ -n "${SL[drain_hibernate]:-}" ]] && info P2 "battery drain, cycles that hibernated: ${SL[drain_hibernate]}"
evidence P3 "a lid close → suspend → resume" "close and open the lid once" sl lid_suspend 1
ev_bt_out=$(ev_bt); case $? in
    0) pass P3 "Bluetooth reconnects after resume ($ev_bt_out)" ;;
    2) fail P3 "Bluetooth did not reconnect after the latest resume"; detail <<<"$ev_bt_out" ;;
    *) wait_ P3 "Bluetooth reconnects after resume" "connect a Bluetooth device, then close and open the lid" ;;
esac
evidence P4 "Wi-Fi connected" "connect to a Wi-Fi network" ev_wifi
evidence P4 "webcam answers a capture query" "the camera switch on the bezel off?" ev_webcam
evidence P4 "an audio output (not the dummy)" "log in to the desktop" ev_audio
evidence P4 "external display connected and lit" "plug a USB-C display in" ext_display
evidence P10 "a print job completed" "print anything, or run --exercise" ev_print
evidence D1 "10 logins through cosmic-session-wait" "log out and in (each login counts)" ev_logins
if [[ -r $NSTATE/download-size.log ]]; then info L6 "staged downloads (last 3): $(tail -3 "$NSTATE/download-size.log" | paste -sd ';' -)"; fi

USER_DONE=0; [[ -d "$UHOME/.local/share/chezmoi" ]] && USER_DONE=1
if [[ $USER_LAYER == 1 || ( $USER_LAYER == auto && $USER_DONE == 1 ) ]]; then
    section "user layer — $U"
    check C1 "every formula in ~/.config/homebrew/Brewfile installed" as_user "$BREW_PREFIX/bin/brew" bundle check --file "$UHOME/.config/homebrew/Brewfile" --no-upgrade
    check D9 "dotfiles in their declared state (chezmoi status empty)" sh -c \
        "out=\$(runuser -u '$U' -- env HOME='$UHOME' PATH=\"/usr/bin:$BREW_PREFIX/bin\" chezmoi status); [ -z \"\$out\" ] || { echo \"\$out\"; exit 1; }"
    check D10 "nothing managed in ~ itself but .bashrc, .bash_profile; bash history in ~/.local/state" sh -c \
        "out=\$(runuser -u '$U' -- env HOME='$UHOME' PATH=\"/usr/bin:$BREW_PREFIX/bin\" chezmoi managed --include=files | grep -v / | grep -vxE '\\.bashrc|\\.bash_profile'); [ -z \"\$out\" ] || { echo \"managed in ~: \$out\"; exit 1; }; \
         h=\$(runuser -u '$U' -- env HOME='$UHOME' PATH=/usr/bin:$BREW_PREFIX/bin bash -ic 'echo \$HISTFILE' 2>/dev/null | tail -n1); [ \"\$h\" = '$UHOME/.local/state/bash/history' ] || { echo \"HISTFILE=\$h\"; exit 1; }"
    check E9 "boxes dev, claude, rocm exist" sh -c "for b in dev claude rocm; do runuser -u '$U' -- podman container exists \$b || { echo \"missing \$b\"; exit 1; }; done"
    check S1 "Syncthing user service enabled" sh -c "runuser -u '$U' -- env XDG_RUNTIME_DIR=/run/user/$UID_U systemctl --user is-enabled --quiet syncthing.service"
    check D2 "Ghostty exported from dev; COSMIC Terminal on the host" sh -c \
        "ls '$UHOME'/.local/share/applications/dev-*ghostty*.desktop >/dev/null 2>&1 && rpm -q cosmic-term >/dev/null"
    check D3 "starship prompt on the host and in dev" sh -c \
        "runuser -u '$U' -- env HOME='$UHOME' PATH=/usr/bin:$BREW_PREFIX/bin bash -ic 'echo \$STARSHIP_SHELL' 2>/dev/null | grep -qx bash && \
         runuser -u '$U' -- env HOME='$UHOME' XDG_RUNTIME_DIR=/run/user/$UID_U distrobox enter dev -- bash -ic 'echo \$STARSHIP_SHELL' 2>/dev/null | grep -qx bash"
    check D6 "Chrome (dev) opens links" sh -c "runuser -u '$U' -- env HOME='$UHOME' xdg-mime query default x-scheme-handler/https | grep -qi chrome"
    check A "apps present: Chrome, VS Code, Antigravity, Ghostty (dev); Claude Desktop, Claude Code (claude)" sh -c \
        "runuser -u '$U' -- env HOME='$UHOME' XDG_RUNTIME_DIR=/run/user/$UID_U distrobox enter dev -- sh -c 'command -v google-chrome && command -v code && command -v antigravity && command -v ghostty' >/dev/null && \
         runuser -u '$U' -- env HOME='$UHOME' XDG_RUNTIME_DIR=/run/user/$UID_U distrobox enter claude -- sh -c 'command -v claude-desktop && command -v claude' >/dev/null"
    check E2 "uv runs a fresh project" as_user sh -c 'd=$(mktemp -d) && cd "$d" && uv init -q --no-workspace p && cd p && uv run -q python -c "print(1)" >/dev/null; rc=$?; rm -rf "$d"; exit $rc'
    check E3 "ROCm sees the GPU in rocm" sh -c \
        "runuser -u '$U' -- env HOME='$UHOME' XDG_RUNTIME_DIR=/run/user/$UID_U distrobox enter rocm -- sh -c '/opt/rocm/bin/rocminfo 2>/dev/null || rocminfo' | grep -q gfx"
    check V3 "OpenSC in Chrome's NSS database (dev box)" sh -c \
        "runuser -u '$U' -- env HOME='$UHOME' XDG_RUNTIME_DIR=/run/user/$UID_U distrobox enter dev -- modutil -dbdir sql:'$UHOME/.pki/nssdb' -list 2>/dev/null | grep -qiE 'opensc|p11-kit'"
    evidence V3 "card certificates readable on Firefox's path (p11-kit)" "insert the CAC" card_certs pkcs11-tool --module /usr/lib64/p11-kit-proxy.so -O --type cert
    evidence V3 "card certificates readable on Chrome's path (OpenSC in dev)" "insert the CAC" card_certs \
        runuser -u "$U" -- env HOME="$UHOME" XDG_RUNTIME_DIR="/run/user/$UID_U" distrobox enter dev -- pkcs11-tool --module /usr/lib64/opensc-pkcs11.so -O --type cert
    you V3 "a DoD site login in Chrome and in Firefox (your PIN)"
    evidence P11 "ddcutil detect lists the external monitor" "plug the monitor in" ev_ddc
fi

section "backups and VPN — evidence from use"
if [[ -r /etc/fedora-cosmic-atomic/nightly.env ]]; then
    check R1 "restore point within a day (nightly report)" sh -c \
        "l=$(age_h local); o=$(age_h offsite); n=\$(( l < o ? l : o )); [ \$n -le 26 ] || { echo \"newest copy \$n h old\"; exit 1; }"
else
    wait_ R1 "restore point within a day" "M11 sets up the backups"
fi
evidence S2 "restore probe: a file back from the DAS and from B2, identical" "a night with the DAS attached and one online" ev_restore_probe
[[ -r $NSTATE/report.txt ]] && check S2 "the last nightly restore probe found no difference" sh -c \
    "! grep '^FAIL  restore probe' '$NSTATE/report.txt'"
evidence N4 "a VPN tunnel with routes and DNS working from the host, dev and a container" "connect the VPN once (the login is yours)" ev_tunnel
you N4 "the VPN logins; which method stays (N4/N5 trial) is your call"

# ── result ───────────────────────────────────────────────────────────
section "result: $NPASS pass, $NFAIL fail, $NWAIT waiting for evidence, $NYOU yours"

# L3: known-good. The record of clean days per deployment; the first complete acceptance
# pins the booted deployment; a newer one that stays clean 7 days takes the pin over.
pin_logic() {
    local js booted_idx booted_csum booted_ts pinned clean idx old
    js=$(rpm-ostree status --json 2>/dev/null) || return 0
    read -r booted_idx booted_csum booted_ts pinned < <(python3 -c '
import json,sys
d=json.load(sys.stdin)["deployments"]
b=[(i,x) for i,x in enumerate(d) if x.get("booted")][0]
p=",".join("%d:%d" % (i, x.get("timestamp",0)) for i,x in enumerate(d) if x.get("pinned"))
print(b[0], b[1]["checksum"], b[1].get("timestamp",0), p or "-")' <<<"$js")
    clean="$STATE/clean/$booted_csum"
    if (( NFAIL > 0 )); then rm -f "$clean"; [[ $PIN == 1 ]] && info L3 "not pinned: something FAILed"; return 0; fi
    grep -qx "$(date +%F)" "$clean" 2>/dev/null || date +%F >> "$clean"
    if [[ $PIN == 1 ]]; then
        ostree admin pin "$booted_idx" >/dev/null && info L3 "pinned the booted deployment ($booted_idx) by request"; return 0
    fi
    if [[ "$pinned" == - ]]; then
        if (( NWAIT == 0 )); then ostree admin pin "$booted_idx" >/dev/null && info L3 "acceptance complete: pinned the booted deployment as known-good"
        else info L3 "not pinned yet: $NWAIT check(s) still waiting for evidence"; fi
        return 0
    fi
    [[ ",$pinned," == *",$booted_idx:"* ]] && { info L3 "the booted deployment is the pinned known-good one"; return 0; }
    for idx in ${pinned//,/ }; do
        (( booted_ts > ${idx#*:} )) || { info L3 "pinned known-good is newer than the booted one; pin unchanged"; return 0; }
    done
    if (( $(wc -l < "$clean") >= 7 )); then
        ostree admin pin "$booted_idx" >/dev/null || return 0
        for old in ${pinned//,/ }; do ostree admin pin --unpin "${old%%:*}" >/dev/null; done
        info L3 "the booted deployment stayed clean 7 days: it is the known-good pin now (the older pin released)"
    else
        info L3 "known-good stays pinned; the booted deployment has $(wc -l < "$clean") of 7 clean days"
    fi
}
pin_logic

if [[ $RECORD == 1 ]]; then
    cp "$OUT" "$STATE/latest.txt"; chmod 0644 "$STATE/latest.txt"
    echo "Acceptance: $NPASS pass, $NFAIL fail, $NWAIT waiting, $NYOU yours — $STATE/latest.txt"
    grep -E '^(FAIL|INFO  L3)' "$OUT" | sed 's/^/  /'
fi
[[ $NFAIL == 0 ]]
