import Foundation

// MARK: - Argument Parsing

struct CLIArgs {
    var port: String?
    var daemon = false
    var interval = 10
    var mode: Int?
    var speed: Int?
    var brightness: Int?
    var temperature: Int?
    var frontLight: Int?
    var refresh = false
    var query = false
    var monitor = false
    var rawCommands: [(UInt8, UInt8)] = []
    var help = false
}

func printUsage() {
    let name = (CommandLine.arguments.first! as NSString).lastPathComponent
    print("""
    Paperlike 13K 2025 Color - macOS CLI

    Usage: \(name) [port] [options]

    Options:
      --daemon              Keep display alive (recommended for standalone use)
      --interval N          Keepalive interval in seconds (default: 10)
      --mode 1-6            Set display mode (1=Web 2=Text 3=Image 4=Active 5=Heavy)
      --speed 1-8           Set speed/darkness threshold
      --brightness 0-64     Set brightness
      --temperature 0-5     Set color temperature
      --front-light 0-3     Set front light (0=off 1=warm 2=cold 3=both)
      --refresh             Force display refresh
      --query               Query device info
      --monitor             Monitor serial traffic (Ctrl+C to stop)
      --send CMD OPT        Send raw command (hex or decimal)
      --help                Show this help

    Examples:
      \(name) --daemon                          Init + keep alive
      \(name) --mode 3 --brightness 32          Set mode and brightness
      \(name) --query                           Query all device info
      \(name) --refresh                         Force display refresh
      \(name) --send 0x02 0x03                  Send raw command
      \(name) /dev/cu.usbserial-1410 --daemon   Specify port manually

    Display modes: 1=Web  2=Text  3=Image  4=Active  5=Heavy
    """)
}

func parseIntArg(_ argv: [String], _ i: inout Int, name: String, range: ClosedRange<Int>) -> Int {
    i += 1
    guard i < argv.count, let val = Int(argv[i]), range.contains(val) else {
        fputs("Error: \(name) requires integer \(range.lowerBound)-\(range.upperBound)\n", stderr)
        exit(1)
    }
    return val
}

func parseHexOrDec(_ s: String) -> UInt8? {
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        return UInt8(s.dropFirst(2), radix: 16)
    }
    return UInt8(s)
}

func parseArgs() -> CLIArgs {
    var args = CLIArgs()
    let argv = Array(CommandLine.arguments.dropFirst())
    var i = 0

    while i < argv.count {
        let arg = argv[i]
        switch arg {
        case "--daemon":
            args.daemon = true
        case "--interval":
            args.interval = parseIntArg(argv, &i, name: "--interval", range: 1...3600)
        case "--mode":
            args.mode = parseIntArg(argv, &i, name: "--mode", range: 1...6)
        case "--speed":
            args.speed = parseIntArg(argv, &i, name: "--speed", range: 1...8)
        case "--brightness":
            args.brightness = parseIntArg(argv, &i, name: "--brightness", range: 0...64)
        case "--temperature":
            args.temperature = parseIntArg(argv, &i, name: "--temperature", range: 0...5)
        case "--front-light":
            args.frontLight = parseIntArg(argv, &i, name: "--front-light", range: 0...3)
        case "--refresh":
            args.refresh = true
        case "--query":
            args.query = true
        case "--monitor":
            args.monitor = true
        case "--send":
            guard i + 2 < argv.count,
                  let cmd = parseHexOrDec(argv[i + 1]),
                  let opt = parseHexOrDec(argv[i + 2]) else {
                fputs("Error: --send requires two valid byte values (CMD OPT)\n", stderr)
                exit(1)
            }
            i += 2
            args.rawCommands.append((cmd, opt))
        case "--help", "-h":
            args.help = true
        default:
            if arg.hasPrefix("-") {
                fputs("Unknown option: \(arg)\n", stderr)
                exit(1)
            }
            args.port = arg
        }
        i += 1
    }
    return args
}

// MARK: - CLI Serial Helpers

