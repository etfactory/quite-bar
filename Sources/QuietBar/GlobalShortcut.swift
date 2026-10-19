import AppKit
import Carbon

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var action: (() -> Void)?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard result == noErr, id.signature == 0x51424152, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func configure(_ preferences: Preferences) -> String? {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard preferences.shortcutEnabled else { return nil }
        let id = EventHotKeyID(signature: 0x51424152, id: 1)
        let result = RegisterEventHotKey(preferences.shortcutCode, preferences.shortcutModifiers,
                                       id, GetApplicationEventTarget(), 0, &hotKey)
        return result == noErr ? nil : "단축키를 등록하지 못했습니다 (\(result)). 다른 키 조합을 지정해 주세요."
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }

    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
    }
}
