# Babelfin loopback drivers

This directory builds two virtual audio devices for Babelfin:

- **Babelfin Microphone** carries translated speech from Babelfin to a meeting app.
  Select it as the microphone in the meeting app.
- **Babelfin Speaker** carries meeting audio from a meeting app to Babelfin.
  Select it as the speaker in the meeting app.

Each device is a two-channel loopback. Each driver also publishes a hidden mirror device.
Babelfin uses two separate drivers so that the two directions never share one loopback.

## Source and license

The drivers are built from BlackHole by Existential Audio Inc., licensed under GPL-3.0.
`upstream/BlackHole.c` is an unmodified copy of upstream commit `574029f` (version 0.7.1).
`upstream/LICENSE`, `upstream/VERSION` and `upstream/COMMIT` record the license and origin.

The BlackHole license does not permit the BlackHole name, logo or trademarks on modified
builds. The build therefore sets all names through compile-time macros. It also replaces
four string literals that do not use the macros: the box name, the plug-in name, the
manufacturer name and one log message. The build makes these replacements in a copy under
`.build/loopback-drivers/` and does not change `upstream/`.

The driver binaries are GPL-3.0. A release that ships them must include the GPL-3.0 text
and must offer the corresponding source: `upstream/`, `build-drivers.sh` and `Info.plist.in`.
The Babelfin app communicates with the drivers only through Core Audio device APIs.

## Build

Run this command from the repository root:

```sh
zsh Drivers/BabelfinLoopback/build-drivers.sh
```

The script needs the Command Line Tools (clang and codesign). It writes universal
(arm64 and x86_64) bundles with an ad-hoc signature to `.build/loopback-drivers/`.
To write the bundles to a different directory, give that directory as the first argument.

| Bundle | Bundle identifier | Device UID |
| --- | --- | --- |
| `Babelfin Microphone.driver` | `no.tallmaker.Babelfin.Microphone` | `Babelfin Microphone_UID` |
| `Babelfin Speaker.driver` | `no.tallmaker.Babelfin.Speaker` | `Babelfin Speaker_UID` |

## Install

> **Caution:** Installation needs administrator rights and a restart of Core Audio. All
> audio stops for a few seconds. Only the Mac owner does this step. The build script never
> installs a driver or changes audio defaults.

Release builds do not include the drivers yet. It is not verified that Core Audio loads
the ad-hoc signed drivers on other Macs; Developer ID signing may be necessary. Until then,
users install BlackHole.

With `BABELFIN_BUNDLE_DRIVERS=1`, `scripts/build-app.sh` runs this build and copies both
bundles and the GPL-3.0 text to `Babelfin.app/Contents/Resources/AudioDrivers/`. When an
app contains them, Settings → Audio devices →
**Install** copies the two bundles to `/Library/Audio/Plug-Ins/HAL/` and restarts Core
Audio. **Remove** deletes the same two bundles and restarts Core Audio. Each action uses
one administrator prompt and touches no other file in that folder.

To install a build by hand:

1. Copy both bundles to `/Library/Audio/Plug-Ins/HAL/`.
2. Restart Core Audio with `sudo killall -9 coreaudiod`, or restart the Mac.
3. Open Audio MIDI Setup and make sure that both devices are visible.

A public release needs a Developer ID signature and notarization. An ad-hoc signature is
for local tests only.

To remove the drivers, delete both bundles from `/Library/Audio/Plug-Ins/HAL/`. Then
restart Core Audio.
