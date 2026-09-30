#!/usr/bin/env bash
# configure-amd-gpu-desktop.sh
# AMD ROCm environment for desktop with Ryzen 9 9950X + Radeon RX 9070 XT.
#
# The RX 9070 XT is Navi 48 (RDNA 4). ROCm support for RDNA 4 is newer.
# Unlike the Framework APU, a discrete GPU typically does NOT need
# HSA_OVERRIDE_GFX_VERSION — it should report its gfx version natively.
#
# However, the 9950X also has integrated graphics (Radeon Graphics,
# Granite Ridge iGPU). If ROCm picks the wrong device, you may need
# HIP_VISIBLE_DEVICES to point at the discrete GPU.
#
# After first boot, verify with:
#   rocminfo | grep -E "Name:|gfx"
#   rocm-clinfo
#
# If the discrete GPU reports correctly, this script can be simplified
# or removed. If it needs an override, uncomment the HSA_OVERRIDE line.
set -euo pipefail

cat > /etc/profile.d/amd-rocm.sh << 'EOF'
# AMD ROCm environment for desktop (9950X + RX 9070 XT)
# RX 9070 XT is RDNA 4 (Navi 48). Verify gfx version after first boot:
#   rocminfo | grep gfx
# If ROCm doesn't recognize the GPU, uncomment the override below:
# export HSA_OVERRIDE_GFX_VERSION=12.0.0

# Prefer the discrete GPU for compute (index 0 is usually dGPU)
export HIP_VISIBLE_DEVICES=0
EOF

mkdir -p /etc/environment.d
cat > /etc/environment.d/50-amd-rocm.conf << 'EOF'
HIP_VISIBLE_DEVICES=0
EOF

echo "AMD ROCm configured for desktop (RX 9070 XT / RDNA 4)."
echo "NOTE: Verify gfx version after first boot with: rocminfo | grep gfx"
