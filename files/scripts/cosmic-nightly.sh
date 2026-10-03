#!/usr/bin/env bash
#
# cosmic-nightly — the one scheduled maintenance job (spec J1). Shipped as
# /usr/bin/cosmic-nightly, run by cosmic-nightly.timer (~04:30, Persistent=true:
# a night missed in sleep or hibernation runs at the next wake).
#
#   1. backup   local plain-file snapshots on the DAS (S2a, only when it is mounted)
#               + restic to the off-site repository (S2b, only when online)
#   2. drift    what is on the machine that the image and the dotfiles do not declare (O1)
#   3. upgrade  bootc upgrade (STAGED: never --apply), flatpaks, distroboxes,
#               firmware metadata (never firmware itself)
#   4. report   /var/lib/cosmic-nightly/report.txt + a desktop notification
#
# NEVER reboots, never applies an update, never inhibits sleep (the laptop must still
# hibernate in a bag mid-run; the job continues after resume). Every step runs even if
# an earlier one failed; the report lists failures first.
#
# Settings: /etc/fedora-cosmic-atomic/nightly.env (root, 0600, written during the
# migration; template /usr/share/fedora-cosmic-atomic/nightly.example.env). Without it,
# only the drift report and the upgrades run.
#
#   cosmic-nightly            run all steps (root)
#   cosmic-nightly --dry-run  print what would run, change nothing
#
set -uo pipefail

CONF="${NIGHTLY_CONF:-/etc/fedora-cosmic-atomic/nightly.env}"
SHARE=/usr/share/fedora-cosmic-atomic
STATE=/var/lib/cosmic-nightly
LOGDIR=/var/log/cosmic-nightly
DRY=0; [[ "${1:-}" == --dry-run ]] && DRY=1

[[ $EUID -eq 0 ]] || { echo "cosmic-nightly: run as root (it is a system service)" >&2; exit 1; }
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && source "$CONF"
U="${NIGHTLY_USER:-$(getent passwd 1000 | cut -d: -f1)}"
UID_U=$(id -u "$U" 2>/dev/null) || { echo "cosmic-nightly: user '$U' not found" >&2; exit 1; }
UHOME=$(realpath "$(getent passwd "$U" | cut -d: -f6)")

mkdir -p "$STATE" "$LOGDIR"; chmod 0755 "$STATE"
LOG="$LOGDIR/$(date +%F).log"
exec > >(tee -a "$LOG") 2>&1
SUMMARY=()

