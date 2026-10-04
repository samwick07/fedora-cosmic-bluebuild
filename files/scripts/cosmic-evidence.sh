#!/usr/bin/bash
#
# cosmic-evidence — records what happens to the machine, so that cosmic-acceptance can
# check it later and nobody has to tick anything by hand (spec L5). It only writes to the
# journal (tag cosmic-evidence) and to /run; it changes nothing.
#
#   cosmic-evidence sleep-pre            before every sleep (cosmic-evidence-sleep.service)
#   cosmic-evidence sleep-post           after the resume (same unit, ExecStop)
#   cosmic-evidence bt-recheck MAC,...   45 s after a resume: are those devices back?
#   cosmic-evidence tunnel IFACE         a tunnel interface appeared (udev → cosmic-evidence-tunnel@)
#
# Optional: /etc/fedora-cosmic-atomic/evidence.env, PROBE_NAMES="name1 name2" — the names
# the tunnel probe resolves (e.g. a work-internal one); default fedoraproject.org.
set -uo pipefail
TAG=cosmic-evidence
RUNDIR=/run/cosmic-evidence
# shellcheck disable=SC1091
[[ -r /etc/fedora-cosmic-atomic/evidence.env ]] && . /etc/fedora-cosmic-atomic/evidence.env

log() { logger -t "$TAG" -- "$*"; echo "$*"; }

# energy=<now> full=<full> ac=<0|1> (µWh, or µAh where the battery only reports charge)
battery() {
    local b now="" full="" ac=0 m
    for b in /sys/class/power_supply/*; do
        case "$(cat "$b/type" 2>/dev/null)" in
            Battery)
                if [[ -r $b/energy_now ]]; then now=$(cat "$b/energy_now"); full=$(cat "$b/energy_full")
                elif [[ -r $b/charge_now ]]; then now=$(cat "$b/charge_now"); full=$(cat "$b/charge_full"); fi ;;
            Mains|USB) m=$(cat "$b/online" 2>/dev/null); [[ "$m" == 1 ]] && ac=1 ;;
        esac
    done
    echo "energy=${now:-?} full=${full:-?} ac=$ac"
}

bt_connected() {
    timeout 5 bluetoothctl devices Connected 2>/dev/null | awk '$1 == "Device" {print $2}' | paste -sd, -
}

sleep_pre() {
    local t bt; t=$(date +%s); bt=$(bt_connected)
    mkdir -p "$RUNDIR"
    printf 't=%s bt=%s\n' "$t" "$bt" > "$RUNDIR/sleep"
    log "sleep-pre t=$t $(battery) bt=${bt:--}"
}

sleep_post() {
    local t pre_t="" bt=""; t=$(date +%s)
    if [[ -r $RUNDIR/sleep ]]; then
        pre_t=$(sed -n 's/^t=\([0-9]*\) .*/\1/p' "$RUNDIR/sleep")
        bt=$(sed -n 's/.* bt=\(.*\)$/\1/p' "$RUNDIR/sleep")
    fi
    log "sleep-post t=$t slept=$(( t - ${pre_t:-$t} )) $(battery)"
    # Bluetooth devices reconnect on their own after a resume; look again in 45 s.
    [[ -n "$bt" ]] && systemd-run --quiet --no-block --on-active=45 --unit="cosmic-evidence-bt-$t" \
        /usr/libexec/cosmic-evidence bt-recheck "$bt"
    return 0
}

bt_recheck() {
    local mac want=0 back=0 missing=()
    IFS=, read -r -a macs <<< "${1:-}"
    for mac in "${macs[@]}"; do
        [[ -n "$mac" ]] || continue
        want=$((want + 1))
        if timeout 5 bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then back=$((back + 1)); else missing+=("$mac"); fi
    done
    log "bt-recheck wanted=$want back=$back missing=$(IFS=,; echo "${missing[*]:--}")"
}

# The user who owns the session (uid 1000 by convention on this machine).
session_user() { getent passwd 1000 | cut -d: -f1; }

tunnel() {
    local ifc="$1" u uid kind route dns names n host=ok dev=skip ctr=skip img
    sleep 20                       # let the client set routes and DNS
    [[ -e /sys/class/net/$ifc ]] || { log "tunnel iface=$ifc gone within 20 s"; return 0; }
    kind=$(ip -d -o link show dev "$ifc" 2>/dev/null | grep -oE '\b(tun|wireguard)\b' | head -1)
    route=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | cut -d' ' -f2)
    dns=$(resolvectl dns "$ifc" 2>/dev/null | cut -d: -f2- | xargs)
    names="${PROBE_NAMES:-fedoraproject.org}"
    for n in $names; do getent ahosts "$n" >/dev/null || host=fail; done
    # The same names from the dev box (host network) and from a plain podman container
    # (its own network namespace, like the Hermes sandbox), as the session user.
    u=$(session_user); uid=$(id -u "$u" 2>/dev/null)
    if [[ -n "$uid" && -d /run/user/$uid ]]; then
        local pu=(runuser -u "$u" -- env XDG_RUNTIME_DIR="/run/user/$uid" podman)
        if [[ "$("${pu[@]}" inspect -f '{{.State.Running}}' dev 2>/dev/null)" == true ]]; then
            dev=ok; for n in $names; do "${pu[@]}" exec dev getent ahosts "$n" >/dev/null 2>&1 || dev=fail; done
        fi
        img=$("${pu[@]}" inspect -f '{{.ImageName}}' dev 2>/dev/null)
        if [[ -n "$img" ]]; then
            ctr=ok; for n in $names; do timeout 60 "${pu[@]}" run --rm --pull=never "$img" getent ahosts "$n" >/dev/null 2>&1 || ctr=fail; done
        fi
    fi
    log "tunnel iface=$ifc kind=${kind:-?} default-route=${route:-?} dns=${dns:--} names=${names// /,} host=$host dev=$dev container=$ctr"
}

case "${1:-}" in
    sleep-pre)  sleep_pre ;;
    sleep-post) sleep_post ;;
    bt-recheck) bt_recheck "${2:-}" ;;
    tunnel)     [[ -n "${2:-}" ]] || exit 2; tunnel "$2" ;;
    *) echo "usage: cosmic-evidence sleep-pre|sleep-post|bt-recheck MACS|tunnel IFACE" >&2; exit 2 ;;
esac
exit 0
