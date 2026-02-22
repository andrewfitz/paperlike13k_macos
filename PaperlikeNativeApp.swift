import SwiftUI

@main
struct PaperlikeNativeApp: App {
    @StateObject private var daemonManager = NativeDaemonManager()

    var body: some Scene {
        MenuBarExtra("Paperlike", systemImage: "display") {
            ContentView(manager: daemonManager)
        }
        .menuBarExtraStyle(.window)
    }
}

struct ContentView: View {
    @ObservedObject var manager: NativeDaemonManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Paperlike Native Monitor")
                        .font(.headline)
                    Spacer()
                    Circle()
                        .fill(manager.isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                }
                if !manager.lastError.isEmpty {
                    Text(manager.lastError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                Text("Port: \(manager.activePort)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Mode:")
                    .frame(width: 80, alignment: .leading)
                Picker("", selection: Binding(
                    get: { manager.mode },
                    set: { manager.updateMode($0) }
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
                    set: { manager.updateSpeed(Int($0)) }
                ), in: 1...8, step: 1)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Front Light:")
                Picker("", selection: Binding(
                    get: { manager.frontLight },
                    set: { manager.updateFrontLight($0) }
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
                    set: { manager.updateBrightness(Int($0)) }
                ), in: 0...64, step: 1)
            }

            Divider()

            HStack {
                Button("Force Refresh") {
                    manager.forceRefresh()
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