run() { if [[ $DRY == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }
# A step function returns 0 = ok, 99 = skipped (reason on stdout), anything else = failed.
step() {
    local name="$1" rc; shift
    echo; echo "== $name  $(date +%T)"
    "$@"; rc=$?
    case $rc in
        0)  SUMMARY+=("ok    $name") ;;
        99) SUMMARY+=("skip  $name") ;;
        *)  SUMMARY+=("FAIL  $name (exit $rc)") ;;
    esac
}
as_user() {
    runuser -u "$U" -- env HOME="$UHOME" USER="$U" XDG_RUNTIME_DIR="/run/user/$UID_U" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_U/bus" \
        PATH="$UHOME/.local/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

# ── 1. backup ────────────────────────────────────────────────────────
# Not backed up: caches, Trash, container image layers (rebuilt from their
# definitions). Container volumes ARE backed up.
home_excludes() {
    cat <<'EOF'
/.cache/
/.local/share/Trash/
/.local/share/containers/storage/overlay/
/.local/share/containers/storage/overlay-images/
/.local/share/containers/storage/overlay-layers/
/.var/app/*/cache/
EOF
}
VM_DIRS="${VM_IMAGE_DIRS:-/var/lib/libvirt/images /var/lib/libvirt/vm-images}"

backup_local() {
    local dest="${LOCAL_SNAPSHOT_DIR:-}"
    [[ -n "$dest" ]] || { echo "no LOCAL_SNAPSHOT_DIR in $CONF"; return 99; }
    [[ -d "$dest" ]] || { echo "$dest not present (DAS not attached or not unlocked)"; return 99; }
    # Built in a .partial folder and renamed only when every copy succeeded; old
    # snapshots are pruned only after that, so a failed night never costs a good one.
    local today; today="$dest/$(date +%F)"
    local partial="$dest/.partial-$(date +%F)"
    local prev; prev=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' | sort | tail -1)
    # -A/-X keep ACLs and xattrs (SELinux labels); a target without them (some NAS) sets RSYNC_FLAGS=-aH
    local rs=(rsync ${RSYNC_FLAGS:--aHAX} --numeric-ids --delete --delete-excluded)
    local rc=0 d
    run rm -rf "$dest"/.partial-*                          # leftovers of a failed night
    run mkdir -p "$partial"
    # $HOME, the libvirt definitions, and libvirt state except the disk images
    run "${rs[@]}" ${prev:+--link-dest="$prev/home"} --exclude-from=<(home_excludes) "$UHOME/" "$partial/home/" || rc=1
    run "${rs[@]}" ${prev:+--link-dest="$prev/etc-libvirt"} /etc/libvirt/ "$partial/etc-libvirt/" || rc=1
    local ex=(); for d in $VM_DIRS; do ex+=(--exclude="/${d#/var/lib/libvirt/}/"); done
    run "${rs[@]}" ${prev:+--link-dest="$prev/var-lib-libvirt"} "${ex[@]}" /var/lib/libvirt/ "$partial/var-lib-libvirt/" || rc=1
    if [[ $rc != 0 ]]; then
        echo "  snapshot incomplete: kept as $partial for inspection; nothing pruned"
        return 1
    fi
    run rm -rf "$today"; run mv "$partial" "$today"
    # VM disks: separately, only when changed and their VM is off; keep the last 2 copies
    local img name stamp
    for d in $VM_DIRS; do
        for img in "$d"/*.qcow2 "$d"/*.img; do
            [[ -f "$img" ]] || continue
            name=$(basename "$img")
            if virsh -c qemu:///system list --name 2>/dev/null | while read -r vm; do
                   [[ -n "$vm" ]] && virsh -c qemu:///system domblklist "$vm" --details 2>/dev/null | grep -qF "$img" && echo hit
               done | grep -q hit; then
                echo "  $name: its VM is running — copied another night"; continue
            fi
            stamp=$(stat -c '%Y-%s' "$img")
            [[ -f "$dest/vm-images/$name.stamp" && "$(cat "$dest/vm-images/$name.stamp")" == "$stamp" ]] && { echo "  $name: unchanged"; continue; }
            run mkdir -p "$dest/vm-images"
            run rsync -a --sparse "$img" "$dest/vm-images/$name.$(date +%F)" || { rc=1; continue; }
            [[ $DRY == 1 ]] || echo "$stamp" > "$dest/vm-images/$name.stamp"
            # keep the last 2
            find "$dest/vm-images" -maxdepth 1 -name "$name.20*" | sort | head -n -2 | while read -r old; do run rm -f "$old"; done
        done
    done
    prune_snapshots "$dest"
    return $rc
}

# Keep the newest snapshot of each of the last N days / ISO weeks / months.
prune_snapshots() {
    local dest="$1" keep_d="${LOCAL_KEEP_DAILY:-7}" keep_w="${LOCAL_KEEP_WEEKLY:-4}" keep_m="${LOCAL_KEEP_MONTHLY:-12}"
    local all; mapfile -t all < <(find "$dest" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' -printf '%f\n' | sort -r)
    declare -A keep=() seen_w=() seen_m=()
    local s w m nd=0 nw=0 nm=0
    for s in "${all[@]}"; do
        if (( nd < keep_d )); then keep[$s]=1; nd=$((nd + 1)); fi
        w=$(date -d "$s" +%G-%V); m=${s:0:7}
        if [[ -z "${seen_w[$w]:-}" ]] && (( nw < keep_w )); then seen_w[$w]=1; keep[$s]=1; nw=$((nw + 1)); fi
        if [[ -z "${seen_m[$m]:-}" ]] && (( nm < keep_m )); then seen_m[$m]=1; keep[$s]=1; nm=$((nm + 1)); fi
    done
    for s in "${all[@]}"; do [[ -n "${keep[$s]:-}" ]] || { echo "  prune $s"; run rm -rf "${dest:?}/$s"; }; done
}

backup_offsite() {
    [[ -n "${RESTIC_REPOSITORY:-}" ]] || { echo "no RESTIC_REPOSITORY in $CONF"; return 99; }
    nm-online -q -t 30 || { echo "offline"; return 99; }
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE B2_ACCOUNT_ID B2_ACCOUNT_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY 2>/dev/null
    local rc=0
    run restic backup --host "$(hostname)" --tag nightly --exclude-caches \
        --exclude-file=<(home_excludes | sed -e "s|^/|$UHOME/|" -e 's|/$||') \
        "$UHOME" /etc/libvirt /var/lib/libvirt || rc=1
    # Pruning needs the admin key and is done by hand (S2b); the nightly key cannot delete.
    if [[ "$(date +%d)" == 01 ]]; then run restic check --read-data-subset=5% || rc=1; fi
    return $rc
}

# ── 2. drift report ──────────────────────────────────────────────────
drift() {
    local out="$STATE/drift.txt" ignore="$SHARE/drift-ignore.regex"
    {
        echo "-- /etc changed against the image (ostree admin config-diff)"
        ostree admin config-diff 2>/dev/null | grep -vEf <(grep -v '^#' "$ignore" | sed '/^$/d') || true
        echo "-- packages layered or overridden on this machine"
        rpm-ostree status --booted 2>/dev/null | grep -E 'LayeredPackages|LocalPackages|RemovedBasePackages|Overrides|InactiveRequests' || true
        echo "-- system flatpaks not in the image's list"
        comm -23 <(flatpak list --system --app --columns=application 2>/dev/null | sort -u) <(grep -v '^#' "$SHARE/flatpaks.list" | sed '/^$/d' | sort -u)
        echo "-- system flatpaks in the list but not installed"
        comm -13 <(flatpak list --system --app --columns=application 2>/dev/null | sort -u) <(grep -v '^#' "$SHARE/flatpaks.list" | sed '/^$/d' | sort -u)
        echo "-- user flatpaks"
        as_user flatpak list --user --app --columns=application 2>/dev/null || true
        echo "-- dotfiles not in their declared state (chezmoi status)"
        as_user sh -c 'command -v chezmoi >/dev/null && chezmoi status || echo "(chezmoi not installed)"' 2>&1
    } > "$out"
    chmod 0644 "$out"
    local n; n=$(grep -vc '^--' "$out" || true)
    echo "drift items: $n (details: $out)"
    return 0
}

# ── 3. upgrades (staged; nothing is applied, nothing reboots) ────────
upgrade_image()    { run bootc upgrade --quiet; }
upgrade_flatpaks() { run flatpak update --system -y --noninteractive && run as_user flatpak update --user -y --noninteractive; }
upgrade_boxes() {
    local rc=0
    run as_user distrobox upgrade --all || rc=1          # rootless boxes: dev, claude, rocm
    if podman container exists vpn 2>/dev/null; then       # rootful box (VPN clients)
        run distrobox upgrade --root vpn || rc=1
    fi
    return $rc
}
# Metadata only; firmware is never installed by this job (fwupdmgr update is a manual step).
firmware_metadata() { run fwupdmgr refresh --force >/dev/null 2>&1; fwupdmgr get-updates 2>/dev/null | head -20 || true; return 0; }

# ── run ──────────────────────────────────────────────────────────────
echo "cosmic-nightly $(date -Is) on $(hostname) (user $U)$([[ $DRY == 1 ]] && echo ', DRY RUN')"
step "backup: local snapshot (DAS)" backup_local
step "backup: off-site (restic)"    backup_offsite
step "drift report"                 drift
step "upgrade: image (staged)"      upgrade_image
step "upgrade: flatpaks"            upgrade_flatpaks
step "upgrade: distroboxes"         upgrade_boxes
step "firmware: metadata"           firmware_metadata

# ── 4. report ────────────────────────────────────────────────────────
REPORT="$STATE/report.txt"
{
    echo "Nightly job $(date '+%F %R') — $(hostname)"
    printf '%s\n' "${SUMMARY[@]}" | LC_ALL=C sort -s -k1,1     # FAIL first, then ok, skip
    echo
    echo "Staged image: $(bootc status --format=json 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"].get("staged"); print(s["image"]["image"]["image"]+" (applies at the next reboot)" if s else "none")' 2>/dev/null || echo unknown)"
    echo "Drift: $(grep -vc '^--' "$STATE/drift.txt" 2>/dev/null || echo '?') item(s) — $STATE/drift.txt"
    echo "Log: $LOG"
} > "$REPORT"
chmod 0644 "$REPORT"
cat "$REPORT"
# Tell the user now if a session is open; otherwise cosmic-nightly-notify shows it at login.
[[ $DRY == 1 ]] || { [[ -S "/run/user/$UID_U/bus" ]] && as_user /usr/bin/cosmic-nightly-notify >/dev/null 2>&1; } || true
exit 0
