#!/usr/bin/env bash
# enable-flathub.sh
# Ensures Flathub is configured as the default flatpak remote during image build.
set -euo pipefail

# Add Flathub remote (idempotent)
flatpak remote-add --if-not-exists --system flathub \
  https://flathub.org/repo/flathub.flatpakrepo

# Set Flathub as default remote for user installations
mkdir -p /etc/skel/.config
cat > /etc/skel/.config/flatpak-default-remote << 'EOF'
flathub
EOF

echo "Flathub configured."
