import Foundation
import AppKit
import Carbon

final class CarbonHotkeyManager: @unchecked Sendable {
    static let shared = CarbonHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    typealias HotKeyHandler = @Sendable () -> Void
    private var handler: HotKeyHandler?
    
    init() {
        setupEventHandler()
    }
    
    deinit {
        unregister()
        if let eventHandler = eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }
    
    private func setupEventHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        let ptr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        let status = InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, event, userData) -> OSStatus in
            guard let userData = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<CarbonHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event,
                                          EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID),
                                          nil,
                                          MemoryLayout<EventHotKeyID>.size,
                                          nil,
                                          &hotKeyID)
            
            if status == noErr && hotKeyID.signature == manager.hotKeySignature {
                manager.handler?()
                return noErr
            }
            
            return CallNextEventHandler(nextHandler, event)
        }, 1, &eventType, ptr, &eventHandler)
        
        if status != noErr {
            print("Failed to install event handler: \(status)")
        }
    }
    
    private let hotKeySignature = OSType(0x504C5246) // 'PLRF' (Paperlike Refresh)
    
    func register(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, handler: @escaping HotKeyHandler) {
        unregister()
        
        self.handler = handler
        
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: 1)
        
        let status = RegisterEventHotKey(UInt32(keyCode),
                                        carbonModifiers,
                                        hotKeyID,
                                        GetApplicationEventTarget(),
                                        0,
                                        &hotKeyRef)
        
        if status != noErr {
            print("Failed to register hotkey: \(status)")
        }
    }
    
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        self.handler = nil
    }
}
