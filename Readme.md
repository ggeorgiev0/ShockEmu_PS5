# ShockEmu_PS5

ShockEmu maps local keyboard and mouse input to a virtual DualShock 4 as seen by Sony's PS Remote Play client on macOS. This modernization replaces the original Python code generator, global Objective-C method swizzling, magic pointers, and flat-namespace injection with a tested Swift Package Manager build and a scoped IOKit interposer.

This repository currently targets one verified setup:

- Apple M3 Pro
- macOS 26.5 with System Integrity Protection enabled
- Xcode 26.6
- PS Remote Play 9.0.0 (`com.playstation.RemotePlay`)
- Sony team identifier `8UT4NVUACP`
- Remote Play executable SHA-256 `6e6e09495de366ae5a1264442cf3395c0f97ee7a03f493afa838cc9451401612`

Other Remote Play versions and hashes are blocked. There is deliberately no override.

> This fork has no license file. Treat it as personal research code; redistribution and relicensing are out of scope.

## Safety model

ShockEmu never modifies `/Applications/RemotePlay.app`. `prepare` copies it beneath `~/Library/Application Support/ShockEmu`, removes hardened runtime only from that disposable copy through ad-hoc signing, preserves the microphone entitlement, and verifies the complete copy. SIP and AMFI stay enabled.

Generated artifacts and logs are owner-only. Cleanup resolves canonical paths and removes only paths named by ShockEmu's versioned manifest. The runtime does not record characters, key codes, modifiers, mouse deltas, credentials, or full home-directory paths.

True virtual HID through CoreHID is not used because it requires restricted Apple entitlements. ShockEmu instead presents its fake controller only to Remote Play's verified controller-discovery manager.

## Quick start

Quit every running PS Remote Play instance, then build and validate the local setup:

```zsh
git clone https://github.com/ggeorgiev0/ShockEmu_PS5.git
cd ShockEmu_PS5
swift build -c release
.build/release/shockemu doctor
.build/release/shockemu profile validate darktide.se
```

Start Remote Play with the verified keyboard-and-mouse profile:

```zsh
.build/release/shockemu run \
  --profile darktide.se \
  --input-source local \
  --verbose
```

`run` automatically prepares or refreshes the disposable Remote Play copy, so an explicit `prepare` command is optional. Connect to the PS5 normally once the app opens. Keep the Terminal process running for the entire session.

## Build and inspect

Install Xcode 26.6 or compatible command-line tools, then run:

```zsh
swift test
swift build -c release
.build/release/shockemu doctor
```

Core coverage is enforced at 80%:

```zsh
./Scripts/check-core-coverage.sh
```

`doctor` verifies the Sony signature, bundle version, executable hash, required IOKit imports, SIP status, and any prepared cache.

The release injection harness exercises the actual dylib through dyld:

```zsh
./IntegrationTests/run-interpose-harness.sh
```

## Profiles

Validate a profile before launch:

```zsh
.build/release/shockemu profile validate only_keyboard.se
```

Each mapping has the form `input = output`; `#` starts a comment. Existing keyboard names, mouse buttons, controller buttons, axes, and mouse-look settings remain compatible.

```text
w = leftY-
space = X
shift = O
leftMouse = R1

mouseLook.type = linear
mouseLook.stick = right
mouseLook.sensitivity = 0.04
mouseLook.smoothing = 0.65
mouseLook.minimumMagnitude = 0
mouseLook.decay = 10
mouseLook.deadZone = 0.1
mouseLook.multX = 1
mouseLook.multY = -1
```

One input can drive several distinct outputs. Exact duplicate lines are ignored with a warning. Multiple inputs mapped to one button use OR semantics; axis contributions are summed and clamped, so opposing inputs cancel. Malformed lines, unknown names, unsupported mouse-look types, and invalid ranges produce line-numbered errors.

`mouseLook.minimumMagnitude` radially raises any active mouse movement into a minimum analog-stick range. A value such as `0.85` skips a game's slow-pan range while preserving direction; the default `0` retains fully analog movement.

## Warhammer 40,000: Darktide controls

The tuned `darktide.se` profile uses these mappings:

| DualShock input | Keyboard or mouse |
|---|---|
| Left stick | W / A / S / D |
| Right stick | Mouse movement |
| Cross (X) | Space |
| Circle | C |
| Square | R |
| Triangle | Tab |
| L1 | T |
| L2 | Right mouse button |
| L3 | Shift |
| R1 | G |
| R2 | Left mouse button |
| R3 | Middle mouse button |
| D-pad Up / Left / Right / Down | F / Q / E / V |
| Options | Escape |
| PS button | P |
| Share / Touchpad | Unmapped |