func sendCommandVerbose(_ port: SerialPort, cmd: UInt8, opt: UInt8, label: String, wait: UInt32 = 200_000) -> [(cmd: UInt8, opt: UInt8, payload: String)] {
    let packet = PaperlikeProtocol.makePacket(cmd: cmd, opt: opt)
    port.writeString(packet)
    usleep(wait)
    let resp = port.readAvailable()
    let parsed = PaperlikeProtocol.parsePackets(resp)

    let nonHB = parsed.filter { !($0.cmd == 0xF5 && $0.opt == 0x20) }
    let pad = label.padding(toLength: 22, withPad: " ", startingAt: 0)
    if !nonHB.isEmpty {
        for p in nonHB {
            print("  TX 0x\(hex(cmd)),0x\(hex(opt)) [\(pad)] -> RESP 0x\(hex(p.cmd)),0x\(hex(p.opt)) \(p.payload)")
        }
    } else {
        let status = parsed.isEmpty ? "(none)" : "heartbeat"
        print("  TX 0x\(hex(cmd)),0x\(hex(opt)) [\(pad)] -> \(status)")
    }
    return parsed
}

func queryDeviceInfo(_ port: SerialPort) {
    let queries: [(UInt8, String)] = [
        (0x10, "MCU version"),
        (0x13, "Display version/modes"),
        (0x01, "Speed/threshold"),
        (0x02, "Display mode"),
        (0x07, "Front light mode"),
        (0x09, "Brightness"),
        (0x08, "Color temperature"),
    ]
    for (opt, label) in queries {
        let wait: UInt32 = opt == 0x10 ? 400_000 : 200_000
        let pkts = sendCommandVerbose(port, cmd: 0x0A, opt: opt, label: "Query \(label)", wait: wait)
        for p in pkts where p.cmd == 0xF0 && p.payload.count >= 4 {
            let s = p.payload.index(p.payload.startIndex, offsetBy: 2)
            let e = p.payload.index(p.payload.startIndex, offsetBy: 4)
            if let val = UInt8(p.payload[s..<e], radix: 16) {
                print("    \(label) = \(val)")
            }
        }
    }
}

func waitForHeartbeat(_ port: SerialPort, timeout: TimeInterval = 6) -> Bool {
    let start = Date()
    while Date().timeIntervalSince(start) < timeout {
        let data = port.readAvailable()
        if !data.isEmpty {
            let pkts = PaperlikeProtocol.parsePackets(data)
            if pkts.contains(where: { $0.cmd == 0xF5 }) { return true }
        }
        usleep(50_000)
    }
    return false
}

func activateDisplay(_ port: SerialPort) {
    print("\n--- Waiting for heartbeat ---")
    if waitForHeartbeat(port) {
        print("  Heartbeat received - MCU alive")
    } else {
        print("  WARNING: No heartbeat (continuing anyway)")
    }

    print("\n--- Query device info ---")
    queryDeviceInfo(port)

    print("\n--- Activate display ---")
    _ = sendCommandVerbose(port, cmd: 0x20, opt: 0x01, label: "Activate display", wait: 300_000)

    print("\n--- Monitoring (5s) ---")
    let start = Date()
    while Date().timeIntervalSince(start) < 5 {
        let data = port.readAvailable()
        if !data.isEmpty {
            for p in PaperlikeProtocol.parsePackets(data) {
                let kind = p.cmd == 0xF5 ? "HB" : "0x\(hex(p.cmd))"
                print("  [\(String(format: "%.1f", Date().timeIntervalSince(start)))s] \(kind) opt=0x\(hex(p.opt))")
            }
        }
        usleep(50_000)
    }
    print("\n--- Init complete ---")
}

