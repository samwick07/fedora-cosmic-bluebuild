#!/usr/bin/bash
# cosmic-net-box — create and maintain the rootful `net` distrobox (spec N4, N5, C1c).
# Run by cosmic-net-box.service at boot (retries until the network is up) and by the
# nightly job after it upgrades the box; idempotent, so a run with nothing to do changes nothing.
#
#   1. create the box from /usr/share/fedora-cosmic-atomic/net-box.ini if it is missing
#   2. Windscribe (N5): fetch the vendor's current .deb into the installers folder
#   3. install what is in /var/lib/net-box/installers/ and not yet in the box:
#        *.deb                          apt installs it (or upgrades to a newer version)
#        cisco-secure-client-*.sh       Cisco's web-deploy installer (5.1 up to 5.1.14), run
#                                       inside the box: it writes /usr/share and its own
#                                       systemd unit, which the read-only host does not allow;
#                                       from 5.1.15 Cisco ships a .deb, which the line above takes
#   4. Cisco profiles: /var/lib/net-box/cisco-profile/ (backed up) <-> the box
#   5. menu launchers for the vendor apps found in the box (/usr/local/share/applications)
#   6. root-owned wrappers in /usr/local/bin for the network tools (nmap, mtr, tcpdump)
set -uo pipefail
INI=/usr/share/fedora-cosmic-atomic/net-box.ini
BOX=net
STATE=/var/lib/net-box
APPS=/usr/local/share/applications
BIN=/usr/local/bin
WINDSCRIBE_URL="${WINDSCRIBE_URL:-https://windscribe.com/install/desktop/linux_deb_x64}"
PROFILES=/opt/cisco/secureclient/vpn/profile
RC=0

install -d -m 0755 "$STATE/installers" "$STATE/cisco-profile" "$APPS" "$BIN"

if ! podman container exists "$BOX"; then
    echo "creating the $BOX box from $INI"
    distrobox assemble create --file "$INI" || exit 1
fi
podman start "$BOX" >/dev/null || exit 1
# Vendor installers enable and start systemd units: wait for the box's systemd.
timeout 120 podman exec "$BOX" systemctl is-system-running --wait >/dev/null 2>&1 || true

# N5: Windscribe has no apt repository; its stable download URL redirects to the current .deb.
latest=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$WINDSCRIBE_URL" 2>/dev/null)
latest=${latest##*/}; latest=${latest%%\?*}
if [[ "$latest" == windscribe*.deb && ! -e "$STATE/installers/$latest" ]]; then
    echo "fetching $latest"
    if curl -fsSL -o "$STATE/installers/.$latest.part" "$WINDSCRIBE_URL"; then
        find "$STATE/installers" -maxdepth 1 -name 'windscribe*.deb' -delete
        mv "$STATE/installers/.$latest.part" "$STATE/installers/$latest"
    else
        rm -f "$STATE/installers/.$latest.part"; echo "!! Windscribe download failed"; RC=1
    fi
fi

shopt -s nullglob
# .deb: install when the package is missing or at another version.
for deb in "$STATE"/installers/*.deb; do
    f="/installers/$(basename "$deb")"
    pkg=$(podman exec "$BOX" dpkg-deb -f "$f" Package) || { echo "!! $f is not a .deb"; RC=1; continue; }
    want=$(podman exec "$BOX" dpkg-deb -f "$f" Version)
    have=$(podman exec "$BOX" dpkg-query -W -f '${Status} ${Version}' "$pkg" 2>/dev/null)
    [[ "$have" == "install ok installed $want" ]] && continue
    echo "installing $pkg $want from $(basename "$deb")"
    podman exec -e DEBIAN_FRONTEND=noninteractive "$BOX" apt-get install -y -q "$f" || RC=1
done
# Cisco's .sh: run once per installer file, in an empty folder (the web-deploy script asks
# for the license only when a license.txt sits beside it; it never does in this form).
for sh in "$STATE"/installers/cisco-secure-client-*.sh; do
    name=$(basename "$sh"); stamp="/var/lib/cosmic-net-box/$name.done"
    podman exec "$BOX" test -e "$stamp" && continue
    # A failed installer is not retried every 5 minutes; it is reported (cosmic-acceptance N4,
    # this unit's log) until a new installer file arrives or the marker is removed.
    [[ -e "$STATE/failed-$name" ]] && { echo "!! $name failed before ($STATE/failed-$name); not retried"; RC=1; continue; }
    echo "installing $name"
    out=$(podman exec "$BOX" sh -c 'd=$(mktemp -d) && cd "$d" && sh "/installers/$1"' _ "$name" </dev/null 2>&1); rc=$?
    tail -5 <<< "$out"
    # A newer client, upgraded by the headend on connect, makes the script refuse: fine.
    if [[ $rc == 0 ]] || grep -q "already installed" <<< "$out"; then
        podman exec "$BOX" sh -c 'mkdir -p /var/lib/cosmic-net-box && touch "$1"' _ "$stamp"
    else
        echo "!! $name failed (exit $rc)"; printf '%s\n' "$out" > "$STATE/failed-$name"; RC=1
    fi
done

# Cisco profiles: the kept folder fills a box that has none of them; then whatever the box
# has (a headend pushes updates on connect) goes back to the kept folder.
if podman exec "$BOX" test -d "$PROFILES"; then
    for f in "$STATE"/cisco-profile/*.xml; do
        podman exec "$BOX" test -e "$PROFILES/${f##*/}" || podman cp "$f" "$BOX:$PROFILES/" || RC=1
    done
    podman cp "$BOX:$PROFILES/." "$STATE/cisco-profile/" 2>/dev/null || true
fi

# Launchers for the vendor GUIs that are present. A rootful box needs sudo, so they open
# in a terminal that asks once (the fingerprint works there too).
launcher() {  # id, name, command inside the box
    local id="$1" name="$2" cmd="$3"; local f="$APPS/net-box-$id.desktop"
    if podman exec "$BOX" test -x "${cmd%% *}"; then
        cat > "$f" <<EOT
[Desktop Entry]
Type=Application
Name=$name (net box)
Exec=distrobox enter --root $BOX -- $cmd
Terminal=true
Icon=network-vpn
Categories=Network;
EOT
        chmod 0644 "$f"
    else
        rm -f "$f"
    fi
}
launcher cisco "Cisco Secure Client" "/opt/cisco/secureclient/bin/vpnui"
launcher windscribe "Windscribe" "/opt/windscribe/Windscribe"

# Network tools that need real root: run them in the box (sudo asks once).
for tool in nmap mtr tcpdump; do
    cat > "$BIN/$tool" <<EOT
#!/bin/sh
# Generated by cosmic-net-box: $tool runs as root in the rootful net box (spec C1c).
if [ -t 0 ]; then t=-it; else t=-i; fi
exec sudo podman exec \$t $BOX $tool "\$@"
EOT
    chmod 0755 "$BIN/$tool"
done
[[ $RC == 0 ]] && echo "net box ready" || echo "net box: something failed (above; journalctl -u cosmic-net-box)"
exit $RC
