#!/bin/bash
#
# install-macos.sh - build and install the `austro` CLI on macOS, together with its one
# runtime dependency: the MacCAN PCBUSB library (c) UV Software, freeware.
#
# Usage:
#   bash scripts/install-macos.sh                   # install to /usr/local (sudo if needed)
#   PREFIX=~/.local bash scripts/install-macos.sh   # user install, no sudo
#   bash scripts/install-macos.sh --uninstall       # remove what this installed
#
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${PREFIX:-/usr/local}"
BIN="$PREFIX/bin"
LIB="$PREFIX/lib"
DYLIB_NAME="libPCBUSB.0.13.dylib"

# Use sudo only when the target isn't writable by us.
SUDO=""
if ! mkdir -p "$BIN" "$LIB" 2>/dev/null || [ ! -w "$BIN" ] || [ ! -w "$LIB" ]; then
    SUDO="sudo"
    echo "Note: $PREFIX needs elevated permissions; using sudo."
fi

if [ "${1:-}" = "--uninstall" ]; then
    echo "Removing austro from $PREFIX ..."
    $SUDO rm -f "$BIN/austro" "$LIB/$DYLIB_NAME" "$LIB/libPCBUSB.dylib"
    echo "Done."
    exit 0
fi

if [ "$(uname)" != "Darwin" ]; then
    echo "This installer is for macOS. On Linux/WSL build with: swift build -c release --product austro" >&2
    exit 1
fi

# 1. Runtime library: fetch the MacCAN PCBUSB dylib if we don't already have it.
if [ ! -f ".tools/pcbusb/$DYLIB_NAME" ]; then
    echo "Fetching the MacCAN PCBUSB library ..."
    bash scripts/fetch-pcbusb.sh
fi

# 2. Build the CLI (release).
echo "Building austro (release) ..."
swift build -c release --product austro
BINARY=".build/release/austro"
[ -x "$BINARY" ] || { echo "Build did not produce $BINARY" >&2; exit 1; }

# 3. Install the library and binary.
echo "Installing to $PREFIX ..."
$SUDO mkdir -p "$BIN" "$LIB"
$SUDO cp ".tools/pcbusb/$DYLIB_NAME" "$LIB/$DYLIB_NAME"
$SUDO ln -sf "$DYLIB_NAME" "$LIB/libPCBUSB.dylib"
$SUDO cp "$BINARY" "$BIN/austro"

# 4. Point the installed binary at the installed lib (it loads @rpath/libPCBUSB.0.13.dylib),
#    then re-sign ad-hoc - editing the Mach-O invalidates the signature on Apple Silicon.
$SUDO install_name_tool -add_rpath "$LIB" "$BIN/austro" 2>/dev/null || true
$SUDO codesign -s - -f "$BIN/austro" >/dev/null 2>&1 || true

# 5. Verify it runs (and thus resolves the dylib).
echo
if ! "$BIN/austro" --help >/dev/null 2>&1; then
    echo "WARNING: installed, but '$BIN/austro --help' did not run - check the dylib at $LIB." >&2
    exit 1
fi
echo "OK - installed:"
echo "    $BIN/austro"
echo "    $LIB/$DYLIB_NAME"
case ":$PATH:" in
    *":$BIN:"*) echo "    '$BIN' is on your PATH - run:  austro --help" ;;
    *) echo "    Add to PATH:  export PATH=\"$BIN:\$PATH\"   (then: austro --help)" ;;
esac

# 6. Per-user secrets. These are NOT installed (they are recovered from each user's own
#    Wizard and are sensitive) - the CLI reads them at runtime from ~/.config/austro:
#      ae3-ukey.json  - ECU security key mask  (needed by `dump` and `faults`)
#      ae3.pass       - .ae3 passphrase        (needed by `dump` to write the .ae3; CSV works without)
CFG="$HOME/.config/austro"
MISSING=0
[ -f "$CFG/ae3-ukey.json" ] || MISSING=1
[ -f "$CFG/ae3.pass" ]     || MISSING=1
echo
if [ "$MISSING" = "0" ]; then
    echo "Keys found in $CFG - dump/live/faults are ready to use."
else
    echo "Keys needed for ECU access are not set up yet (binary is installed, but:"
    [ -f "$CFG/ae3-ukey.json" ] || echo "    missing $CFG/ae3-ukey.json   (security key mask - dump & faults)"
    [ -f "$CFG/ae3.pass" ]     || echo "    missing $CFG/ae3.pass        (.ae3 passphrase - dump's .ae3 output)"
    echo "  Populate them from your own Austro Wizard:   bash scripts/setup-keys.sh"
    echo "  (or set AE3_UKEY / AE3_PASSPHRASE env vars). 'austro live' works without keys."
fi
