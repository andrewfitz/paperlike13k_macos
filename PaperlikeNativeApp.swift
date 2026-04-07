import SwiftUI
import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var daemonManager = NativeDaemonManager()
    var shortcutManager = GlobalShortcutManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        DisplayDriverInitializer.applyInitOverrides()
        let worker = daemonManager.worker
        shortcutManager.onTriggerForceRefresh = {
            worker.sendCommand(cmd: 0x03, opt: 0x01)
        }
        print("App finished launching, managers initialized.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemonManager.shutdown()
    }
}

@main
struct PaperlikeNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Paperlike", systemImage: "display") {
            ContentView(manager: appDelegate.daemonManager, shortcutManager: appDelegate.shortcutManager)
        }
        .menuBarExtraStyle(.window)
    }
}

// Custom Window Manager for Settings
@MainActor
class SettingsWindowManager {
    static let shared = SettingsWindowManager()
    private var window: NSWindow?

    func showWindow(shortcutManager: GlobalShortcutManager) {
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsView(shortcutManager: shortcutManager))
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 450, height: 200),
                               styleMask: [.titled, .closable],
                               backing: .buffered,
                               defer: false)
            win.center()
            win.title = "Paperlike Settings"
            win.contentViewController = hostingController
            win.isReleasedWhenClosed = false
            self.window = win
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// Global Shortcut Manager using Carbon
@MainActor
class GlobalShortcutManager: ObservableObject {
    @Published var refreshKeyCode: UInt16?
    @Published var refreshModifiers: NSEvent.ModifierFlags?
    var onTriggerForceRefresh: (@Sendable () -> Void)? {
        didSet { setupCarbonHotkey() }
    }

    init() {
        loadShortcut()
        setupCarbonHotkey()
    }

    nonisolated deinit {
        CarbonHotkeyManager.shared.unregister()
    }

