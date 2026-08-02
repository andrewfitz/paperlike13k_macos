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
    var diagnose = false
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
      --diagnose            Debug USB connection stability (high-freq monitoring)
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
        case "--diagnose":
            args.diagnose = true
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

func timestampMs() -> String {
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    return df.string(from: Date())
}

// MARK: - Diagnostic Mode

struct DisconnectEvent {
    let timestamp: Date
    let reconnectedAt: Date?
    let type: String          // "USB_REMOVED", "SERIAL_ERROR", "HEARTBEAT_TIMEOUT"
    let oldPort: String
    let newPort: String?

    var durationMs: Int? {
        guard let r = reconnectedAt else { return nil }
        return Int(r.timeIntervalSince(timestamp) * 1000)
    }
}

func runDiagnostic(specifiedPort: String?) {
    print("=== Paperlike USB Connection Diagnostic ===")
    print("Started: \(timestampMs())")
    print("Polling interval: 200ms (device presence) / 5s (heartbeat)")
    print("Press Ctrl+C to stop and see summary\n")

    installSignalHandlers()

    // Start system log watcher for USB events
    let logProcess = Process()
    let logPipe = Pipe()
    logProcess.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    logProcess.arguments = [
        "stream", "--style", "compact",
        "--predicate",
        "subsystem == \"com.apple.usb\" OR eventMessage CONTAINS[c] \"IOUSBHost\" OR eventMessage CONTAINS[c] \"CH34\" OR eventMessage CONTAINS[c] \"usbserial\""
    ]
    logProcess.standardOutput = logPipe
    logProcess.standardError = FileHandle.nullDevice

    // Collect system log lines in background
    nonisolated(unsafe) var sysLogLines: [String] = []
    let sysLogLock = NSLock()
    logPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
        for line in str.components(separatedBy: .newlines) where !line.isEmpty {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            sysLogLock.lock()
            sysLogLines.append(trimmed)
            sysLogLock.unlock()
            print("  [\(timestampMs())] SYSLOG: \(trimmed)")
            fflush(stdout)
        }
    }
    try? logProcess.run()

    // Find initial port
    var currentPortPath = specifiedPort ?? SerialPort.findWCHPort()
    if currentPortPath == nil {
        print("[\(timestampMs())] NO DEVICE - waiting for USB serial device...")
        while !shouldExit {
            usleep(200_000)
            if let p = SerialPort.findWCHPort() {
                currentPortPath = p
                print("[\(timestampMs())] DEVICE FOUND: \(p)")
                break
            }
        }
    }
    guard let startPort = currentPortPath, !shouldExit else {
        printDiagSummary([], Date()); return
    }
    _ = startPort // used to seed currentPortPath

    print("[\(timestampMs())] DEVICE: \(currentPortPath!)")

    // List all serial devices for context
    let fm = FileManager.default
    if let items = try? fm.contentsOfDirectory(atPath: "/dev") {
        let serialDevs = items.filter { $0.hasPrefix("cu.usb") || $0.hasPrefix("cu.wch") }.sorted()
        if !serialDevs.isEmpty {
            print("[\(timestampMs())] ALL SERIAL DEVICES: \(serialDevs.map { "/dev/\($0)" }.joined(separator: ", "))")
        }
    }

    // Open port
    var port = SerialPort(path: currentPortPath!)
    guard port.openPort() else {
        print("[\(timestampMs())] OPEN FAILED: \(String(cString: strerror(errno)))")
        printDiagSummary([], Date()); return
    }
    _ = port.readAvailable()
    print("[\(timestampMs())] PORT OPENED: \(currentPortPath!)")

    // Activate
    port.writeString(PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x01))
    usleep(200_000)
    let initResp = port.readAvailable()
    if !initResp.isEmpty {
        let pkts = PaperlikeProtocol.parsePackets(initResp)
        for p in pkts {
            print("[\(timestampMs())] INIT RESPONSE: cmd=0x\(hex(p.cmd)) opt=0x\(hex(p.opt)) payload=\(p.payload)")
        }
    }
    print("[\(timestampMs())] ACTIVATED - beginning monitoring\n")

    let sessionStart = Date()
    var events: [DisconnectEvent] = []
    var lastHeartbeatSent = Date()
    var lastHeartbeatOk: Date? = nil
    var heartbeatsSent = 0
    var heartbeatsOk = 0
    var heartbeatsFailed = 0
    // var serialErrors = 0  // reserved for future write-error tracking
    var isConnected = true
    var disconnectedAt: Date? = nil
    var disconnectType = ""
    var disconnectPort = ""
    var consecutiveReadFailures = 0
    let heartbeatInterval: TimeInterval = 5.0
    let pollInterval: UInt32 = 200_000 // 200ms

    while !shouldExit {
        usleep(pollInterval)
        let now = Date()

        if isConnected {
            // Check 1: Does the device file still exist?
            let deviceExists = fm.fileExists(atPath: currentPortPath!)
            if !deviceExists {
                isConnected = false
                disconnectedAt = now
                disconnectType = "USB_REMOVED"
                disconnectPort = currentPortPath!
                print("[\(timestampMs())] *** USB DISCONNECT *** device file gone: \(currentPortPath!)")
                print("[\(timestampMs())]   Type: USB/physical - device removed from /dev")
                print("[\(timestampMs())]   Likely cause: USB link reset, cable issue, or power interruption")
                port.closePort()

                // Dump any new syslog lines
                sysLogLock.lock()
                let recentLogs = sysLogLines.suffix(5)
                sysLogLock.unlock()
                if !recentLogs.isEmpty {
                    print("[\(timestampMs())]   Recent USB system messages:")
                    for l in recentLogs {
                        print("[\(timestampMs())]     \(l)")
                    }
                }
                continue
            }

            // Check 2: Try reading any available data
            let data = port.readAvailable()
            if !data.isEmpty {
                consecutiveReadFailures = 0
                let pkts = PaperlikeProtocol.parsePackets(data)
                for p in pkts {
                    if p.cmd == 0xF5 {
                        lastHeartbeatOk = now
                        heartbeatsOk += 1
                    } else {
                        print("[\(timestampMs())] RX: cmd=0x\(hex(p.cmd)) opt=0x\(hex(p.opt)) payload=\(p.payload)")
                    }
                }
            }

            // Check 3: Periodic heartbeat/keepalive probe
            if now.timeIntervalSince(lastHeartbeatSent) >= heartbeatInterval {
                heartbeatsSent += 1
                lastHeartbeatSent = now

                let packet = PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x01)
                port.writeString(packet)
                usleep(150_000) // wait for response

                let resp = port.readAvailable()
                if resp.isEmpty {
                    consecutiveReadFailures += 1
                    let elapsed = lastHeartbeatOk.map { String(format: "%.1fs ago", now.timeIntervalSince($0)) } ?? "never"
                    print("[\(timestampMs())] HEARTBEAT: no response (last ok: \(elapsed), consecutive fails: \(consecutiveReadFailures))")

                    if consecutiveReadFailures >= 3 {
                        heartbeatsFailed += 1
                        isConnected = false
                        disconnectedAt = now
                        disconnectType = "HEARTBEAT_TIMEOUT"
                        disconnectPort = currentPortPath!
                        print("[\(timestampMs())] *** SERIAL DISCONNECT *** 3 consecutive heartbeat failures")
                        print("[\(timestampMs())]   Type: Data/firmware - USB device present but MCU unresponsive")
                        print("[\(timestampMs())]   Likely cause: MCU hang, serial buffer overflow, or data corruption")
                        port.closePort()
                    }
                } else {
                    consecutiveReadFailures = 0
                    let pkts = PaperlikeProtocol.parsePackets(resp)
                    let hasResponse = pkts.contains { $0.cmd == 0xF5 || $0.cmd == 0xF0 }
                    if hasResponse {
                        lastHeartbeatOk = now
                        heartbeatsOk += 1
                        let df = DateFormatter()
                        df.dateFormat = "HH:mm:ss"
                        print("\r[\(df.string(from: now))] heartbeat ok (\(heartbeatsOk)/\(heartbeatsSent))   ", terminator: "")
                        fflush(stdout)
                    } else {
                        print("[\(timestampMs())] HEARTBEAT: unexpected response: \(resp.prefix(48))")
                    }
                }
            }
        } else {
            // Disconnected - scan for device
            if let newPath = SerialPort.findWCHPort() {
                let newPort = SerialPort(path: newPath)
                if newPort.openPort() {
                    let reconnectedAt = Date()
                    let duration = disconnectedAt.map { Int(reconnectedAt.timeIntervalSince($0) * 1000) } ?? 0
                    _ = newPort.readAvailable()

                    print("")
                    print("[\(timestampMs())] *** RECONNECTED *** \(newPath) (offline \(duration)ms)")
                    if newPath != disconnectPort {
                        print("[\(timestampMs())]   Port changed: \(disconnectPort) -> \(newPath)")
                    }

                    // Re-activate
                    newPort.writeString(PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x01))
                    usleep(200_000)
                    let resp = newPort.readAvailable()
                    if !resp.isEmpty {
                        print("[\(timestampMs())]   Re-activation response received")
                    }

                    let event = DisconnectEvent(
                        timestamp: disconnectedAt ?? reconnectedAt,
                        reconnectedAt: reconnectedAt,
                        type: disconnectType,
                        oldPort: disconnectPort,
                        newPort: newPath != disconnectPort ? newPath : nil
                    )
                    events.append(event)

                    port = newPort
                    currentPortPath = newPath
                    isConnected = true
                    consecutiveReadFailures = 0
                    lastHeartbeatSent = reconnectedAt
                    print("[\(timestampMs())]   Monitoring resumed\n")
                }
            }
        }
    }

    // Cleanup
    print("\n")
    if isConnected {
        port.writeString(PaperlikeProtocol.makePacket(cmd: 0x20, opt: 0x00))
        usleep(100_000)
        port.closePort()
    }
    logProcess.terminate()
    logPipe.fileHandleForReading.readabilityHandler = nil

    // If currently disconnected, record it
    if !isConnected, let disc = disconnectedAt {
        events.append(DisconnectEvent(
            timestamp: disc, reconnectedAt: nil, type: disconnectType,
            oldPort: disconnectPort, newPort: nil
        ))
    }

    printDiagSummary(events, sessionStart)
}

