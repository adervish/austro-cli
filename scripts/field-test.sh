#!/usr/bin/env bash
#
# field-test.sh — one-command, maximum-logging field test of the `austro` CLI.
#
# Runs the full read-only sequence against the engines and captures EVERYTHING
# (environment, USB/adapter state, every command's stdout+stderr+exit code+timing,
# and all output files) into a single timestamped debug bundle you can zip and send.
#
#   Order (each step is independent; a failure never aborts the run):
#     0. environment + PCAN-USB adapter presence
#     1. austro live   — listen-only, both broadcast groups (zero TX, safest)
#     2. austro faults A / faults B   — DTCs (first TX path)
#     3. austro dump A / dump B (1 hour)   — flash → .ae3 + CSV
#
#   SAFETY: every step is read-only. live never transmits; faults/dump send only
#   allowlisted diagnostic reads + ISO-TP flow control. Run on the ground, engine off.
#
# Usage:
#   scripts/field-test.sh                 # both ECUs, 1h dump, auto-build if needed
#   scripts/field-test.sh --ecu A         # just ECU A
#   scripts/field-test.sh --hours 2       # dump 2 hours instead of 1
#   scripts/field-test.sh --live-secs 10  # listen 10s instead of 5
#   scripts/field-test.sh --skip-dump     # skip the flash pull (faster)
#   scripts/field-test.sh --bin /path/to/austro   # use a specific binary
#
# Everything lands in:  ./austro-fieldtest-YYYYmmdd-HHMMSS/

set -u
set -o pipefail

# ---- config / args --------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ECUS="A B"
HOURS=1
LIVE_SECS=5
DO_DUMP=1
BIN_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ecu)       ECUS="$2"; shift 2 ;;
    --hours)     HOURS="$2"; shift 2 ;;
    --live-secs) LIVE_SECS="$2"; shift 2 ;;
    --skip-dump) DO_DUMP=0; shift ;;
    --bin)       BIN_OVERRIDE="$2"; shift 2 ;;
    -h|--help)   grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="$(pwd)/austro-fieldtest-$STAMP"
LOG="$OUT_DIR/field-test.log"
mkdir -p "$OUT_DIR"

# ---- logging helpers ------------------------------------------------------
# Mirror ALL script output (and every command's output) to the log file.
exec > >(tee -a "$LOG") 2>&1

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
hr()  { printf '%s\n' "========================================================================"; }
say() { printf '[%s] %s\n' "$(ts)" "$*"; }

# run <label> -- <command...>   : logs cmd, runs it, captures rc + duration, never aborts
run() {
  local label="$1"; shift
  [ "$1" = "--" ] && shift
  hr
  say "STEP: $label"
  say "CMD : $*"
  local start end rc
  start=$(date +%s)
  # Use `script`-free capture: we are already tee'd, so just run inline.
  "$@"
  rc=$?
  end=$(date +%s)
  say "EXIT: $rc   (${label}, $((end - start))s)"
  if [ $rc -ne 0 ]; then
    say "  ^^ NON-ZERO EXIT — captured above. Continuing."
  fi
  return $rc
}

trap 'say "field-test.sh exiting (last rc=$?). Bundle: $OUT_DIR"' EXIT

# ---- 0. banner + environment ---------------------------------------------
hr
say "austro field test — bundle: $OUT_DIR"
say "args: ecus=[$ECUS] hours=$HOURS live-secs=$LIVE_SECS dump=$DO_DUMP"
hr

say "--- host ---"
sw_vers 2>/dev/null
uname -a
echo "arch: $(uname -m)"
date

say "--- PCAN-USB adapter (PEAK vendor 0x0c72) ---"
# system_profiler is the authoritative macOS USB enumeration; grep the PEAK tree.
# Enumerate USB two ways — system_profiler is informative but can return nothing
# (it sometimes times out); ioreg is the more reliable presence check.
: > "$OUT_DIR/usb-full.txt"
command -v system_profiler >/dev/null 2>&1 && \
  system_profiler SPUSBDataType 2>/dev/null >> "$OUT_DIR/usb-full.txt"
command -v ioreg >/dev/null 2>&1 && \
  { echo "--- ioreg IOUSBHostDevice ---" >> "$OUT_DIR/usb-full.txt"; \
    ioreg -rc IOUSBHostDevice -l -w 0 2>/dev/null >> "$OUT_DIR/usb-full.txt"; }