    func saveShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.refreshKeyCode = keyCode
        self.refreshModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "refreshKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "refreshModifiers")
        setupCarbonHotkey()
    }

    func clearShortcut() {
        self.refreshKeyCode = nil
        self.refreshModifiers = nil
        UserDefaults.standard.removeObject(forKey: "refreshKeyCode")
        UserDefaults.standard.removeObject(forKey: "refreshModifiers")
        CarbonHotkeyManager.shared.unregister()
    }

    private func loadShortcut() {
        if UserDefaults.standard.object(forKey: "refreshKeyCode") != nil {
            self.refreshKeyCode = UInt16(UserDefaults.standard.integer(forKey: "refreshKeyCode"))
            self.refreshModifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "refreshModifiers")))
        }
    }

    private func setupCarbonHotkey() {
        guard let code = refreshKeyCode, let mods = refreshModifiers else { return }
        let callback = self.onTriggerForceRefresh
        CarbonHotkeyManager.shared.register(keyCode: code, modifiers: mods) {
            if let callback = callback {
                callback()
            } else {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("TriggerForceRefresh"), object: nil)
                }
            }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var shortcutManager: GlobalShortcutManager
    @State private var isRecording = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Refresh Shortcut:")
                    Spacer()
                    Button(action: {
                        isRecording = true
                    }) {
                        if isRecording {
                            Text("Type Shortcut...")
                                .foregroundColor(.red)
                        } else {
                            Text(shortcutText())
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(4)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)

                    if shortcutManager.refreshKeyCode != nil {
                        Button(action: {
                            shortcutManager.clearShortcut()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }
            Text("Note: Global shortcuts NO LONGER require Accessibility permissions.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 400, height: 150)
        .background(
            KeyEventHandlingView(isRecording: $isRecording, shortcutManager: shortcutManager)
                .frame(width: 0, height: 0)
        )
    }

    private func shortcutText() -> String {
        guard let mods = shortcutManager.refreshModifiers, let code = shortcutManager.refreshKeyCode else {
            return "Click to Record"
        }

        var text = ""
        if mods.contains(.control) { text += "\u{2303}" }
        if mods.contains(.option) { text += "\u{2325}" }
        if mods.contains(.shift) { text += "\u{21E7}" }
        if mods.contains(.command) { text += "\u{2318}" }

        text += String(format: "[Key %d]", code)
        return text
    }
}

// Invisible NSViewRepresentable to capture key events when recording
struct KeyEventHandlingView: NSViewRepresentable {
    @Binding var isRecording: Bool
    var shortcutManager: GlobalShortcutManager

    func makeNSView(context: Context) -> CustomKeyView {
        let view = CustomKeyView()
        view.onKeyDown = { event in
            if isRecording {
                let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
                if !modifiers.isEmpty {
                    shortcutManager.saveShortcut(keyCode: event.keyCode, modifiers: modifiers)
                    isRecording = false
                    return true
                }
            }
            return false
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CustomKeyView, context: Context) {
        if isRecording {
            DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
        }
    }
}

class CustomKeyView: NSView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let handler = onKeyDown, handler(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct ContentView: View {
    @ObservedObject var manager: NativeDaemonManager
    @ObservedObject var shortcutManager: GlobalShortcutManager
    @State private var localSpeed: Double = 5
    @State private var localBrightness: Double = 32
    private let modeOptions: [(value: Int, title: String)] = [
        (1, "Web"),
        (2, "Text"),
        (3, "Image"),
        (4, "Active"),
        (5, "Heavy")
    ]

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
            }

            HStack(spacing: 6) {
                ForEach(modeOptions, id: \.value) { modeOption in
                    Button(modeOption.title) {
                        manager.updateMode(modeOption.value)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(manager.mode == modeOption.value ? Color.accentColor : Color.secondary.opacity(0.2))
                    .foregroundColor(manager.mode == modeOption.value ? .white : .primary)
                    .cornerRadius(6)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Darkness:")
                        .frame(width: 100, alignment: .leading)
                    Text("\(Int(localSpeed))").monospacedDigit()
                }
                Slider(value: $localSpeed, in: 1...8, step: 1) { editing in
                    if !editing {
                        manager.updateSpeed(Int(localSpeed))
                    }
                }
                .onChange(of: manager.speed) { _, newValue in
                    localSpeed = Double(newValue)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Front Light:")
                Picker("", selection: Binding(
                    get: { manager.frontLight },
                    set: { manager.updateFrontLight($0) }
                )) {
                    Text("Off").tag(0)
                    Text("Cold").tag(1)
                    Text("Warm").tag(2)
                    Text("Both").tag(3)
                }
                .pickerStyle(SegmentedPickerStyle())
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness:")
                        .frame(width: 80, alignment: .leading)
                    Text("\(Int(localBrightness))").monospacedDigit()
                }
                Slider(value: $localBrightness, in: 0...64, step: 1) { editing in
                    if !editing {
                        manager.updateBrightness(Int(localBrightness))
                    }
                }
                .onChange(of: manager.brightness) { _, newValue in
                    localBrightness = Double(newValue)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: Binding(
                    get: { manager.autoRefreshEnabled },
                    set: { manager.autoRefreshEnabled = $0 }
                )) {
                    Text("Auto Refresh")
                }
                if manager.autoRefreshEnabled {
                    Picker("Interval:", selection: Binding(
                        get: { manager.autoRefreshMinutes },
                        set: { manager.autoRefreshMinutes = $0 }
                    )) {
                        Text("1 min").tag(1)
                        Text("2 min").tag(2)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .pickerStyle(.menu)
                }
            }

            Divider()

            HStack {
                Button("Refresh") {
                    manager.forceRefresh()
                }
                Spacer()
                Button("Settings...") {
                    SettingsWindowManager.shared.showWindow(shortcutManager: shortcutManager)
                }
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding()
        .frame(width: 280)
        .onAppear {
            localSpeed = Double(manager.speed)
            localBrightness = Double(manager.brightness)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerForceRefresh"))) { _ in
            manager.forceRefresh()
        }
    }
}
