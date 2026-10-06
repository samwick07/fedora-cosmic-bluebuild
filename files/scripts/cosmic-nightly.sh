#!/usr/bin/env bash
#
# cosmic-nightly — the one scheduled maintenance job (spec J1). Shipped as
# /usr/bin/cosmic-nightly, run by cosmic-nightly.timer (~04:30, Persistent=true:
# a night missed in sleep or hibernation runs at the next wake).
#
#   0. manifest what this machine is right now: image digest, kargs, layered packages,
#               enabled units, flatpaks, the packages in every box (R1)
#   1. backup   local plain-file snapshots on the DAS (S2a, only when it is mounted)
#               + restic to the off-site repository (S2b, only when online, and not
#               while OFFSITE_DEFERRED is set: every report then says since when);
#               scope: $HOME, all of /etc, /var state, VM disks (S2d); then a restore
#               probe: one random home file and the manifest back from each copy, compared
#   2. drift    what is on the machine that the image and the dotfiles do not declare (O1)
#   3. upgrade  bootc upgrade (STAGED: never --apply), flatpaks, Homebrew (as the
#               user), distroboxes, firmware metadata (never firmware itself)
#   4. accept   cosmic-acceptance --record: the spec's checks, daily, so a regression after
#               an update shows the next morning; pins known-good deployments (L3, L5)
#   5. report   /var/lib/cosmic-nightly/report.txt + a desktop notification
#
# NEVER reboots, never applies an update, never inhibits sleep (the laptop must still
# hibernate in a bag mid-run; the job continues after resume). Every step runs even if
# an earlier one failed; the report lists failures first.
#
# Settings: /etc/fedora-cosmic-atomic/nightly.env (root, 0600, written during the
# migration; template /usr/share/fedora-cosmic-atomic/nightly.example.env). Without it,
# only the drift report and the upgrades run.
#
#   cosmic-nightly             run all steps (root)
#   cosmic-nightly --dry-run   print what would run, change nothing
#   cosmic-nightly --catch-up  hourly: the manifest and the backups, only when the last
#                              good copy is older than 24 h and its target is reachable (R1)
#
set -uo pipefail

CONF="${NIGHTLY_CONF:-/etc/fedora-cosmic-atomic/nightly.env}"
SHARE=/usr/share/fedora-cosmic-atomic
STATE=/var/lib/cosmic-nightly
LOGDIR=/var/log/cosmic-nightly
DRY=0; MODE=nightly
for a in "$@"; do
    case $a in
        --dry-run)  DRY=1 ;;
        --catch-up) MODE=catch-up ;;
        *) echo "usage: cosmic-nightly [--dry-run] [--catch-up]" >&2; exit 2 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "cosmic-nightly: run as root (it is a system service)" >&2; exit 1; }
# shellcheck disable=SC1090
[[ -r "$CONF" ]] && source "$CONF"
U="${NIGHTLY_USER:-$(getent passwd 1000 | cut -d: -f1)}"
UID_U=$(id -u "$U" 2>/dev/null) || { echo "cosmic-nightly: user '$U' not found" >&2; exit 1; }
UHOME=$(realpath "$(getent passwd "$U" | cut -d: -f6)")

mkdir -p "$STATE" "$LOGDIR"; chmod 0755 "$STATE"
# One run at a time (the nightly run and the hourly catch-up share the targets).
exec 9>/run/cosmic-nightly.lock
flock -n 9 || { echo "cosmic-nightly: another run is in progress"; exit 0; }

# R1: a good copy older than this many hours is stale.
MAX_AGE_H="${BACKUP_MAX_AGE_H:-24}"
age_h() {  # hours since the last good backup to target $1 (local | offsite); 9999 = never
    local f="$STATE/last-$1"
    if [[ -r "$f" ]]; then echo $(( ($(date +%s) - $(cat "$f")) / 3600 )); else echo 9999; fi
}
mark_ok() { [[ $DRY == 1 ]] || date +%s > "$STATE/last-$1"; }
local_reachable()   { [[ -n "${LOCAL_SNAPSHOT_DIR:-}" && -d "${LOCAL_SNAPSHOT_DIR}" ]]; }
offsite_reachable() { [[ -z "$DEFERRED" && -n "${RESTIC_REPOSITORY:-}" ]] && nm-online -q -t 30; }

