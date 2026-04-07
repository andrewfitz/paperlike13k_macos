import Foundation
import Swift
#if os(macOS)
import IOKit
import IOKit.serial
#endif

// MARK: - Serial Port (low-level POSIX I/O)
final class SerialPort: @unchecked Sendable {
    private var fileDescriptor: Int32 = -1
    let path: String

    init(path: String) {
        self.path = path
    }

    deinit {
        closePort()
    }

    func openPort() -> Bool {
        fileDescriptor = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fileDescriptor != -1 else { return false }

        var options = termios()
        if tcgetattr(fileDescriptor, &options) == -1 {
            closePort()
            return false
        }

        cfmakeraw(&options)

        options.c_cflag |= UInt(CS8)
        options.c_cflag &= ~UInt(PARENB)
        options.c_cflag &= ~UInt(CSTOPB)
        options.c_cflag &= ~UInt(CRTSCTS)
        options.c_cflag |= UInt(CREAD | CLOCAL)

        let speed = speed_t(B115200)
        cfsetspeed(&options, speed)

        withUnsafeMutablePointer(to: &options.c_cc) {
            $0.withMemoryRebound(to: cc_t.self, capacity: Int(NCCS)) { ptr in
                ptr[Int(VMIN)] = 0
                ptr[Int(VTIME)] = 5 // 0.5 seconds timeout
            }
        }

        if tcsetattr(fileDescriptor, TCSANOW, &options) == -1 {
            closePort()
            return false
        }

        var status: Int32 = 0
        if ioctl(fileDescriptor, TIOCMGET, &status) != -1 {
            status &= ~TIOCM_DTR
            status &= ~TIOCM_RTS
            _ = ioctl(fileDescriptor, TIOCMSET, &status)
        }

        tcflush(fileDescriptor, TCIFLUSH)
        usleep(300_000)

        return true
    }

    func closePort() {
        if fileDescriptor != -1 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    func writeString(_ string: String) {
        guard fileDescriptor != -1 else { return }
        let data = Array(string.utf8)
        data.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var totalWritten = 0
            while totalWritten < buffer.count {
                let written = write(fileDescriptor, baseAddress + totalWritten, buffer.count - totalWritten)
                if written < 0 { return }
                totalWritten += written
            }
        }
    }

    func readAvailable() -> String {
        guard fileDescriptor != -1 else { return "" }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let bytesRead = read(fileDescriptor, &buffer, buffer.count)
        if bytesRead > 0 {
            return String(bytes: buffer[0..<Int(bytesRead)], encoding: .ascii) ?? ""
        }
        return ""
    }

    func isOpen() -> Bool {
        return fileDescriptor != -1
    }

    static func findWCHPort() -> String? {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(atPath: "/dev") {
            for item in items.sorted() {
                if item.hasPrefix("cu.usbserial") || item.hasPrefix("cu.wchusbserial") {
                    return "/dev/" + item
                }
            }
        }
        return nil
    }
}

// MARK: - Display Driver
private enum DisplayLocation {
    case all
    case embedded
    case external
}

enum DisplayDriverInitializer {
    static func applyInitOverrides() {
        setProperties(["enableDither": kCFBooleanFalse], target: .all)
        setProperties(["uniformity2D": kCFBooleanFalse], target: .embedded)
    }

    private static func setProperties(_ props: [String: CFTypeRef], target: DisplayLocation) {
        var iterator = io_iterator_t()
        defer { IOObjectRelease(iterator) }

        let ret = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferAP"), &iterator)
        guard ret == KERN_SUCCESS, iterator != IO_OBJECT_NULL else { return }

        while true {
            let service = IOIteratorNext(iterator)
            if service == IO_OBJECT_NULL { break }
            defer { IOObjectRelease(service) }

            let externalValue = IORegistryEntryCreateCFProperty(service, "external" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            let isExternal = (externalValue as? Bool) ?? false

            if isExternal && target == .embedded { continue }
            if !isExternal && target == .external { continue }

            for (key, value) in props {
                _ = IORegistryEntrySetCFProperty(service, key as CFString, value)
            }
        }
    }
}

// MARK: - Protocol Logic
struct PaperlikeProtocol: Sendable {
    static func makePacket(cmd: UInt8, opt: UInt8) -> String {
        let cmdHex = String(format: "%02X", cmd)
        let optHex = String(format: "%02X", opt)
        return "5FF5\(cmdHex)\(optHex)000000000000A0FA"
    }

    static var activateDisplayCommand: String {
        return makePacket(cmd: 0x20, opt: 0x01)
    }

