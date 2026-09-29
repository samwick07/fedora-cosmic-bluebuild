# System config files for BlueBuild image
# ==============================
# This directory maps to / in the container image.
# Everything here is copied verbatim into the image root during build.
#
# Structure:
#   system/etc/...        -> /etc/...        (system configs)
#   system/usr/...        -> /usr/...        (binaries, scripts, etc.)
#   system/etc/skel/...   -> /etc/skel/...   (default home dir template for new users)
#
# ─────────────────────────────────────────────
# DEFAULT SHELL CONFIG (applies to all new users via /etc/skel)
# ─────────────────────────────────────────────

# /etc/skel/.bashrc — default bash config for new users
# Your personal .bashrc will be restored from restic after install.

# /etc/profile.d/ configs are handled by the scripts module (configure-amd-gpu.sh)
# not by static files here, because they need to be generated based on hardware.
