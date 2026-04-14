import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandler: EventHandlerRef?

    func registerCtrlSpace(action: @escaping () -> Void) {
        unregister()
        self.handler = action

        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            if hotKeyID.signature == HotkeyService.signature {
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { service.handler?() }
            }
            return noErr
        }, 1, &type, selfPtr, &eventHandler)

        let hkID = EventHotKeyID(signature: Self.signature, id: 1)
        let keyCode: UInt32 = UInt32(kVK_Space)
        let mods: UInt32 = UInt32(controlKey)
        RegisterEventHotKey(keyCode, mods, hkID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        if let handler = eventHandler { RemoveEventHandler(handler) }
        eventHandler = nil
    }

    private static let signature: OSType = {
        let chars = Array("STMU".utf8)
        return (OSType(chars[0]) << 24) | (OSType(chars[1]) << 16) | (OSType(chars[2]) << 8) | OSType(chars[3])
    }()
}
