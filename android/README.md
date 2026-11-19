# Austro Reader for Android

A native Android app (Kotlin + Jetpack Compose) that reads Austro AE300 / E4 engine data
through a **PEAK PCAN-USB** adapter plugged into the phone's USB-C port. It uses the
Android USB Host API directly: no root and no PEAK driver.

It is the Android counterpart of the `austro` command-line tool in this repository and is
**read-only** in the same way: the write, erase, clear and reset services are blocked in
code (`can/Kwp.kt`), and that block is covered by unit tests.

> Independent project, not affiliated with or endorsed by Austro Engine, Diamond Aircraft
> or PEAK-System. Use on the **ground, engine off**, at your own risk. Connecting
> non-approved devices to a certified aircraft may be regulated; check with your mechanic.

## What it does

| Tab | What it does | Transmits on the bus? | Needs your keys? |
|---|---|---|---|
| **Live** | Streams the engine's broadcast data (per-ECU ENG1 / ENG2 readings) | No, listen-only | No |
| **Log** | Opens a Wizard `.ae3` datalogger export and shows per-session and per-signal summaries | No bus access | Passphrase |
| **Faults** | Reads stored fault codes (DTCs) from ECU A or B | Yes, read requests | Key mask |
| **Flash** | Reads the datalogger flash from ECU A or B and saves a `.ae3` file | Yes, read requests | Both |

## Status

- **Builds, and its unit tests pass** (decoder, USB frame parser, read-only allowlist).
- **Not yet verified on a phone against a real adapter and engine.** The PCAN-USB bring-up
  and the diagnostic flows are ports of the working macOS implementation, but treat the
  first on-device run as a test.
- **Known issue:** fault reading opens the diagnostic session before security access. The
  command-line tool hit an ECU rejection (NRC 0x33) with that ordering, so expect the
  Faults tab to fail the same way until it is changed.

## What you need

- An Android phone or tablet with **USB host (OTG)** support, Android 7.0 (API 24) or later.
- A **PEAK PCAN-USB** adapter (USB ID `0C72:000C`), a USB-C OTG adapter or cable, and the
  harness to the engine's diagnostic connector. The adapter is bus-powered; no hub needed.
- A computer with either **Android Studio**, or **JDK 17** plus the Android SDK
  (platform 35), to build the app. There is no prebuilt APK: see "Why no APK" below.
- For anything beyond the Live tab, your **two keys** from your own licensed AE300 Wizard.

## 1. Add your keys

The app needs the same two constants as the command-line tool. They are not in this
repository. Extract them from your own Wizard install with the guided script in the
repository root (details in the [main README](../README.md)):

```sh
bash scripts/setup-keys.sh
```

That writes `~/.config/austro/ae3.pass` and `~/.config/austro/ae3-ukey.json`. Then copy
them into `android/local.properties`, which is gitignored:

```sh
cd android
printf 'ae3Passphrase=%s\nae3Ukey=%s\n' \
  "$(cat ~/.config/austro/ae3.pass)" \
  "$(tr -d ' \n' < ~/.config/austro/ae3-ukey.json)" >> local.properties
```

You can skip this step if you only want the Live tab. The other tabs report a missing-key
error without it.

## 2. Build and install

### With Android Studio (simplest)

1. Open the `android` folder in Android Studio and let it sync. It installs the SDK and
   writes `sdk.dir` into `local.properties` for you.
2. On the phone, enable **Developer options** (tap *Build number* seven times in
   *Settings → About phone*), then turn on **USB debugging**.
3. Connect the phone to the computer, accept the debugging prompt, pick the phone in the
   device menu and press **Run**.

### From the command line

```sh
cd android
export JAVA_HOME=/path/to/jdk-17          # e.g. /opt/homebrew/opt/openjdk@17 on macOS
export ANDROID_HOME=~/Library/Android/sdk # or set sdk.dir in local.properties

./gradlew :app:testDebugUnitTest          # optional: run the unit tests
./gradlew :app:installDebug               # build and install on the connected phone
```

`installDebug` needs USB debugging enabled as above. To copy the APK by hand instead, run
`./gradlew :app:assembleDebug` and install `app/build/outputs/apk/debug/app-debug.apk`
with `adb install` or by opening the file on the phone.

### Why no APK

Your keys are compiled into the app (`BuildConfig`), so **an APK you build contains your
passphrase and key mask**. Do not share it or upload it anywhere. For the same reason this
project does not publish a prebuilt APK.

## 3. Use it

1. Unplug the phone from the computer and connect the PCAN-USB adapter through the OTG
   adapter. Android offers to open Austro Reader; allow USB access when asked.
2. **Live:** tap *Connect*. The adapter is put in listen-only mode, so the app never
   transmits or acknowledges in this tab.
3. **Faults / Flash:** choose ECU A or B and tap the read button. These tabs send
   diagnostic read requests to the ECU. Saved `.ae3` files are written to the app's
   storage and the path is shown when the read finishes.
4. **Log:** open any `.ae3` export (or an already decrypted `.xml`) from the phone.

## How it works

- `res/xml/device_filter.xml` matches the adapter (vendor `0x0C72`, product `0x000C`), so
  Android launches the app when it is attached.
- `can/PcanUsbSource.kt` claims the adapter's interface and runs the bring-up (500 kbit/s,
  listen-only for Live, normal mode for diagnostics); `can/PcanFrameParser.kt` decodes its
  USB records into CAN frames.
- `core/BroadcastDecoder.kt` turns the broadcast frames into engine readings.
- `can/Kwp.kt` implements KWP2000 over ISO-TP with the read-only service allowlist.
- `can/EcuDatalogReader.kt`, `can/Ae3Crypto.kt` and `can/Ae3Decoder.kt` read the
  datalogger flash and write and decode `.ae3` files.

## Tests

```sh
./gradlew :app:testDebugUnitTest
```

`Ae3CryptoTest` decrypts a real capture and is skipped unless you point it at one of your
own exports: `AE3_SAMPLE=/path/to/DataLog.ae3 ./gradlew :app:testDebugUnitTest`.

## Licensing note

The PCAN-USB protocol layer was written using the GPL-2.0 Linux kernel driver
(`drivers/net/can/usb/peak_usb/pcan_usb.c`) as a protocol reference; it is a
reimplementation, not a copy of that code.
