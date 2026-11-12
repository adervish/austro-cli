#!/bin/bash
# Downloads the MacCAN PCBUSB library (© UV Software, freeware) and installs the header
# + dylib this project needs. Not redistributed here — fetched from the official release.
#   https://github.com/mac-can/PCBUSB-Library
set -euo pipefail
cd "$(dirname "$0")/.."
VER="0.13"
URL="https://github.com/mac-can/PCBUSB-Library/releases/download/v${VER}/macOS_Library_for_PCANUSB_v${VER}.tar.gz"
TMP="$(mktemp -d)"

echo "Downloading MacCAN PCBUSB v${VER}…"
curl -fsSL --max-time 60 "$URL" -o "$TMP/pcbusb.tar.gz"
tar -xzf "$TMP/pcbusb.tar.gz" -C "$TMP"

mkdir -p .tools/pcbusb Sources/CPCBUSB
cp "$TMP/PCBUSB/libPCBUSB.${VER}.dylib" .tools/pcbusb/
cp "$TMP/PCBUSB/PCBUSB.h" .tools/pcbusb/
cp "$TMP/PCBUSB/LICENSE" .tools/pcbusb/ 2>/dev/null || true
ln -sf "libPCBUSB.${VER}.dylib" .tools/pcbusb/libPCBUSB.dylib
# The C shim includes the header from its own target directory:
cp "$TMP/PCBUSB/PCBUSB.h" Sources/CPCBUSB/PCBUSB.h
chmod 755 ".tools/pcbusb/libPCBUSB.${VER}.dylib"
rm -rf "$TMP"

echo "Installed:"
echo "  .tools/pcbusb/libPCBUSB.${VER}.dylib  (+ libPCBUSB.dylib symlink)"
echo "  Sources/CPCBUSB/PCBUSB.h"
echo
echo "NOTE: Package.swift references an absolute rpath to .tools/pcbusb — if you cloned"
echo "to a different path, update 'pcbusbDir' at the top of Package.swift."
