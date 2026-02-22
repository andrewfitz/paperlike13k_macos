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
    
    deinit {
        timer?.invalidate()
        if let port = serialPort {
            sendCommand(cmd: 0x20, opt: 0x00) // Deactivate
            port.closePort()
        }
    }
}
