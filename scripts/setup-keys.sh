#!/bin/bash
# Guided, interactive setup: walks you through extracting YOUR keys from YOUR licensed
# AE300 Wizard into ~/.config/austro/. Values are never printed or committed.
set -uo pipefail
cd "$(dirname "$0")/.."

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true); rst=$(tput sgr0 2>/dev/null || true)
say()  { printf "%s\n" "$*"; }
step() { printf "\n${bold}%s${rst}\n" "$*"; }
ok()   { printf "  ✓ %s\n" "$*"; }
warn() { printf "  ⚠ %s\n" "$*"; }
die()  { printf "  ✗ %s\n" "$*" >&2; exit 1; }

cat <<EOF
${bold}Austro CANery — key setup${rst}
This reads two constants from your own licensed AE300 Wizard and saves them to
~/.config/austro/ so the app can decrypt .ae3 files and read the ECU:
  • the .ae3 passphrase        -> ae3.pass
  • the ECU security key mask   -> ae3-ukey.json
Nothing is uploaded, printed, or added to the repo. You need a copy of your Wizard
install (the folder with "AE 300 - Wizard.exe" and DataAbstraction.dll).
EOF

step "1) Checking prerequisites"
command -v python3 >/dev/null || die "python3 not found."
ok "python3"
if command -v dotnet >/dev/null; then ok "dotnet ($(dotnet --version 2>/dev/null))"
else
  warn "The .NET SDK is required (for the ILSpy decompiler)."
  say  "  Install it, then re-run:   ${bold}brew install dotnet${rst}   (or https://dotnet.microsoft.com/download)"
  die  "dotnet not found."
fi

step "2) Locating your Wizard install"
found=""
search_roots=(
  "$HOME/AustroEngine-private/AE 300 - Wizard"
  "./AE 300 - Wizard"
  "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents" "/Applications"
)
for root in "${search_roots[@]}"; do
  [ -e "$root" ] || continue
  hit="$(find "$root" -maxdepth 4 -name DataAbstraction.dll -print -quit 2>/dev/null || true)"
  if [ -n "$hit" ]; then found="$(dirname "$hit")"; break; fi
done

if [ -n "$found" ]; then
  say "  Found a Wizard install at:"
  say "    ${dim}$found${rst}"
  read -r -p "  Use this? [Y/n] " ans
  [[ "${ans:-Y}" =~ ^[Nn] ]] && found=""
fi

while [ -z "$found" ]; do
  say "  Enter the path to your Wizard folder (you can drag it into this window), or 'q' to quit:"
  read -r -p "  > " wiz
  wiz="${wiz%\"}"; wiz="${wiz#\"}"; wiz="${wiz%/}"       # strip quotes / trailing slash
  [[ "$wiz" == q ]] && die "cancelled."
  [ -z "$wiz" ] && continue
  hit="$(find "$wiz" -maxdepth 4 -name DataAbstraction.dll -print -quit 2>/dev/null || true)"
  if [ -n "$hit" ]; then found="$(dirname "$hit")"; else warn "No DataAbstraction.dll under that path — try again."; fi
done
ok "Using: $found"

step "3) Extracting keys"
if [ -f "$HOME/.config/austro/ae3.pass" ] || [ -f "$HOME/.config/austro/ae3-ukey.json" ]; then
  read -r -p "  Keys already exist in ~/.config/austro — overwrite? [y/N] " ans
  [[ "${ans:-N}" =~ ^[Yy] ]] || die "kept existing keys; nothing changed."
fi
scripts/extract-keys.sh "$found" || die "extraction failed (see messages above)."

step "4) Verifying"
[ -s "$HOME/.config/austro/ae3.pass" ] && ok "ae3.pass written" || die "ae3.pass missing"
[ -s "$HOME/.config/austro/ae3-ukey.json" ] && ok "ae3-ukey.json written" || die "ae3-ukey.json missing"

cat <<EOF

${bold}All set.${rst} Your keys are in ~/.config/austro/ (chmod 600, not in the repo).
Next: plug in the PCAN-USB and open Austro CANery — Open a .ae3, or (ground/engine off)
use "Read from ECU". Android: add 'ae3Passphrase=<your passphrase>' to android/local.properties.
EOF