func printDiagSummary(_ events: [DisconnectEvent], _ sessionStart: Date) {
    let duration = Date().timeIntervalSince(sessionStart)
    let mins = Int(duration) / 60
    let secs = Int(duration) % 60

    print("=== Diagnostic Summary ===")
    print("  Session duration: \(mins)m \(secs)s")
    print("  Total disconnects: \(events.count)")

    if events.isEmpty {
        print("  No disconnects detected during this session.")
        return
    }

    let usbRemoved = events.filter { $0.type == "USB_REMOVED" }
    let heartbeatTimeout = events.filter { $0.type == "HEARTBEAT_TIMEOUT" }
    let serialError = events.filter { $0.type == "SERIAL_ERROR" }

    print("  By type:")
    if !usbRemoved.isEmpty {
        print("    USB/physical disconnects: \(usbRemoved.count)  (device vanished from /dev)")
    }
    if !heartbeatTimeout.isEmpty {
        print("    Heartbeat timeouts:       \(heartbeatTimeout.count)  (device present, MCU unresponsive)")
    }
    if !serialError.isEmpty {
        print("    Serial I/O errors:        \(serialError.count)  (read/write failures)")
    }

    let durations = events.compactMap { $0.durationMs }
    if !durations.isEmpty {
        let avg = durations.reduce(0, +) / durations.count
        let maxD = durations.max()!
        let minD = durations.min()!
        print("  Disconnect durations:")
        print("    Shortest: \(minD)ms")
        print("    Longest:  \(maxD)ms")
        print("    Average:  \(avg)ms")
    }

    let portChanged = events.filter { $0.newPort != nil }
    if !portChanged.isEmpty {
        print("  Port path changed \(portChanged.count) time(s) (USB re-enumeration)")
    }

    print("\n  Event log:")
    let df = DateFormatter()
    df.dateFormat = "HH:mm:ss.SSS"
    for (i, e) in events.enumerated() {
        let dur = e.durationMs.map { "\($0)ms" } ?? "ongoing"
        let portInfo = e.newPort.map { " -> \($0)" } ?? ""
        print("    #\(i+1) [\(df.string(from: e.timestamp))] \(e.type) \(e.oldPort)\(portInfo) (\(dur))")
    }

    print("\n  Interpretation:")
    if !usbRemoved.isEmpty && heartbeatTimeout.isEmpty {
        print("    All disconnects are USB-level (device removal from /dev).")
        print("    This points to a physical/power issue:")
        print("      - USB-C cable or connector making intermittent contact")
        print("      - USB hub or dock power management")
        print("      - macOS USB power saving (check System Settings > Energy)")
        print("      - Insufficient USB bus power under load")
        if let avg = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count {
            if avg < 500 {
                print("    Sub-500ms reconnects suggest a brief USB link reset,")
                print("    likely a power glitch or signal integrity issue on the cable.")
            }
        }
    } else if usbRemoved.isEmpty && !heartbeatTimeout.isEmpty {
        print("    All disconnects are heartbeat timeouts (MCU unresponsive).")
        print("    The USB link stayed up but the display MCU stopped responding.")
        print("    This points to a firmware/data issue:")
        print("      - MCU firmware hang or watchdog reset")
        print("      - Serial buffer overflow")
        print("      - EMI/noise corrupting serial data")
    } else if !usbRemoved.isEmpty && !heartbeatTimeout.isEmpty {
        print("    Mixed disconnect types detected.")
        print("    Both USB-level and MCU-level issues are occurring.")
        print("    Try isolating: use a different USB-C cable/port first,")
        print("    then check if heartbeat timeouts persist alone.")
    }
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

        // --- Diagnose mode ---
        if cliArgs.diagnose {
            runDiagnostic(specifiedPort: cliArgs.port)
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
