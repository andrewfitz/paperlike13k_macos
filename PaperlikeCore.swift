import Foundation
import Swift
#if os(macOS)
import IOKit
import IOKit.serial
#endif

class SerialPort {
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
        
        // Prevent default echoing and special characters.
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
        
        // Timeout configuration
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 5 // VTIME (0.5 seconds timeout)
        
        if tcsetattr(fileDescriptor, TCSANOW, &options) == -1 {
            closePort()
            return false
        }
        
        // Clear DTR/RTS since Handshake is None (dsrdtr=False, rtscts=False)
        var status: Int32 = 0
        if ioctl(fileDescriptor, TIOCMGET, &status) != -1 {
            status &= ~TIOCM_DTR
            status &= ~TIOCM_RTS
            _ = ioctl(fileDescriptor, TIOCMSET, &status)
        }
        
        tcflush(fileDescriptor, TCIFLUSH)
        usleep(300_000) // 0.3s sleep as in python
        
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
            _ = write(fileDescriptor, buffer.baseAddress, buffer.count)
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
            // Sort to prefer cu.wchusbserial or cu.usbserial
            for item in items.sorted() {
                if item.hasPrefix("cu.usbserial") || item.hasPrefix("cu.wchusbserial") {
                    return "/dev/" + item
                }
            }
        }
        return nil
    }
}

// MARK: - Protocol Logic
struct PaperlikeProtocol {
    static func makePacket(cmd: UInt8, opt: UInt8) -> String {
        let cmdHex = String(format: "%02X", cmd)
        let optHex = String(format: "%02X", opt)
        return "5FF5\(cmdHex)\(optHex)000000000000A0FA"
    }
    
    // Command 0x20 Opt 0x01
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

// MARK: - Daemon Manager
class NativeDaemonManager: ObservableObject {
    @Published var mode: Int = 3
    @Published var speed: Int = 5
    @Published var brightness: Int = 32
    @Published var frontLight: Int = 0
    @Published var isConnected: Bool = false
    @Published var lastError: String = ""
    
    private var serialPort: SerialPort?
    private var timer: Timer?
    private var readBuffer: String = ""
    private let queue = DispatchQueue(label: "com.paperlike.serialQueue")
    
    init() {
        queue.async {
            self.connectAndInit()
        }
        startKeepAliveTimer()
    }
    
    private func connectAndInit() {
        if let portPath = SerialPort.findWCHPort() {
            let port = SerialPort(path: portPath)
            if port.openPort() {
                self.serialPort = port
                DispatchQueue.main.async {
                    self.isConnected = true
                    self.lastError = ""
                }
                
                print("Connected to \(portPath), draining...")
                _ = port.readAvailable()
                
                print("Activating display...")
                sendCommand(cmd: 0x20, opt: 0x01)
                
                // Give it some time to wake up after activation
                usleep(300_000)
                
                // Query current settings
                queryExistingSettings()
                return
            } else {
                let errString = String(cString: strerror(errno))
                DispatchQueue.main.async {
                    self.isConnected = false
                    self.lastError = "Failed to open port: \(errString)"
                }
            }
        } else {
            DispatchQueue.main.async {
                self.isConnected = false
                self.lastError = "No CH340 / USB serial port found"
            }
        }
    }
    
    private func startKeepAliveTimer() {
        // Ping every 10 seconds.
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.queue.async {
                if let port = self.serialPort, port.isOpen() {
                    _ = port.readAvailable()
                    self.sendCommand(cmd: 0x20, opt: 0x01)
                } else {
                    // Try to reconnect
                    self.connectAndInit()
                }
            }
        }
    }
    
    func updateMode(_ newValue: Int) {
        mode = newValue
        queue.async { self.sendCommand(cmd: 0x02, opt: UInt8(newValue)) }
    }
    
    func updateSpeed(_ newValue: Int) {
        speed = newValue
        queue.async { self.sendCommand(cmd: 0x01, opt: UInt8(newValue)) }
    }
    
    func updateBrightness(_ newValue: Int) {
        brightness = newValue
        queue.async { self.sendCommand(cmd: 0x09, opt: UInt8(newValue)) }
    }
    
    func updateFrontLight(_ newValue: Int) {
        frontLight = newValue
        queue.async { self.sendCommand(cmd: 0x07, opt: UInt8(newValue)) }
    }
    
    func forceRefresh() {
        queue.async { self.sendCommand(cmd: 0x03, opt: 0x01) }
    }
    
    private func sendCommand(cmd: UInt8, opt: UInt8) {
        guard let port = serialPort, port.isOpen() else { return }
        let packet = PaperlikeProtocol.makePacket(cmd: cmd, opt: opt)
        port.writeString(packet)
        // give it time to flush on native IO
        usleep(100_000)
    }
    
    private func queryExistingSettings() {
        print("Querying device configuration...")
        
        // Python script queries 0x10 and 0x13 first
        _ = sendQuerySync(opt: 0x10) // MCU version
        _ = sendQuerySync(opt: 0x13) // Display version
        
        // Mode
        if let val = sendQuerySync(opt: 0x02) {
            print("  - Mode: \(val)")
            DispatchQueue.main.async { self.mode = Int(val) }
        }
        // Speed
        if let val = sendQuerySync(opt: 0x01) {
            print("  - Speed: \(val)")
            DispatchQueue.main.async { self.speed = Int(val) }
        }
        // Brightness
        if let val = sendQuerySync(opt: 0x09) {
            print("  - Brightness: \(val)")
            DispatchQueue.main.async { self.brightness = Int(val) }
        }
        // Front Light
        if let val = sendQuerySync(opt: 0x07) {
            print("  - Front Light: \(val)")
            DispatchQueue.main.async { self.frontLight = Int(val) }
        }
    }
    
    private func sendQuerySync(opt: UInt8) -> UInt8? {
        guard let port = serialPort, port.isOpen() else { return nil }
        let packet = PaperlikeProtocol.makePacket(cmd: 0x0A, opt: opt)
        print("  TX Query [\(String(format: "%02X", opt))]: \(packet)")
        port.writeString(packet)
        
        // Clear local buffer for this sync query to avoid stale responses
        self.readBuffer = ""
        
        // Wait up to 1.5s for response (30 * 50ms)
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
                        // Response for query 0x0A is cmd 0xF0.
                        // The device might not echo the 'opt' byte, so we accept any 0xF0 here
                        // as long as we just sent a query.
                        if p.payload.count >= 4 {
                            let start = p.payload.index(p.payload.startIndex, offsetBy: 2)
                            let end = p.payload.index(p.payload.startIndex, offsetBy: 4)
                            if let val = UInt8(p.payload[start..<end], radix: 16) {
                                // Reset buffer after finding our target
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
    
    deinit {
        timer?.invalidate()
        if let port = serialPort {
            sendCommand(cmd: 0x20, opt: 0x00) // Deactivate
            port.closePort()
        }
    }
}
