#!/usr/bin/env bash
#
# cosmic-nightly-notify — show the nightly job's report as a desktop notification.
# Runs at login (/etc/xdg/autostart) and right after the job when a session is open.
# Each report is shown once (~/.local/state/cosmic-nightly-seen).
#
set -uo pipefail
REPORT=/var/lib/cosmic-nightly/report.txt
SEEN="${XDG_STATE_HOME:-$HOME/.local/state}/cosmic-nightly-seen"
[[ -r "$REPORT" ]] || exit 0
[[ -f "$SEEN" && ! "$REPORT" -nt "$SEEN" ]] && exit 0
title=$(head -1 "$REPORT")
if grep -q '^FAIL' "$REPORT"; then urgency=2; title="$title — needs attention"; else urgency=1; fi
body=$(sed -n '2,$p' "$REPORT" | grep -E '^(FAIL|ok|skip)|^Staged|^Drift' | head -12)
# org.freedesktop.Notifications.Notify via gdbus (in the base image; no libnotify needed)
gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify "Nightly job" 0 "system-software-update" \
    "$title" "$body" "[]" "{'urgency': <byte $urgency>}" 0 >/dev/null 2>&1 || exit 0
mkdir -p "$(dirname "$SEEN")"; touch "$SEEN"