func openPortOrExit(_ path: String) -> SerialPort {
    let port = SerialPort(path: path)
    guard port.openPort() else {
        fputs("Error: Failed to open \(path): \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }
    _ = port.readAvailable()
    return port
}

func resolvePort(_ specified: String?) -> String {
    if let p = specified { return p }
    if let p = SerialPort.findWCHPort() {
        print("Auto-detected: \(p)")
        return p
    }
    fputs("Error: No CH340/CH341 serial port found.\n", stderr)
    fputs("  Please ensure the device is connected and drivers are installed.\n", stderr)
    exit(1)
}

func hex(_ v: UInt8) -> String { String(format: "%02X", v) }

func timestamp() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss"
    return df.string(from: Date())
}

// MARK: - Signal Handling

nonisolated(unsafe) var shouldExit = false

func installSignalHandlers() {
    signal(SIGINT) { _ in shouldExit = true }
    signal(SIGTERM) { _ in shouldExit = true }
}

// MARK: - Main

@main
struct PaperlikeCLIMain {
    static func main() {
        let cliArgs = parseArgs()

        if cliArgs.help {
            printUsage()
            return
        }

        // Build command list
        var commands: [(cmd: UInt8, opt: UInt8, label: String)] = []
        if let m = cliArgs.mode       { commands.append((0x02, UInt8(m), "Set mode \(m)")) }
        if let s = cliArgs.speed      { commands.append((0x01, UInt8(s), "Set speed \(s)")) }
        if let b = cliArgs.brightness { commands.append((0x09, UInt8(b), "Set brightness \(b)")) }
        if let t = cliArgs.temperature { commands.append((0x08, UInt8(t), "Set temperature \(t)")) }
        if let f = cliArgs.frontLight { commands.append((0x07, UInt8(f), "Set front light \(f)")) }
        if cliArgs.refresh { commands.append((0x03, 0x01, "Force refresh")) }
        for (cmd, opt) in cliArgs.rawCommands {
            commands.append((cmd, opt, "Raw 0x\(hex(cmd)) 0x\(hex(opt))"))
        }

        // --- Query mode ---
        if cliArgs.query {
            let portPath = resolvePort(cliArgs.port)
            let port = openPortOrExit(portPath)
            queryDeviceInfo(port)
            port.closePort()
            return
        }

        // --- Monitor mode ---
        if cliArgs.monitor {
            let portPath = resolvePort(cliArgs.port)
            let port = openPortOrExit(portPath)
            print("Monitoring \(portPath) (Ctrl+C to stop)...")
            installSignalHandlers()
            while !shouldExit {
                let data = port.readAvailable()
                if !data.isEmpty {
                    for p in PaperlikeProtocol.parsePackets(data) {
                        let kind = p.cmd == 0xF5 ? "HB" : "0x\(hex(p.cmd))"
                        print("  [\(timestamp())] \(kind) opt=0x\(hex(p.opt)) \(p.payload)")
                    }
                }
                usleep(10_000)
            }
            port.closePort()
            return
        }

        // --- Send commands directly (no daemon) ---
        if !commands.isEmpty && !cliArgs.daemon {
            let portPath = resolvePort(cliArgs.port)
            let port = openPortOrExit(portPath)
            for c in commands {
                _ = sendCommandVerbose(port, cmd: c.cmd, opt: c.opt, label: c.label)
            }
            port.closePort()
            return
        }

        // --- Init (+ optional daemon) ---
        var currentPortPath = resolvePort(cliArgs.port)
        print("Paperlike 13K 2025 Color - macOS Init")
        print("Serial port: \(currentPortPath)")
        print(String(repeating: "=", count: 50))

        var port = openPortOrExit(currentPortPath)

        if !commands.isEmpty {
            for c in commands {
                _ = sendCommandVerbose(port, cmd: c.cmd, opt: c.opt, label: c.label)
            }
        }

        activateDisplay(port)

        if !cliArgs.daemon {
            print("TIP: Use --daemon to keep display active")
            port.closePort()
            return
        }

        // --- Daemon loop ---
        print("\nDaemon: refreshing every \(cliArgs.interval)s (Ctrl+C to stop)")
        installSignalHandlers()

        var tick = 0
        while !shouldExit {
            sleep(UInt32(cliArgs.interval))
            if shouldExit { break }
            tick += 1

            // Check if device file still exists (detects USB unplug)
            if !FileManager.default.fileExists(atPath: currentPortPath) {
                print("\n  Disconnected (device removed)")
                port.closePort()

                print("  Waiting for device...")
                var backoff: UInt32 = 1
                while !shouldExit {
                    if let newPath = SerialPort.findWCHPort() {
                        let newPort = SerialPort(path: newPath)
                        if newPort.openPort() {
                            _ = newPort.readAvailable()
                            port = newPort
                            currentPortPath = newPath
                            print("  Device back on \(newPath) - re-initializing...")
                            activateDisplay(port)
                            print("\nDaemon: resuming (Ctrl+C to stop)")
                            tick = 0
                            break
                        }
                    }
                    sleep(backoff)
                    backoff = min(backoff + 1, 15)
                }
                continue
            }

            _ = port.readAvailable()
            port.writeString(PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x01))
            usleep(100_000)

            print("\r  [\(timestamp())] tick \(tick)   ", terminator: "")
            fflush(stdout)
        }

        // Cleanup
        print("\n\nShutting down...")
        port.writeString(PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x00))
        usleep(100_000)
        print("  Sent deactivate")
        port.closePort()
    }
}