Mouse look starts at 25% stick magnitude, uses a base sensitivity of `0.075`, and applies horizontal/vertical multipliers of `2.25`/`1.75`. Final camera speed is intended to be adjusted in Darktide. The Y direction is tuned for local AppKit capture.

While streaming, the cursor is hidden and decoupled from its screen position. Press **Control–Option–M** to release/show it or capture/hide it again. Switching away from Remote Play also restores the cursor automatically.

## Prepare and run

Prepare explicitly, or let `run` prepare a stale or missing cache:

```zsh
.build/release/shockemu prepare
.build/release/shockemu run --profile only_keyboard.se
```

ShockEmu refuses to prepare, run, or clean while any Remote Play instance is already running. Keep the Terminal command open for the Remote Play session.

Input is active only while Remote Play is active and its verified `RPWindowStreaming` window is key. Events are returned unchanged to Remote Play. Losing focus clears all input immediately and emits a neutral controller report, preventing stuck keys.

While streaming, ShockEmu hides and decouples the cursor so mouse deltas continue at screen edges. Press **Control–Option–M** to release/show the cursor or capture/hide it again. Switching away from Remote Play always restores the cursor; returning captures it again unless the hotkey disabled capture.

The default `auto` source uses local AppKit events. `local` is the verified mode on this machine. If continuous mouse input proves unavailable, an experimental event-tap fallback is available:

```zsh
.build/release/shockemu run --profile darktide.se --input-source event-tap
```

macOS will request Input Monitoring access through its supported permission API. The event tap exists only while the streaming window is active. Grant access only if you choose this mode.

The event-tap permission/focus transition caused a controller disconnect in current manual testing. Prefer `--input-source local` unless debugging that fallback.

## Commands

```text
shockemu doctor
shockemu profile validate <file.se>
shockemu prepare [--force]
shockemu run --profile <file.se> [--input-source auto|local|event-tap] [--verbose]
shockemu clean [--logs]
```

`clean` removes the manifest-owned prepared app and runtime. Add `--logs` to remove ShockEmu's rotated logs as well. Logs rotate across five 1 MB files.

## Architecture

- `ShockEmuCore`: profile parsing, modifier/input state, mouse filtering, and DS4 report encoding.
- `ShockEmuRuntime`: Objective-C dylib with explicit `__DATA,__interpose` entries, AppKit capture, scoped IOKit state, and 120 Hz report timers.
- `shockemu`: validation, diagnostics, safe preparation, launch, and cleanup.
- `InterposeHarness`: direct release-dylib integration coverage.

The runtime returns real `IOHIDManagerRef` objects and keys lock-protected state by manager. Only Remote Play 9.0.0's captured 11-entry Sony gamepad criteria sees the owned fake device; unrelated managers and devices call the original IOKit functions. Report delivery uses the exact run loop and mode supplied by Remote Play.

## Troubleshooting

- **Unsupported version/hash:** reinstall the verified Remote Play 9.0.0 build. ShockEmu will not bypass this check.
- **Remote Play is already running:** quit every instance before `prepare`, `run`, or `clean`.
- **Runtime not found:** run `swift build -c release`, then use `.build/release/shockemu`.
- **Profile error:** run `shockemu profile validate`; errors include the source line.
- **No mouse movement:** first confirm the streaming window is key, then try `--input-source event-tap` and approve Input Monitoring.
- **Prepared copy cannot authenticate or stream:** stop. Do not disable SIP or weaken system security.

The legacy implementation could crash in `-[HIDRunner mouseDown:]` by dereferencing its global controller before initialization. The new runtime does not swizzle Remote Play classes and cannot handle input until its validated core and manager state exist.

## Manual acceptance checklist

Before calling a build complete on this machine, confirm:

1. The prepared copy signs in, connects to the PS5, and streams with SIP enabled.
2. `only_keyboard.se` works, including `shift = O`.
3. `darktide.se` supports WASD, mouse buttons, and smooth mouse-look.
4. Changing focus immediately returns the controller to neutral.
5. Event-tap mode works only after explicit Input Monitoring approval, if it is needed.
6. `shockemu clean` removes only ShockEmu-owned artifacts.

DualSense haptics, adaptive triggers, gyro, touch coordinates, public distribution, and broader Remote Play support are intentionally out of scope.
