#!/usr/bin/sh
# cosmic-session-wait — start the COSMIC session only after the greeter has
# let go of the GPU.
#
# Workaround for pop-os/cosmic-comp#2690 (also pop-os/cosmic-greeter#513):
# greetd starts the user session as soon as the greeter reports a successful
# login, while the greeter's own cosmic-comp may still hold /dev/dri/cardN.
# The session's cosmic-comp then fails to open it ("Device or resource busy"),
# exits with "Backend initialized without output", and the screen stays black.
# Seen on every login of the Framework 13 (Ryzen 7040) with COSMIC 1.8.0.
#
# The image points /usr/share/wayland-sessions/cosmic.desktop at this script
# (common-modules.yml). Remove both once cosmic-comp retries busy devices
# itself (upstream PR pop-os/cosmic-comp#2670 or an equivalent fix).
#
# COSMIC_SESSION_WAIT_MS caps the wait (default 10000); after it the session
# starts anyway, so the worst case is the old behaviour, 10 s later.

timeout_ms="${COSMIC_SESSION_WAIT_MS:-10000}"
step_ms=100

greeter_busy() {
    # The greeter's compositor is still running ...
    pgrep -u cosmic-greeter -x cosmic-comp >/dev/null 2>&1 && return 0
    # ... or logind still has the greeter's session (its devices are released
    # when the session is removed). list-sessions has no JSON output on
    # systemd 259, so ask for each session's class.
    for s in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
        [ "$(loginctl show-session "$s" -p Class --value 2>/dev/null)" = greeter ] && return 0
    done
    return 1
}

waited=0
while greeter_busy && [ "$waited" -lt "$timeout_ms" ]; do
    sleep 0.1
    waited=$((waited + step_ms))
done

# One line per login, so cosmic-acceptance can count logins (spec D1, L5).
if greeter_busy; then
    logger -t cosmic-session-wait "login: greeter still active after ${waited} ms; starting the session anyway"
else
    logger -t cosmic-session-wait "login: session starts after waiting ${waited} ms for the greeter"
fi

exec /usr/bin/start-cosmic "$@"
