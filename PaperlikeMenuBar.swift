import SwiftUI
import Foundation

@main
struct PaperlikeApp: App {
    @StateObject private var daemonManager = DaemonManager()

    var body: some Scene {
        MenuBarExtra("Paperlike", systemImage: "display") {
            ContentView(manager: daemonManager)
        }
        .menuBarExtraStyle(.window)
    }
}

class DaemonManager: ObservableObject {
    @Published var mode: Int = 3
    @Published var speed: Int = 5
    @Published var brightness: Int = 32
    @Published var frontLight: Int = 0

    private var daemonProcess: Process?

    init() {
        startDaemon()
    }

    func startDaemon() {
        let scriptPath = Bundle.main.path(forResource: "paperlike_init_macos", ofType: "py") ?? "/Users/maoyuankao/src/paperlike/paperlike13k_macos/paperlike_init_macos.py"
        RunCommand(args: ["python3", scriptPath, "--daemon"])
    }

    func updateSetting(flag: String, value: Int) {
        let scriptPath = Bundle.main.path(forResource: "paperlike_init_macos", ofType: "py") ?? "/Users/maoyuankao/src/paperlike/paperlike13k_macos/paperlike_init_macos.py"
        RunCommand(args: ["python3", scriptPath, flag, String(value)])
    }

    private func RunCommand(args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = args
            try? task.run()
        }
    }
}

struct ContentView: View {
    @ObservedObject var manager: DaemonManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paperlike Monitor")
                .font(.headline)

            HStack {
                Text("Mode:")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: Binding(
                    get: { manager.mode },
                    set: { newValue in
                        manager.mode = newValue
                        manager.updateSetting(flag: "--mode", value: newValue)
                    }
                )) {
                    Text("Fast").tag(1)
                    Text("Fast+").tag(2)
                    Text("Balance").tag(3)
                    Text("Text").tag(4)
                    Text("Text+").tag(5)
                    Text("Read").tag(6)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Level (Speed):")
                        .frame(width: 100, alignment: .leading)
                    Text("\(manager.speed)").monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(manager.speed) },
                    set: { newValue in
                        let intValue = Int(newValue)
                        if intValue != manager.speed {
                            manager.speed = intValue
                            manager.updateSetting(flag: "--speed", value: intValue)
                        }
                    }
                ), in: 1...8, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Front Light:")
                Picker("", selection: Binding(
                    get: { manager.frontLight },
                    set: { newValue in
                        manager.frontLight = newValue
                        manager.updateSetting(flag: "--front-light", value: newValue)
                    }
                )) {
                    Text("Off").tag(0)
                    Text("Warm").tag(1)
                    Text("Cold").tag(2)
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness:")
                        .frame(width: 80, alignment: .leading)
                    Text("\(manager.brightness)").monospacedDigit()
                }
                Slider(value: Binding(
                    get: { Double(manager.brightness) },
                    set: { newValue in
                        let intValue = Int(newValue)
                        if intValue != manager.brightness {
                            manager.brightness = intValue
                            manager.updateSetting(flag: "--brightness", value: intValue)
                        }
                    }
                ), in: 0...64, step: 1)
            }

            Divider()

            HStack {
                Button("Force Refresh") {
                    let scriptPath = Bundle.main.path(forResource: "paperlike_init_macos", ofType: "py") ?? "/Users/maoyuankao/src/paperlike/paperlike13k_macos/paperlike_init_macos.py"
                    DispatchQueue.global().async {
                        let task = Process()
                        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                        task.arguments = ["python3", scriptPath, "--refresh"]
                        try? task.run()
                    }
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 280)
    }
}