    static func parsePackets(_ data: String) -> [(cmd: UInt8, opt: UInt8, payload: String)] {
        var results: [(cmd: UInt8, opt: UInt8, payload: String)] = []
        let text = data.uppercased()
        var searchPos = text.startIndex

        while let range = text.range(of: "5FF5", options: [], range: searchPos..<text.endIndex) {
            let start = range.lowerBound
            if let end = text.index(start, offsetBy: 24, limitedBy: text.endIndex) {
                let pkt = String(text[start..<end])
                if pkt.hasSuffix("A0FA") {
                    let cmdStart = pkt.index(pkt.startIndex, offsetBy: 4)
                    let cmdEnd = pkt.index(pkt.startIndex, offsetBy: 6)
                    let optStart = pkt.index(pkt.startIndex, offsetBy: 6)
                    let optEnd = pkt.index(pkt.startIndex, offsetBy: 8)
                    let payloadStart = pkt.index(pkt.startIndex, offsetBy: 8)
                    let payloadEnd = pkt.index(pkt.startIndex, offsetBy: 20)

                    if let cmd = UInt8(pkt[cmdStart..<cmdEnd], radix: 16),
                       let opt = UInt8(pkt[optStart..<optEnd], radix: 16) {
                        let payload = String(pkt[payloadStart..<payloadEnd])
                        results.append((cmd, opt, payload))
                        searchPos = end
                        continue
                    }
                }
            }
            searchPos = text.index(after: range.lowerBound)
        }
        return results
    }
}

// MARK: - Data Types
struct DeviceSettings: Sendable {
    var mode: Int?
    var speed: Int?
    var brightness: Int?
    var frontLight: Int?
}

struct ConnectionResult: Sendable {
    let connected: Bool
    let error: String
    let settings: DeviceSettings?
}

// MARK: - Serial Worker (thread-safe, owns all serial I/O)
final class SerialWorker: @unchecked Sendable {
    private var serialPort: SerialPort?
    private var readBuffer: String = ""
    private let queue = DispatchQueue(label: "com.paperlike.serialQueue")

    func connectAndInit() -> ConnectionResult {
        return queue.sync {
            guard let portPath = SerialPort.findWCHPort() else {
                return ConnectionResult(connected: false, error: "No CH340 / USB serial port found", settings: nil)
            }
            let port = SerialPort(path: portPath)
            guard port.openPort() else {
                let errString = String(cString: strerror(errno))
                return ConnectionResult(connected: false, error: "Failed to open port: \(errString)", settings: nil)
            }
            self.serialPort = port

            print("Connected to \(portPath), draining...")
            _ = port.readAvailable()

            print("Activating display...")
            self.sendCommandInternal(cmd: 0x20, opt: 0x01)
            usleep(300_000)

            let settings = self.queryExistingSettings()
            return ConnectionResult(connected: true, error: "", settings: settings)
        }
    }

    func sendCommand(cmd: UInt8, opt: UInt8) {
        queue.async {
            self.sendCommandInternal(cmd: cmd, opt: opt)
        }
    }

    func keepAlive() -> Bool {
        return queue.sync {
            if let port = self.serialPort, port.isOpen() {
                _ = port.readAvailable()
                self.sendCommandInternal(cmd: 0x20, opt: 0x01)
                return true
            }
            return false
        }
    }

    func shutdown() {
        queue.sync {
            if let port = self.serialPort, port.isOpen() {
                self.sendCommandInternal(cmd: 0x20, opt: 0x00)
                port.closePort()
            }
            self.serialPort = nil
        }
    }

    // MARK: Internal (must be called on queue)

    private func sendCommandInternal(cmd: UInt8, opt: UInt8) {
        guard let port = serialPort, port.isOpen() else { return }
        let packet = PaperlikeProtocol.makePacket(cmd: cmd, opt: opt)
        port.writeString(packet)
        usleep(100_000)
    }

    private func queryExistingSettings() -> DeviceSettings {
        print("Querying device configuration...")
        _ = sendQuerySync(opt: 0x10) // MCU version
        _ = sendQuerySync(opt: 0x13) // Display version

        var settings = DeviceSettings()
        if let val = sendQuerySync(opt: 0x02) {
            print("  - Mode: \(val)")
            settings.mode = Int(val)
        }
        if let val = sendQuerySync(opt: 0x01) {
            print("  - Speed: \(val)")
            settings.speed = Int(val)
        }
        if let val = sendQuerySync(opt: 0x09) {
            print("  - Brightness: \(val)")
            settings.brightness = Int(val)
        }
        if let val = sendQuerySync(opt: 0x07) {
            print("  - Front Light: \(val)")
            settings.frontLight = Int(val)
        }
        return settings
    }

    private func sendQuerySync(opt: UInt8) -> UInt8? {
        guard let port = serialPort, port.isOpen() else { return nil }
        let packet = PaperlikeProtocol.makePacket(cmd: 0x0A, opt: opt)
        print("  TX Query [\(String(format: "%02X", opt))]: \(packet)")
        port.writeString(packet)

        self.readBuffer = ""

        for i in 0..<30 {
            usleep(50_000)
            let incoming = port.readAvailable()
            if !incoming.isEmpty {
                self.readBuffer += incoming
                print("  RX Raw [\(i)]: \(incoming)")

                let packets = PaperlikeProtocol.parsePackets(self.readBuffer)
                for p in packets {
                    print("  Parsed packet: cmd=\(String(format: "%02X", p.cmd)), opt=\(String(format: "%02X", p.opt)), payload=\(p.payload)")

                    if p.cmd == 0xF0 {
                        if p.payload.count >= 4 {
                            let start = p.payload.index(p.payload.startIndex, offsetBy: 2)
                            let end = p.payload.index(p.payload.startIndex, offsetBy: 4)
                            if let val = UInt8(p.payload[start..<end], radix: 16) {
                                self.readBuffer = ""
                                return val
                            }
                        }
                    }
                }
            }
        }
        print("  Query timeout for opt \(String(format: "%02X", opt))")
        return nil
    }
}
