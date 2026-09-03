import AppKit
import Carbon

final class Hotkeys {
    var toggle: (() -> Void)?
    var peek: ((Bool) -> Void)?
    private var handler: EventHandlerRef?
    private var refs: [EventHotKeyRef] = []
    private(set) var error: String?
    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data -> OSStatus in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<Hotkeys>.fromOpaque(data).takeUnretainedValue()
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if id.id == 1 && down { owner.toggle?() }
            if id.id == 2 { owner.peek?(down) }
            return noErr
        }, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register(present: UInt32(kVK_ANSI_P), peek: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
    }
    func register(present: UInt32, peek: UInt32, modifiers: UInt32) {
        self.peek?(false)
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        error = nil
        for (index, key) in [present, peek].enumerated() {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x5645494c, id: UInt32(index + 1)), GetApplicationEventTarget(), 0, &ref)
            if status != noErr { error = "A shortcut is already in use. Choose another in Settings." }
            if let ref { refs.append(ref) }
        }
    }
    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }
}
