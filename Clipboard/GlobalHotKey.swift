import AppKit
import Carbon

/// System-wide hotkey via Carbon `RegisterEventHotKey` (same approach as
/// KeyboardShortcuts / Maccy). More reliable than `NSEvent` global monitors
/// for ⌘⇧C when other apps are frontmost.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let signature: OSType = 0x50515948 // 'PQYH'
    private let hotKeyID: UInt32
    private let onPress: () -> Void

    /// ⌘⇧C — Maccy default chord.
    static func commandShiftC(onPress: @escaping () -> Void) -> GlobalHotKey {
        GlobalHotKey(
            id: 1,
            keyCode: UInt32(kVK_ANSI_C),
            carbonModifiers: UInt32(cmdKey | shiftKey),
            onPress: onPress
        )
    }

    /// - Parameters:
    ///   - id: Unique id among this process's hotkeys.
    ///   - keyCode: Virtual key (e.g. `kVK_ANSI_C`).
    ///   - carbonModifiers: `cmdKey | shiftKey | …`
    init(id: UInt32, keyCode: UInt32, carbonModifiers: UInt32, onPress: @escaping () -> Void) {
        self.hotKeyID = id
        self.onPress = onPress
        installHandler()
        register(keyCode: keyCode, modifiers: carbonModifiers)
    }

    deinit {
        unregister()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                let this = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                var hk = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hk
                )
                guard status == noErr, hk.id == this.hotKeyID, hk.signature == this.signature else {
                    return noErr
                }
                DispatchQueue.main.async { this.onPress() }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
    }

    private func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        let hotKeyID = EventHotKeyID(signature: signature, id: hotKeyID)
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            NSLog("PromptQy: RegisterEventHotKey failed (%d) — ⌘⇧C may be taken by another app", status)
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }
}
