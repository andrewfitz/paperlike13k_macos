import Foundation
import Combine

// MARK: - Daemon Manager (MainActor, drives SwiftUI)
@MainActor
class NativeDaemonManager: ObservableObject {
    @Published var mode: Int = 3
    @Published var speed: Int = 5
    @Published var brightness: Int = 32
    @Published var frontLight: Int = 0
    @Published var isConnected: Bool = false
    @Published var lastError: String = ""
    @Published var autoRefreshEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(autoRefreshEnabled, forKey: "autoRefreshEnabled")
            restartAutoRefresh()
        }
    }
    @Published var autoRefreshMinutes: Int = 5 {
        didSet {
            UserDefaults.standard.set(autoRefreshMinutes, forKey: "autoRefreshMinutes")
            restartAutoRefresh()
        }
    }

    let worker = SerialWorker()
    private var keepAliveTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?
    private let modeDefaultsKey = "paperlikeMode"

    init() {
        if UserDefaults.standard.object(forKey: modeDefaultsKey) != nil {
            mode = UserDefaults.standard.integer(forKey: modeDefaultsKey)
        }
        if UserDefaults.standard.object(forKey: "autoRefreshMinutes") != nil {
            autoRefreshMinutes = UserDefaults.standard.integer(forKey: "autoRefreshMinutes")
        }
        autoRefreshEnabled = UserDefaults.standard.bool(forKey: "autoRefreshEnabled")

        let worker = self.worker
        let modeKey = self.modeDefaultsKey
        Task {
            let result = await Task.detached { worker.connectAndInit() }.value
            self.applyConnectionResult(result, modeKey: modeKey)
        }
        startKeepAlive()
        restartAutoRefresh()
    }

    private func applyConnectionResult(_ result: ConnectionResult, modeKey: String) {
        self.isConnected = result.connected
        self.lastError = result.error
        if let settings = result.settings {
            if let m = settings.mode {
                self.mode = m
                UserDefaults.standard.set(m, forKey: modeKey)
            }
            if let s = settings.speed { self.speed = s }
            if let b = settings.brightness { self.brightness = b }
            if let f = settings.frontLight { self.frontLight = f }
        }
    }

    private func startKeepAlive() {
        let worker = self.worker
        keepAliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                let result: ConnectionResult? = await Task.detached {
                    if worker.keepAlive() {
                        return nil
                    } else {
                        return worker.connectAndInit()
                    }
                }.value
                if let result {
                    self.isConnected = result.connected
                    self.lastError = result.error
                }
            }
        }
    }

    func updateMode(_ newValue: Int) {
        mode = newValue
        UserDefaults.standard.set(newValue, forKey: modeDefaultsKey)
        worker.sendCommand(cmd: 0x02, opt: UInt8(newValue))
    }

    func updateSpeed(_ newValue: Int) {
        speed = newValue
        worker.sendCommand(cmd: 0x01, opt: UInt8(newValue))
    }

    func updateBrightness(_ newValue: Int) {
        brightness = newValue
        worker.sendCommand(cmd: 0x09, opt: UInt8(newValue))
    }

    func updateFrontLight(_ newValue: Int) {
        frontLight = newValue
        worker.sendCommand(cmd: 0x07, opt: UInt8(newValue))
    }

    func forceRefresh() {
        worker.sendCommand(cmd: 0x03, opt: 0x01)
    }

    private func restartAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefreshEnabled, autoRefreshMinutes > 0 else { return }
        let worker = self.worker
        let minutes = self.autoRefreshMinutes
        autoRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(minutes * 60))
                if Task.isCancelled { break }
                worker.sendCommand(cmd: 0x03, opt: 0x01)
            }
        }
    }

    func shutdown() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        worker.shutdown()
    }
}
