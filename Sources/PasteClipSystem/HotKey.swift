import Carbon

/// A system-wide hotkey registered through Carbon (no Accessibility permission needed).
/// One shared event handler routes each press to the hotkey with the matching id.
public final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32

    /// Returns nil when the combination can't be registered, e.g. another app already owns it.
    public init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextID
        Self.nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x434C_5346), id: id) // 'CLSF'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        guard status == noErr else { return nil }
        Self.actions[id] = action
    }

    deinit {
        Self.actions[id] = nil
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, let action = HotKey.actions[hotKeyID.id] else { return OSStatus(eventNotHandledErr) }
            action()
            return noErr
        }, 1, &spec, nil, nil)
    }
}
