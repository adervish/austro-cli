# austro — Austro AE300 engine data CLI

A small, **read-only** command-line tool to pull data from the Austro AE300 / E4 diesel
engine (as fitted to the Diamond DA40 NG / DA42) over its CAN bus, using an off-the-shelf
PEAK PCAN-USB adapter. Three modes:

```sh
austro dump [A|B] [hours|all] [--csv FILE] [--no-ae3]   # read the datalogger flash
austro live [seconds] [node]                            # stream live engine telemetry
austro faults [A|B]                                     # read stored fault codes (DTCs)
```

Builds on **macOS, Linux, and Windows (WSL2)**. It never transmits anything that writes to
the ECU — only read services (identification, datalogger, DTC list/detail) are ever sent;
the write/erase/clear services are hard-blocked in code.

> Independent project, not affiliated with or endorsed by Austro Engine, Diamond Aircraft,
> or PEAK-System. You supply your own keys from your own licensed Wizard (see below). Use on
> the **ground, engine off**, at your own risk; connecting non-approved devices to a
> certified aircraft may be regulated — check with your mechanic.

## What you need

- A **PEAK PCAN-USB** or **PCAN-USB FD** adapter (classic CAN, 500 kbit/s) and the correct
  harness to the engine's diagnostic connector.
- **macOS 14+** with the Swift toolchain (Xcode or Command Line Tools), **or** Linux / WSL2
  with Swift from [swift.org](https://www.swift.org/install/).
- Your **two keys**, extracted from your own licensed AE300 Wizard (next section).

## Getting your keys from the Wizard

The tool needs two constants that live inside the AE300 Wizard. They are **not** included
here — you extract them from **your own licensed Wizard install** and drop them in
`~/.config/austro/`:

| File | What it is | Needed for |
|------|-----------|-----------|
| `~/.config/austro/ae3.pass`       | the `.ae3` passphrase (AES key derivation) | `dump` writing `.ae3` files |
| `~/.config/austro/ae3-ukey.json`  | the ECU security key mask (seed→key)       | `dump` and `faults` (ECU security access) |

`live` needs neither.

### Automated (recommended)

Run the guided extractor. It decompiles your Wizard's `DataAbstraction.dll`, reads the two
constants, and writes them to `~/.config/austro/` (chmod 600). **Values are never printed,
uploaded, or committed.**

```sh
bash scripts/setup-keys.sh
```

Requirements: `python3` and the **.NET SDK** (for the ILSpy decompiler — `brew install dotnet`
on macOS). You point it at the folder containing `AE 300 - Wizard.exe` and
`DataAbstraction.dll` (drag the folder into the terminal when prompted).

What it pulls, for reference:
- `ae3.pass`      ← `ConfigSecurity.zauberwort` (a short ASCII string)
- `ae3-ukey.json` ← `ConfigKWP.uKey_DiagMask_cu8` (an 8×4 integer array, written as JSON)

### Manual / environment variables

If you already know the values (or prefer not to run the extractor), create the files
yourself:

```sh
mkdir -p ~/.config/austro && chmod 700 ~/.config/austro
printf '%s' 'YOUR_PASSPHRASE' > ~/.config/austro/ae3.pass && chmod 600 ~/.config/austro/ae3.pass
# 8 rows of 4 integers, e.g.:  [[..,..,..,..],[..,..,..,..], ... 8 rows ... ]
echo '[[...],[...],[...],[...],[...],[...],[...],[...]]' > ~/.config/austro/ae3-ukey.json
chmod 600 ~/.config/austro/ae3-ukey.json
```

Or pass them per-run via environment variables instead of files:
`AE3_PASSPHRASE=...`, and `AE3_UKEY=/path/to/ukey.json`.

## Install (macOS)

Builds the CLI and installs it together with its MacCAN PCBUSB runtime library:

```sh
bash scripts/install-macos.sh                   # -> /usr/local (sudo if needed)
PREFIX=~/.local bash scripts/install-macos.sh   # user install, no sudo
bash scripts/install-macos.sh --uninstall       # remove it
```

It also checks for your `~/.config/austro/` keys and points you at `setup-keys.sh` if
they're missing.

## Build from source

**macOS:**
```sh
bash scripts/fetch-pcbusb.sh          # downloads the MacCAN PCBUSB library (not redistributed here)
swift build -c release --product austro
.build/release/austro --help
```

**Linux / WSL2** (SocketCAN; on WSL2 attach the PEAK adapter with `usbipd`):
```sh
sudo ip link set can0 up type can bitrate 500000
swift build -c release --product austro
CAN_IF=can0 .build/release/austro live 10       # $CAN_IF selects the interface (default can0)
```

(On Linux, `dump` emits CSV only — writing encrypted `.ae3` needs AES, which is wired to
Apple's CommonCrypto here.)

## Usage

```sh
austro live 10            # 10 s of live telemetry (listen-only; no keys needed)
austro dump A 2           # last ~2 h of ECU A's flash -> ./DataLog_A_…ae3 + CSV on stdout
austro dump B all --csv out.csv   # all of ECU B -> out.csv (+ a .ae3 in the current dir)
austro dump A --no-ae3    # CSV only, no .ae3
austro faults A           # stored fault codes on ECU A
```

`dump` and `faults` transmit diagnostic requests, so run them with the **engine off on the
ground**. `live` is passive.

## Safety

- **Read-only by design.** The KWP service allowlist is `0x81, 0x10, 0x27, 0x3E, 0x21,
  0x20, 0x1A, 0x18, 0x17` — start/stop communication, session, security *read*,
  tester-present, read-by-local-id, read ident, and DTC list/detail. Any attempt to send a
  write/erase/program/clear service throws before a frame leaves the adapter. Unit tests
  assert the allowlist and that `0x14` (clear DTCs) and `0x3B` (write) stay blocked.
- The datalogger read maps the flash ring buffer and decodes it; it does not erase or
  modify anything.

## Credits

- CAN access on macOS uses the **MacCAN PCBUSB** library © UV Software (freeware), fetched
  at build time from its [official release](https://github.com/mac-can/PCBUSB-Library) — not
  redistributed here.
- `.ae3` format, signal scaling, and the diagnostic protocol were recovered from the AE300
  Wizard and validated against its own output.
