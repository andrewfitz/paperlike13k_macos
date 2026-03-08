# Copilot Instructions for paperlike13k_macos

## Build, test, and lint commands

- Build the native macOS menu bar app bundle:
  - `bash build_native_app.sh`
  - Note: the script uses a hardcoded `cd /Users/maoyuankao/src/paperlike/paperlike13k_macos`.
- Python dependency setup for the init/daemon script:
  - `pip install pyserial`
- Quick script sanity check:
  - `python3 paperlike_init_macos.py --help`
- Tests/lint:
  - No automated test suite or linter configuration is present in this repository, so there is no single-test command to run.

## High-level architecture

- This repo has two control paths for the same Paperlike serial protocol:
  - `paperlike_init_macos.py`: CLI + optional daemon mode with a Unix socket (`paperlike.sock`) for forwarding commands from later invocations.
  - Swift native app (`PaperlikeNativeApp.swift` + `PaperlikeCore.swift`): menu bar UI that talks directly to the serial device and keeps it alive.
- Protocol logic is mirrored in both implementations:
  - Packet format: 24 ASCII hex chars, uppercase only, `5FF5` prefix and `A0FA` suffix.
  - Core commands include mode/speed/brightness/front-light updates, query (`0x0A`), refresh (`0x03`), and activate/deactivate (`0x20`).
- In the Swift app, `NativeDaemonManager` owns device lifecycle:
  - Connects to `/dev/cu.usbserial*` or `/dev/cu.wchusbserial*`
  - Performs activation and startup queries
  - Sends periodic keepalive pings every 10s
  - Reconnects automatically if the port is lost.
- Global hotkey support is implemented via Carbon (`CarbonHotkeyManager.swift`) and wired into `GlobalShortcutManager` in `PaperlikeNativeApp.swift`.
- Packaging is manual: `build_native_app.sh` writes `Info.plist` and compiles Swift files with `swiftc` into `PaperlikeNative.app` (no Xcode project/workspace in this repo).

## Key conventions

- Preserve protocol casing and framing exactly; lowercase hex payloads are ignored by the MCU.
- Keep serial settings aligned across implementations: 115200, 8N1, no flow control, DTR/RTS low.
- Treat `0x20 0x01` as required keepalive/activation and send `0x20 0x00` during shutdown paths.
- Keep UI thread safety in Swift by publishing UI state changes on `DispatchQueue.main`.
- Persist Swift UI user settings in `UserDefaults` with existing keys (`paperlikeMode`, `refreshKeyCode`, `refreshModifiers`) instead of introducing new storage patterns.
