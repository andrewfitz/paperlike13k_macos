# Paperlike 13K 2025 Color — macOS

Open-source native macOS controller for the DASUNG Paperlike 13K 2025 color e-ink display.
Replaces the proprietary PaperLikeClient app with a Swift menu bar app and CLI tool.

## Requirements

- macOS 15+ (Apple Silicon)
- Xcode Command Line Tools (`xcode-select --install`)
- CH34x VCP driver (often built-in on modern macOS, or from WCH website)

## Build

```bash
bash build_native_app.sh
```

This produces two binaries:
- `PaperlikeNative.app` — menu bar GUI app
- `paperlike` — CLI tool

## GUI App

```bash
open PaperlikeNative.app
```

The menu bar app provides:
- Display mode selection (Web, Text, Image, Active, Heavy)
- Darkness/speed slider (1–8)
- Brightness slider (0–64)
- Front light control (Off, Cold, Warm, Both)
- Auto-refresh on a configurable interval
- Global keyboard shortcut for force refresh
- Automatic device detection, keepalive, and reconnect

Settings are persisted across launches.

## CLI Tool

```bash
# Init and keep display alive (recommended):
./paperlike --daemon

# Adjust display settings (can combine multiple):
./paperlike --mode 3                    # Display mode 1-6
./paperlike --brightness 32             # Brightness 0-64
./paperlike --speed 5                   # Speed/darkness 1-8
./paperlike --temperature 3             # Color temperature 0-5
./paperlike --front-light 1             # Front light (0=off 1=warm 2=cold 3=both)
./paperlike --refresh                   # Force full refresh
./paperlike --query                     # Query device info
./paperlike --monitor                   # Monitor serial traffic
./paperlike --send 0x02 0x03            # Send raw command
./paperlike --mode 3 --brightness 32 --daemon   # Combine
./paperlike /dev/cu.usbserial-1410 --daemon     # Specify port manually
```

In daemon mode, the CLI handles USB disconnect/reconnect automatically.

### Display modes

| Mode | Name   |
|------|--------|
| 1    | Web    |
| 2    | Text   |
| 3    | Image  |
| 4    | Active |
| 5    | Heavy  |

## Hardware

- **Display**: Paperlike 13K 2025 Color, 3200x2400 @ 37Hz
- **Connection**: USB-C (DisplayPort Alt Mode + USB data)
- **Control**: CH340 serial (VID:PID 0x1a86:0x7523) at 115200 8N1

## Serial protocol

24 ASCII hex characters, **UPPERCASE** (MCU is case-sensitive):

```
5FF5 CC OO PPPPPPPPPPPP A0FA
     |  |  |            └ trailer
     |  |  └ payload (6 bytes, usually zeros)
     |  └ option byte
     └ command byte
```

### Commands

| CMD  | OPT   | Description |
|------|-------|-------------|
| 0x01 | 1-8   | Set speed/threshold |
| 0x02 | 1-6   | Set display mode |
| 0x03 | 1     | Force refresh |
| 0x07 | 0-3   | Set front light (0=off, 1=warm, 2=cold, 3=both) |
| 0x08 | 0-5   | Set color temperature |
| 0x09 | 0-64  | Set brightness |
| 0x0A | *     | Query (opt selects parameter) |
| 0x20 | 0/1   | Activate/deactivate display |

The display stays active only with periodic `0x20 0x01` commands (~10s interval).
On shutdown, send `0x20 0x00` to deactivate cleanly.
