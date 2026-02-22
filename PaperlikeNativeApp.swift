import SwiftUI
import AppKit

@main
struct PaperlikeNativeApp: App {
    @StateObject private var daemonManager = NativeDaemonManager()
    @StateObject private var shortcutManager = GlobalShortcutManager()

    var body: some Scene {
        MenuBarExtra("Paperlike", systemImage: "display") {
            ContentView(manager: daemonManager, shortcutManager: shortcutManager)
        }
        .menuBarExtraStyle(.window)
    }
}

// Custom Window Manager for Settings
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// Global Shortcut Manager using AppKit
class GlobalShortcutManager: ObservableObject {
    @Published var refreshKeyCode: UInt16?
    @Published var refreshModifiers: NSEvent.ModifierFlags?
    
    private var globalMonitor: Any?
    
    init() {
        loadShortcut()
        setupGlobalMonitor()
    }
    
    deinit {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    func saveShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.refreshKeyCode = keyCode
        self.refreshModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: "refreshKeyCode")
        UserDefaults.standard.set(modifiers.rawValue, forKey: "refreshModifiers")
        setupGlobalMonitor()
    }
    
    func clearShortcut() {
        self.refreshKeyCode = nil
        self.refreshModifiers = nil
        UserDefaults.standard.removeObject(forKey: "refreshKeyCode")
        UserDefaults.standard.removeObject(forKey: "refreshModifiers")
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
    }
    
    private func loadShortcut() {
        if UserDefaults.standard.object(forKey: "refreshKeyCode") != nil {
            self.refreshKeyCode = UInt16(UserDefaults.standard.integer(forKey: "refreshKeyCode"))
            self.refreshModifiers = NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: "refreshModifiers")))
        }
    }
    
    private func setupGlobalMonitor() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        
        // Request Accessibility access if needed for global shortcuts
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, let code = self.refreshKeyCode, let mods = self.refreshModifiers else { return }
            
            // Match keycode and essential modifiers (Command, Shift, Control, Option)
            let eventMods = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let targetMods = mods.intersection([.command, .shift, .control, .option])
            
            if event.keyCode == code && eventMods == targetMods {
                // Post notification mapped to Force Refresh
                NotificationCenter.default.post(name: NSNotification.Name("TriggerForceRefresh"), object: nil)
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
            Text("Note: Global shortcuts require Accessibility permissions in System Settings > Privacy & Security.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 400, height: 150)
        // Background listening for key events when recording
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
        if mods.contains(.control) { text += "⌃" }
        if mods.contains(.option) { text += "⌥" }
        if mods.contains(.shift) { text += "⇧" }
        if mods.contains(.command) { text += "⌘" }
        
        // Basic mapping for common keys, typically one would use a Carbon table 
        // to map keycodes to characters, but for a simple UI this suffices or we just show KeyCode
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
                    // Save shortcut
                    shortcutManager.saveShortcut(keyCode: event.keyCode, modifiers: modifiers)
                    isRecording = false
                    return true // Handled
                }
            }
            return false // Not handled
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
                    Text("Cold").tag(1)
                    Text("Warm").tag(2)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TriggerForceRefresh"))) { _ in
            manager.forceRefresh()
        }
    }
}
