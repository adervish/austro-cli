#!/bin/bash
# Extract YOUR OWN keys from YOUR licensed AE300 Wizard install into ~/.config/austro/.
# These constants are Austro's; this only reads them from software you are licensed to run,
# for interoperating with your own engine data. Values are never printed.
#
# Usage: scripts/extract-keys.sh [path-to-Wizard-folder]
#   The folder must contain DataAbstraction.dll (next to "AE 300 - Wizard.exe").
#
# Requires: .NET SDK (for ILSpy) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."

WIZ="${1:-AE 300 - Wizard}"
DLL="$WIZ/DataAbstraction.dll"
if [[ ! -f "$DLL" ]]; then
    echo "DataAbstraction.dll not found in: $WIZ" >&2
    echo "Pass your Wizard folder: scripts/extract-keys.sh /path/to/AE300-Wizard" >&2
    exit 1
fi

# Install the ILSpy CLI locally if needed.
if [[ ! -x .tools/ilspycmd ]]; then
    dotnet tool install ilspycmd --version 11.1.0.9782 --tool-path .tools
fi
if [[ -z "${DOTNET_ROOT:-}" ]] && command -v brew >/dev/null; then
    export DOTNET_ROOT="$(brew --prefix dotnet)/libexec"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "Decompiling DataAbstraction.dll…"
.tools/ilspycmd -p -o "$TMP" "$DLL" >/dev/null

CFG=~/.config/austro
mkdir -p "$CFG"

python3 - "$TMP" "$CFG" <<'PY'
import re, sys, os, json, glob
tmp, cfg = sys.argv[1], sys.argv[2]
def find(name):
    for p in glob.glob(os.path.join(tmp, "**", name), recursive=True):
        return open(p).read()
    return ""

sec = find("ConfigSecurity.cs")
m = re.search(r'string zauberwort\s*=\s*"((?:[^"\\]|\\.)*)"', sec)
if not m: sys.exit("could not find passphrase (ConfigSecurity.zauberwort)")
pw = m.group(1).encode().decode("unicode_escape")
p1 = os.path.join(cfg, "ae3.pass"); open(p1, "w").write(pw); os.chmod(p1, 0o600)

kwp = find("ConfigKWP.cs")
m = re.search(r'uKey_DiagMask_cu8\s*=\s*new uint\[8,\s*4\]\s*\{(.*?)\};', kwp, re.S)
if not m: sys.exit("could not find key mask (ConfigKWP.uKey_DiagMask_cu8)")
nums = [int(x, 0) for x in re.findall(r'0x[0-9A-Fa-f]+|\d+', m.group(1))]
assert len(nums) == 32, f"expected 32 mask values, got {len(nums)}"
grid = [nums[i*4:(i+1)*4] for i in range(8)]
p2 = os.path.join(cfg, "ae3-ukey.json"); open(p2, "w").write(json.dumps(grid)); os.chmod(p2, 0o600)

print(f"Wrote {p1} ({len(pw)} chars) and {p2} (8x4 mask) — values not shown.")
PY

echo "Done. Keys are in $CFG (chmod 600). They are NOT added to the repo."
