# Copilot Instructions for paperlike13k_macos

## Build commands

- Build both the native macOS menu bar app and CLI tool:
  - `bash build_native_app.sh`
- No automated test suite or linter configuration is present in this repository.

## High-level architecture

- This repo has two native Swift control paths for the same Paperlike serial protocol:
  - `paperlike` CLI: standalone command-line tool with daemon mode, query, monitor, and direct command support.
  - `PaperlikeNative.app`: SwiftUI menu bar app with GUI controls, auto-refresh, and global hotkeys.
- Shared code lives in `PaperlikeSerial.swift`:
  - `SerialPort`: low-level POSIX serial I/O (`@unchecked Sendable`)
  - `PaperlikeProtocol`: packet construction and parsing
  - `SerialWorker`: thread-safe serial command dispatch via DispatchQueue (`@unchecked Sendable`)
  - `DisplayDriverInitializer`: IOKit-based GPU dither disabling
- GUI-specific code:
  - `PaperlikeManager.swift`: `NativeDaemonManager` (`@MainActor ObservableObject`) drives SwiftUI via `Task`/`Task.detached` bridging to `SerialWorker`
  - `PaperlikeNativeApp.swift`: SwiftUI views, settings window, global shortcut manager
  - `CarbonHotkeyManager.swift`: Carbon-based global hotkey registration
- CLI-specific code:
  - `PaperlikeCLI.swift`: argument parsing, serial operations, daemon loop with signal handling and reconnect
- Packaging is manual: `build_native_app.sh` compiles with `swiftc` (no Xcode project). GUI and CLI are separate compilation units sharing `PaperlikeSerial.swift`.

## Key conventions

- Swift 6 strict concurrency throughout. Serial I/O isolated in `SerialWorker` (`@unchecked Sendable`), UI state on `@MainActor`.
- Preserve protocol casing and framing exactly; lowercase hex payloads are ignored by the MCU.
- Keep serial settings aligned: 115200, 8N1, no flow control, DTR/RTS low.
- Treat `0x20 0x01` as required keepalive/activation and send `0x20 0x00` during shutdown paths.
- Persist user settings in `UserDefaults` with existing keys (`paperlikeMode`, `refreshKeyCode`, `refreshModifiers`, `autoRefreshEnabled`, `autoRefreshMinutes`).
