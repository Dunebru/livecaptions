#!/usr/bin/env bash
# Downloads the prebuilt NemoTextProcessing xcframework FluidAudio links against (50 MB, Apache 2.0).
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="Vendor/FluidAudio/Binaries"
[ -d "$DEST/NemoTextProcessing.xcframework" ] && { echo "already present"; exit 0; }
mkdir -p "$DEST"
curl -sSL -o /tmp/nemo.zip "https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.0/NemoTextProcessing.xcframework.zip"
echo "76d0ee9a32b1ee2193231299180ca9bc4fc7e98794e771b3d55d66498352d85f  /tmp/nemo.zip" | shasum -a 256 -c -
unzip -qo /tmp/nemo.zip -d "$DEST" && rm /tmp/nemo.zip
echo "→ $DEST/NemoTextProcessing.xcframework"