# S2b: the off-site copy is deferred while nightly.env sets OFFSITE_DEFERRED (anything but
# empty or 0). The date it was first seen is kept, so every report says since when there
# has been no copy outside the house; removing the line ends the deferral (and the record).
DEFER_FILE="$STATE/offsite-deferred-since"
DEFERRED=""
if [[ -n "${OFFSITE_DEFERRED:-}" && "${OFFSITE_DEFERRED}" != 0 ]]; then
    [[ -s "$DEFER_FILE" || $DRY == 1 ]] || date +%F > "$DEFER_FILE"
    DEFERRED=$(cat "$DEFER_FILE" 2>/dev/null || date +%F)
elif [[ $DRY != 1 ]]; then
    rm -f "$DEFER_FILE"
fi

# ── the daily snapshot of /var/home (S2e) ───────────────────────────
# Only when /var/home is its own btrfs subvolume (the kickstart's layout, L1). Otherwise
# the backups read the live files, as before.
HOME_FS=/var/home
SNAPDIR="$HOME_FS/.snapshots"     # one read-only snapshot per day; you can read your own files
HOME_SRC="$UHOME"
home_is_subvol() {
    [[ "$UHOME" == "$HOME_FS"/* && "$(stat -f -c %T "$HOME_FS" 2>/dev/null)" == btrfs ]] \
        && btrfs subvolume show "$HOME_FS" >/dev/null 2>&1
}

# The hourly catch-up leaves no trace unless a stale copy can be refreshed right now.
if [[ $MODE == catch-up ]]; then
    want=0
    (( $(age_h local) >= MAX_AGE_H )) && local_reachable && want=1
    (( $(age_h offsite) >= MAX_AGE_H )) && offsite_reachable && want=1
    [[ $want == 1 ]] || exit 0
fi

LOG="$LOGDIR/$(date +%F).log"
exec > >(tee -a "$LOG") 2>&1
SUMMARY=()
LOCAL_OK=0; LOCAL_SNAP=""; OFFSITE_OK=0; ACCEPT=""

run() { if [[ $DRY == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }
# A step function returns 0 = ok, 99 = skipped (reason on stdout), 98 = deferred by
# decision (S2b), anything else = failed.
step() {
    local name="$1" rc; shift
    echo; echo "== $name  $(date +%T)"
    "$@"; rc=$?
    case $rc in
        0)  SUMMARY+=("ok    $name") ;;
        99) SUMMARY+=("skip  $name") ;;
        98) SUMMARY+=("defer $name (since $DEFERRED, S2b)") ;;
        *)  SUMMARY+=("FAIL  $name (exit $rc)") ;;
    esac
}
as_user() {
    runuser -u "$U" -- env HOME="$UHOME" USER="$U" XDG_RUNTIME_DIR="/run/user/$UID_U" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$UID_U/bus" \
        HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 \
        PATH="$UHOME/.local/bin:/usr/local/bin:/usr/bin:/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin" "$@"
}
# C1: Homebrew is the user's CLI lane. Root never runs it (Homebrew refuses root, and a
# root job must not execute user-writable files); every brew call goes through as_user.
BREW_PREFIX=/home/linuxbrew/.linuxbrew
BREW="$BREW_PREFIX/bin/brew"
brew_ok() { [[ -x "$BREW" && "$(stat -c %u "$BREW_PREFIX")" == "$UID_U" ]]; }

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

# /var: everything except what is backed up elsewhere ($HOME = /var/home/<user>; VM disks)
# or rebuilt or disposable (caches, temp, logs, installed flatpaks, container image layers).
# Paths relative to /var. The top-level ones are left out of the restic paths instead of
# excluded, so an exclude can never match the explicit $HOME path.
VAR_SKIP_TOP="home cache tmp log"
var_excludes() {
    cat <<'EOF'
/lib/flatpak/
/lib/containers/storage/overlay/
/lib/containers/storage/overlay-images/
/lib/containers/storage/overlay-layers/
/lib/systemd/coredump/
/lib/net-box/packages/
/roothome/.cache/
EOF
    local d; for d in $VM_DIRS; do echo "/${d#/var/}/"; done
}
var_paths() {  # restic paths for /var: its top-level entries minus VAR_SKIP_TOP
    local p
    for p in /var/* /var/.[!.]*; do
        [[ -e "$p" || -L "$p" ]] || continue
        [[ " $VAR_SKIP_TOP " == *" ${p#/var/} "* ]] && continue
        echo "$p"
    done
}
vm_images() {
    local d img
    for d in $VM_DIRS; do for img in "$d"/*.qcow2 "$d"/*.img; do [[ -f "$img" ]] && echo "$img"; done; done
    return 0
}
vm_in_use() {  # is this disk attached to a running VM?
    local img="$1" vm
    while read -r vm; do
        [[ -n "$vm" ]] && virsh -c qemu:///system domblklist "$vm" --details 2>/dev/null | grep -qF "$img" && return 0
    done < <(virsh -c qemu:///system list --name 2>/dev/null)
    return 1
}

# ── 0. manifest (R1) ─────────────────────────────────────────────────
# Plain text under $STATE/manifest, which the backups below include (it is in /var).
# With it, a rebuild can return to yesterday's image digest, kargs, layered packages,
# enabled units, flatpaks and box contents, not only to the declared state.
BOXES_IN_USE=""
PKGS_CMD='if command -v rpm >/dev/null 2>&1; then rpm -qa --qf "%{NAME}\n"; else dpkg-query -W -f "\${Package}\n"; fi | sort'
manifest() {
    local m="$STATE/manifest" n
    if [[ $DRY == 1 ]]; then echo "  [dry-run] write $m"; return 0; fi
    mkdir -p "$m/boxes"; chmod 0700 "$m"
    { bootc status --format=json 2>/dev/null || bootc status --json 2>/dev/null; } > "$m/bootc-status.json"
    rpm-ostree status -v      > "$m/rpm-ostree-status.txt" 2>&1
    cat /proc/cmdline         > "$m/kernel-cmdline.txt"
    ostree admin config-diff  > "$m/etc-config-diff.txt" 2>&1
    systemctl list-unit-files --state=enabled --no-legend > "$m/units-system.txt" 2>&1
    as_user systemctl --user list-unit-files --state=enabled --no-legend > "$m/units-user.txt" 2>&1
    flatpak remotes --system --columns=name,url > "$m/flatpak-remotes.txt" 2>&1
    flatpak list --system --app --columns=application,origin,branch,active > "$m/flatpaks-system.txt" 2>&1
    as_user flatpak list --user --app --columns=application,origin,branch,active > "$m/flatpaks-user.txt" 2>&1
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS > "$m/disks.txt" 2>&1
    if brew_ok; then
        as_user "$BREW" list --versions > "$m/brew-versions.txt" 2>&1
        as_user "$BREW" tap > "$m/brew-taps.txt" 2>&1
    fi
    # The packages in every box (rootless, then rootful), so a box rebuilt from its
    # definition can be brought back to yesterday's set.
    rm -f "$m"/boxes/*.pkgs
    BOXES_IN_USE=$(as_user podman ps --filter label=manager=distrobox --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
    while read -r n; do
        [[ -n "$n" ]] || continue
        as_user podman start "$n" >/dev/null 2>&1
        as_user podman exec "$n" sh -c "$PKGS_CMD" > "$m/boxes/$n.pkgs" 2>&1
    done < <(as_user podman ps -a --filter label=manager=distrobox --format '{{.Names}}' 2>/dev/null)
    while read -r n; do
        [[ -n "$n" ]] || continue
        podman start "$n" >/dev/null 2>&1
        podman exec "$n" sh -c "$PKGS_CMD" > "$m/boxes/$n.rootful.pkgs" 2>&1
    done < <(podman ps -a --filter label=manager=distrobox --format '{{.Names}}' 2>/dev/null)
    echo "manifest written: $(find "$m" -type f | wc -l) files in $m"
    return 0
}

backup_local() {
    local dest="${LOCAL_SNAPSHOT_DIR:-}"
    [[ -n "$dest" ]] || { echo "no LOCAL_SNAPSHOT_DIR in $CONF"; return 99; }
    [[ -d "$dest" ]] || { echo "$dest not present (DAS not attached or not unlocked)"; return 99; }
    if [[ $MODE == catch-up ]] && (( $(age_h local) < MAX_AGE_H )); then echo "last good copy $(age_h local) h ago"; return 99; fi
    # Built in a .partial folder and renamed only when every copy succeeded; old
    # snapshots are pruned only after that, so a failed night never costs a good one.
    local today partial prev
    today="$dest/$(date +%F)"
    partial="$dest/.partial-$(date +%F)"
    prev=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name '20??-??-??' | sort | tail -1)
    # -A/-X keep ACLs and xattrs (SELinux labels); a target without them (some NAS) sets RSYNC_FLAGS=-aH
    local flags; read -r -a flags <<< "${RSYNC_FLAGS:--aHAX}"
    local rs=(rsync "${flags[@]}" --numeric-ids --delete --delete-excluded)
    local rc=0 t hx vxf
    # Exclude lists as real files: rsync 3.5 refuses --exclude-from=<(…) ("/dev/fd/63: Too
    # many levels of symbolic links"), which failed every local snapshot.
    hx=$(mktemp); vxf=$(mktemp)
    home_excludes > "$hx"; var_excludes > "$vxf"
    run rm -rf "$dest"/.partial-*                          # leftovers of a failed night
    run mkdir -p "$partial"
    # $HOME, all of /etc, and /var state (S2d). /var stays on its own file system (-x)
    # and skips what is backed up elsewhere or rebuilt.
    local vx=(); for t in $VAR_SKIP_TOP; do vx+=(--exclude="/$t/"); done
    run "${rs[@]}" ${prev:+--link-dest="$prev/home"} --exclude-from="$hx" "$HOME_SRC/" "$partial/home/" || rc=1
    run "${rs[@]}" ${prev:+--link-dest="$prev/etc"} /etc/ "$partial/etc/" || rc=1
    run "${rs[@]}" -x ${prev:+--link-dest="$prev/var"} "${vx[@]}" --exclude-from="$vxf" /var/ "$partial/var/" || rc=1
    rm -f "$hx" "$vxf"
    if [[ $rc != 0 ]]; then
        echo "  snapshot incomplete: kept as $partial for inspection; nothing pruned"
        return 1
    fi
    run rm -rf "$today"; run mv "$partial" "$today"
    mark_ok local; LOCAL_OK=1; LOCAL_SNAP="$today"
    # VM disks: separately, only when changed and their VM is off; keep the last 2 copies
    local img name stamp
    while read -r img; do
        name=$(basename "$img")
        if vm_in_use "$img"; then echo "  $name: its VM is running — copied the first night it is off"; continue; fi
        stamp=$(stat -c '%Y-%s' "$img")
        [[ -f "$dest/vm-images/$name.stamp" && "$(cat "$dest/vm-images/$name.stamp")" == "$stamp" ]] && { echo "  $name: unchanged"; continue; }
        run mkdir -p "$dest/vm-images"
        run rsync -a --sparse "$img" "$dest/vm-images/$name.$(date +%F)" || { rc=1; continue; }
        [[ $DRY == 1 ]] || echo "$stamp" > "$dest/vm-images/$name.stamp"
        # keep the last 2
        find "$dest/vm-images" -maxdepth 1 -name "$name.20*" | sort | head -n -2 | while read -r old; do run rm -f "$old"; done
    done < <(vm_images)
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
    [[ -n "$DEFERRED" ]] && { echo "deferred since $DEFERRED (S2b): no off-site copy until OFFSITE_DEFERRED is removed from $CONF"; return 98; }
    [[ -n "${RESTIC_REPOSITORY:-}" ]] || { echo "no RESTIC_REPOSITORY in $CONF"; return 99; }
    if [[ $MODE == catch-up ]] && (( $(age_h offsite) < MAX_AGE_H )); then echo "last good copy $(age_h offsite) h ago"; return 99; fi
    nm-online -q -t 30 || { echo "offline"; return 99; }
    export RESTIC_REPOSITORY RESTIC_PASSWORD_FILE B2_ACCOUNT_ID B2_ACCOUNT_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY 2>/dev/null
    local rc=0 vp img name stamp
    mapfile -t vp < <(var_paths)
    # Reading from the snapshot, restic must still record $UHOME (restores, parent
    # snapshots): bind the snapshot over it in a private mount namespace for this run only.
    local ns=()
    # shellcheck disable=SC2016
    [[ "$HOME_SRC" != "$UHOME" ]] && ns=(unshare --mount --propagation private bash -c 'mount --bind "$1" "$2" && shift 2 && exec "$@"' _ "$HOME_SRC" "$UHOME")
    # Same scope as the local copy: $HOME, all of /etc, /var state (S2d).
    run "${ns[@]}" restic backup --host "$(hostname)" --tag nightly --one-file-system --exclude-caches \
        --exclude-file=<( { home_excludes | sed -e "s|^/|$UHOME/|"; var_excludes | sed -e 's|^/|/var/|'; } | sed 's|/$||') \
        "$UHOME" /etc "${vp[@]}" || rc=1
    [[ $rc == 0 ]] && { mark_ok offsite; OFFSITE_OK=1; }
    # VM disks as for the local copy: only when their VM is off and the disk changed.
    while read -r img; do
        name=$(basename "$img")
        if vm_in_use "$img"; then echo "  $name: its VM is running — uploaded the first night it is off"; continue; fi
        stamp=$(stat -c '%Y-%s' "$img")
        [[ "$(cat "$STATE/offsite-$name.stamp" 2>/dev/null)" == "$stamp" ]] && { echo "  $name: unchanged"; continue; }
        if run restic backup --host "$(hostname)" --tag vm-disk "$img"; then
            [[ $DRY == 1 ]] || echo "$stamp" > "$STATE/offsite-$name.stamp"
        else
            rc=1
        fi
    done < <(vm_images)
    # Pruning needs the admin key, which never lives on the laptop (S2b); the nightly key cannot delete.
    if [[ $MODE == nightly && "$(date +%d)" == 01 ]]; then run restic check --read-data-subset=5% || rc=1; fi
    return $rc
}

# Today's read-only snapshot of /var/home (taken once a day; a catch-up run the same day
# reuses it), so both copies hold your files as they were at one instant. The last
# LOCAL_SNAPSHOTS_KEEP (7) stay as the local undo for a week.
daily_snapshot() {
    HOME_SRC="$UHOME"
    home_is_subvol || { echo "$HOME_FS is not a btrfs subvolume: backing up the live files"; return 99; }
    local snap old keep="${LOCAL_SNAPSHOTS_KEEP:-7}"
    snap="$SNAPDIR/$(date +%F)"
    if [[ $DRY == 1 ]]; then echo "  [dry-run] snapshot $HOME_FS -> $snap"; return 0; fi
    mkdir -p "$SNAPDIR"; chmod 0755 "$SNAPDIR"
    [[ -e "$snap" ]] || btrfs subvolume snapshot -r "$HOME_FS" "$snap" >/dev/null || return 1
    HOME_SRC="$snap/${UHOME#"$HOME_FS"/}"
    echo "backing up from $HOME_SRC"
    find "$SNAPDIR" -mindepth 1 -maxdepth 1 -name '20??-??-??' | sort -r | tail -n +"$((keep + 1))" \
        | while read -r old; do btrfs subvolume delete "$old" >/dev/null && echo "  dropped snapshot $(basename "$old")"; done
    return 0
}

# R1: at least one good copy (local or off-site) younger than a day, plus a margin
# for the timer's random delay and a long run. While the off-site copy is deferred
# (S2b), the local copy alone counts.
offsite_age() {  # for reports: "N h ago" | never | deferred since DATE
    local o; o=$(age_h offsite)
    if [[ -n "$DEFERRED" ]]; then echo "deferred since $DEFERRED"
    elif ((o == 9999)); then echo never; else echo "$o h ago"; fi
}
restore_point() {
    local l o newest
    l=$(age_h local); o=$(age_h offsite)
    [[ -n "$DEFERRED" ]] && o=9999
    newest=$(( l < o ? l : o ))
    echo "last good copy: local $( ((l == 9999)) && echo never || echo "$l h ago" ), off-site $(offsite_age)"
    (( newest <= MAX_AGE_H + 2 )) || { echo "restore point is older than a day"; return 1; }
    return 0
}

# S2/R1: prove tonight's copies restore. One random file of today's home snapshot and
# the manifest come back from each copy written tonight, byte for byte (restic: decrypted
# from B2 with `restic dump`). A mismatch FAILs the step; cosmic-acceptance reads the stamps.
restore_probe() {
    local rel p what src dasrel rpath rc=0 r2=0 did=0 picks=()
    rel=$(cd "$HOME_SRC" 2>/dev/null && find . -xdev -maxdepth 4 -type f -size +0 -size -4M -readable 2>/dev/null \
        | grep -vE '^\./(\.cache|\.local/share/Trash|\.local/share/containers/storage/overlay[^/]*|\.var/app/[^/]+/cache)/' \
        | grep -v '|' | shuf -n1)
    rel=${rel#./}
    [[ -n "$rel" ]] && picks+=("home file|$HOME_SRC/$rel|home/$rel|$UHOME/$rel")
    picks+=("manifest|$STATE/manifest/bootc-status.json|var/lib/cosmic-nightly/manifest/bootc-status.json|$STATE/manifest/bootc-status.json")
    if [[ $DRY == 1 ]]; then echo "  [dry-run] restore probe: ${picks[*]%%|*}"; return 0; fi
    if [[ $LOCAL_OK == 1 ]]; then
        did=1
        for p in "${picks[@]}"; do
            IFS='|' read -r what src dasrel rpath <<< "$p"
            if cmp -s "$src" "$LOCAL_SNAP/$dasrel"; then echo "  DAS: $what identical ($dasrel)"; else echo "  DAS: $what DIFFERS ($dasrel)"; rc=1; fi
        done
        [[ $rc == 0 ]] && mark_ok restore-probe-local
    fi
    if [[ $OFFSITE_OK == 1 ]]; then
        did=1
        for p in "${picks[@]}"; do
            IFS='|' read -r what src dasrel rpath <<< "$p"
            if restic dump --host "$(hostname)" --tag nightly latest "$rpath" 2>/dev/null | cmp -s "$src" -; then
                echo "  B2:  $what identical ($rpath)"
            else
                echo "  B2:  $what DIFFERS or missing ($rpath)"; r2=1
            fi
        done
        if [[ $r2 == 0 ]]; then mark_ok restore-probe-offsite; else rc=1; fi
    fi
    (( did )) || { echo "no copy was written tonight"; return 99; }
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
        local brewfile="$UHOME/.config/homebrew/Brewfile"   # the dotfiles' Brewfile (spec C1, D10)
        if brew_ok && [[ -r "$brewfile" ]]; then
            echo "-- Homebrew: in the Brewfile but not installed"
            as_user "$BREW" bundle check --file="$brewfile" --verbose --no-upgrade 2>&1 | grep -v "dependencies are satisfied" || true
            echo "-- Homebrew: installed but not in the Brewfile"
            as_user "$BREW" bundle cleanup --file="$brewfile" 2>&1 | grep -vE "^(Would|Run \`brew bundle cleanup)" || true
        fi
        echo "-- boxes: packages added (+) or removed (-) since the box was created from its manifest"
        local cur b base
        for cur in "$STATE"/manifest/boxes/*.pkgs; do
            [[ -e "$cur" ]] || continue
            b=$(basename "$cur" .pkgs); base="$UHOME/.local/state/distrobox/$b.baseline"
            if [[ "$b" == *.rootful ]]; then echo "${b%.rootful}: rootful, managed by the image (no baseline)"; continue; fi
            [[ -r "$base" ]] || { echo "$b: no baseline (recreate it from the manifest to start one)"; continue; }
            comm -13 "$base" "$cur" | sed "s/^/$b: + /"
            comm -23 "$base" "$cur" | sed "s/^/$b: - /"
        done
        echo "-- dotfiles not in their declared state (chezmoi status)"
        as_user sh -c 'command -v chezmoi >/dev/null && chezmoi status || echo "(chezmoi not installed)"' 2>&1
    } > "$out"
    chmod 0644 "$out"
    local n; n=$(grep -vc '^--' "$out" || true)
    echo "drift items: $n (details: $out)"
    return 0
}

# ── 3. upgrades (staged; nothing is applied, nothing reboots) ────────
# L6: the size of what the staged upgrade fetched, one line a night (cosmic-acceptance shows it).
upgrade_image() {
    [[ $DRY == 1 ]] && { run bootc upgrade; return 0; }
    local out rc size
    out=$(bootc upgrade 2>&1); rc=$?
    echo "$out" | tail -5
    size=$(grep -oE 'layers needed: [0-9]+ \([^)]*\)' <<< "$out" | tail -1)
    [[ -n "$size" ]] && echo "$(date +%F) $size" >> "$STATE/download-size.log"
    return $rc
}
upgrade_flatpaks() { run flatpak update --system -y --noninteractive && run as_user flatpak update --user -y --noninteractive; }
upgrade_brew() {
    brew_ok || { echo "Homebrew not set up for $U"; return 99; }
    run as_user "$BREW" update --quiet && run as_user "$BREW" upgrade
}
upgrade_boxes() {
    local rc=0
    run as_user distrobox upgrade --all || rc=1          # rootless boxes: dev, claude, rocm
    if podman container exists net 2>/dev/null; then       # rootful box (VPN clients, network tools)
        run distrobox upgrade --root net || rc=1
        run /usr/libexec/cosmic-net-box || rc=1           # newer vendor .debs from their publishers (F10)
    fi
    return $rc
}
# On the 1st: rebuild each rootless box from distrobox.ini, which proves the manifest still
# builds it and drops what an upgrade or a hand install left behind. A box with packages
# added outside the manifest, or in use when the job started, is left alone and reported.
# Never the rootful net box (the image manages it, cosmic-net-box).
recreate_boxes() {
    [[ "$(date +%d)" == 01 ]] || { echo "only on the 1st of the month"; return 99; }
    local ini="$UHOME/.config/distrobox/distrobox.ini" cur b base added rc=0
    [[ -r "$ini" ]] || { echo "no $ini"; return 99; }
    for cur in "$STATE"/manifest/boxes/*.pkgs; do
        [[ -e "$cur" ]] || continue
        b=$(basename "$cur" .pkgs)
        [[ "$b" == *.rootful ]] && continue
        grep -q "^\[$b\]" "$ini" || continue
        [[ " $BOXES_IN_USE " == *" $b "* ]] && { echo "  $b: was running when the job started — not recreated"; continue; }
        base="$UHOME/.local/state/distrobox/$b.baseline"
        if [[ -r "$base" ]]; then added=$(comm -13 "$base" "$cur" | wc -l); else added="?"; fi
        if [[ "$added" != 0 ]]; then
            echo "  $b: $added package(s) not from the manifest — not recreated; declare them in distrobox.ini or remove them"
            continue
        fi
        echo "  $b: recreating from $ini"
        run as_user distrobox assemble create --replace --file "$ini" --name "$b" || { rc=1; continue; }
        if [[ $DRY != 1 ]]; then
            as_user podman start "$b" >/dev/null 2>&1
            as_user podman exec "$b" sh -c "$PKGS_CMD" > "$base.new" 2>/dev/null && chown "$U:" "$base.new" && mv "$base.new" "$base"
        fi
    done
    return $rc
}

# Metadata only; firmware is never installed by this job (it may reboot; that stays your call).
firmware_metadata() { run fwupdmgr refresh --force >/dev/null 2>&1; fwupdmgr get-updates 2>/dev/null | head -20 || true; return 0; }

# ── run ──────────────────────────────────────────────────────────────
echo "cosmic-nightly $(date -Is) on $(hostname) (user $U)$([[ $DRY == 1 ]] && echo ', DRY RUN')"
step "manifest"                     manifest
step "snapshot of /var/home (S2e)"  daily_snapshot
step "backup: local snapshot (DAS)" backup_local
step "backup: off-site (restic)"    backup_offsite
step "restore point (R1)"           restore_point
[[ $MODE == nightly ]] && step "restore probe (S2)" restore_probe
if [[ $MODE == catch-up ]]; then
    # No drift report, upgrades or notification: the nightly run does those.
    printf '%s\n' "${SUMMARY[@]}" | LC_ALL=C sort -s -k1,1 > "$STATE/catch-up.txt"
    chmod 0644 "$STATE/catch-up.txt"
    exit 0
fi
step "drift report"                 drift
step "upgrade: image (staged)"      upgrade_image
step "upgrade: flatpaks"            upgrade_flatpaks
step "upgrade: Homebrew (as $U)"    upgrade_brew
step "upgrade: distroboxes"         upgrade_boxes
step "boxes: monthly rebuild"       recreate_boxes
step "firmware: metadata"           firmware_metadata
# 4. acceptance, daily: a regression after tonight's changes shows in the morning (L5, L3)
acceptance() {
    [[ $DRY == 1 ]] && { echo "  [dry-run] cosmic-acceptance --record"; return 0; }
    ACCEPT=$(/usr/bin/cosmic-acceptance --record 2>&1); local rc=$?
    echo "$ACCEPT"; return $rc
}
step "acceptance (spec section 6)"  acceptance

# ── 4. report ────────────────────────────────────────────────────────
# A dry run (cosmic-acceptance runs one) must not replace the night's report.
REPORT="$STATE/report.txt"; [[ $DRY == 1 ]] && REPORT="$STATE/report-dry-run.txt"
{
    echo "Nightly job $(date '+%F %R') — $(hostname)"
    printf '%s\n' "${SUMMARY[@]}" | LC_ALL=C sort -s -k1,1     # FAIL first, then ok, skip
    echo
    echo "Staged image: $(bootc status --format=json 2>/dev/null | python3 -c 'import json,sys; s=json.load(sys.stdin)["status"].get("staged"); print(s["image"]["image"]["image"]+" (applies at the next reboot)" if s else "none")' 2>/dev/null || echo unknown)"
    echo "Drift: $(grep -vc '^--' "$STATE/drift.txt" 2>/dev/null || echo '?') item(s) — $STATE/drift.txt"
    [[ -n "$ACCEPT" ]] && { echo "${ACCEPT%%$'\n'*}"; grep -E '^  (FAIL|INFO  L3)' <<< "$ACCEPT"; }
    echo "Restore point: local $( (( $(age_h local) == 9999 )) && echo never || echo "$(age_h local) h ago" ), off-site $(offsite_age); manifest in $STATE/manifest"
    [[ -n "$DEFERRED" ]] && echo "No off-site copy since $DEFERRED (S2b deferral, an accepted risk): every copy is in one house"
    echo "Log: $LOG"
} > "$REPORT"
chmod 0644 "$REPORT"
cat "$REPORT"
# Tell the user now if a session is open; otherwise cosmic-nightly-notify shows it at login.
[[ $DRY == 1 ]] || { [[ -S "/run/user/$UID_U/bus" ]] && as_user /usr/bin/cosmic-nightly-notify >/dev/null 2>&1; } || true
exit 0
