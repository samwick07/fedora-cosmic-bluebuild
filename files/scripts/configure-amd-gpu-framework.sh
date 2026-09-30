#!/usr/bin/env bash
# configure-amd-gpu-framework.sh
# AMD ROCm environment for Framework 13 AMD (Ryzen 7040U / Phoenix).
# The integrated Radeon 780M is RDNA3 and reports as gfx1103, which ROCm has
# no kernels for; HSA_OVERRIDE_GFX_VERSION=11.0.0 makes it run gfx1100 code.
set -euo pipefail

cat > /etc/profile.d/amd-rocm.sh << 'EOF'
# AMD ROCm environment for Framework 13 (Ryzen 7040 / RDNA3 APU)
export HSA_OVERRIDE_GFX_VERSION=11.0.0
export HIP_VISIBLE_DEVICES=0
export HSA_ENABLE_SDMA=0
EOF

# Also set for systemd services (not just login shells)
mkdir -p /etc/environment.d
cat > /etc/environment.d/50-amd-rocm.conf << 'EOF'
HSA_OVERRIDE_GFX_VERSION=11.0.0
HIP_VISIBLE_DEVICES=0
HSA_ENABLE_SDMA=0
EOF

echo "AMD ROCm configured for Framework 13 (RDNA3 APU, gfx1103 -> 11.0.0 override)."