if grep -iqE 'PCAN|PEAK|0x0c72|"idVendor" = 3186' "$OUT_DIR/usb-full.txt"; then
  say "PCAN-USB FOUND:"
  grep -iE -A4 'PCAN|PEAK|idVendor.*3186' "$OUT_DIR/usb-full.txt" | head -20 | sed 's/^/    /'
elif [ -s "$OUT_DIR/usb-full.txt" ]; then
  say "!! PCAN-USB not matched in USB enumeration (tree saved to usb-full.txt)."
  say "   Advisory only — the CLI opens the adapter directly; if dump/live work, ignore this."
else
  say "?? Could not enumerate USB (system_profiler + ioreg both empty)."
  say "   Advisory only — this does NOT mean the adapter is missing; the CLI is the real test."
fi

say "--- PCBUSB driver library ---"
for p in /usr/local/lib/libPCBUSB.dylib /opt/homebrew/lib/libPCBUSB.dylib /Library/Frameworks/PCBUSB.framework; do
  [ -e "$p" ] && { say "present: $p"; ls -l "$p"; }
done

say "--- credentials (presence only, never contents) ---"
for f in ~/.config/austro/ae3.pass ~/.config/austro/ae3-ukey.json ~/.config/austro/library.json; do
  if [ -e "$f" ]; then say "present: $f ($(wc -c < "$f" | tr -d ' ') bytes)"; else say "MISSING: $f"; fi
done

# ---- resolve / build the binary ------------------------------------------
BIN=""
if [ -n "$BIN_OVERRIDE" ]; then
  BIN="$BIN_OVERRIDE"
elif [ -x "$REPO_ROOT/.build/release/austro" ]; then
  BIN="$REPO_ROOT/.build/release/austro"
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  say "no release binary found — building (swift build -c release)…"
  ( cd "$REPO_ROOT" && swift build -c release 2>&1 )
  BIN="$REPO_ROOT/.build/release/austro"
fi

if [ ! -x "$BIN" ]; then
  say "FATAL: could not find or build austro binary at $BIN"
  exit 1
fi
say "binary: $BIN"
ls -l "$BIN"
# Record linked libs so a dyld failure later is diagnosable.
otool -L "$BIN" 2>/dev/null > "$OUT_DIR/binary-linkage.txt" && say "linkage saved to binary-linkage.txt"

# All CLI output files (ae3/csv) collect here.
cd "$OUT_DIR"

# ---- 1. live (listen-only) -----------------------------------------------
run "live (listen-only, ${LIVE_SECS}s)" -- "$BIN" live "$LIVE_SECS"

# ---- 2. faults -----------------------------------------------------------
for e in $ECUS; do
  run "faults ECU $e" -- "$BIN" faults "$e"
done

# ---- 3. dump flash -> .ae3 + csv -----------------------------------------
if [ "$DO_DUMP" -eq 1 ]; then
  for e in $ECUS; do
    csv="dump-ECU${e}-${HOURS}h.csv"
    run "dump ECU $e ($HOURS h)" -- "$BIN" dump "$e" "$HOURS" --csv "$csv"
    # verify outputs
    hr
    say "VERIFY: dump ECU $e outputs"
    if [ -s "$csv" ]; then
      say "  CSV ok: $csv ($(wc -l < "$csv" | tr -d ' ') lines)"
      say "  header: $(head -1 "$csv" | cut -c1-80)…"
    else
      say "  !! CSV missing or empty: $csv"
    fi
    # newest .ae3 written this run (dump writes serial-tagged, never-overwriting)
    newest_ae3="$(ls -t *.ae3 2>/dev/null | head -1)"
    if [ -n "$newest_ae3" ] && [ -s "$newest_ae3" ]; then
      say "  AE3 ok: $newest_ae3 ($(wc -c < "$newest_ae3" | tr -d ' ') bytes)"
    else
      say "  !! no .ae3 produced (expected on macOS; Linux is CSV-only)"
    fi
  done
else
  say "dump skipped (--skip-dump)"
fi

# ---- summary --------------------------------------------------------------
hr
say "DONE. Debug bundle contents:"
ls -la "$OUT_DIR" | sed 's/^/    /'
hr
say "To share for debugging:"
say "    zip -r \"${OUT_DIR}.zip\" \"$OUT_DIR\""
say ""
say "NOTE: the .ae3 files contain real flight data and the log may contain engine"
say "serials — treat the bundle as private; do not post it publicly."
