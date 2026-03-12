import Carbon
import AppKit

class HotkeyManager {
    private var eventHandlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, action: () -> Void)] = [:]
    private var nextID: UInt32 = 1
    private static var instance: HotkeyManager?
    private let settings = SettingsManager.shared

    private static let toggleID: UInt32 = 1

    init(onToggle: @escaping () -> Void) {
        HotkeyManager.instance = self
        installHandler()
        register(id: HotkeyManager.toggleID, combo: settings.toggleShortcut, action: onToggle)

        settings.onToggleShortcutChanged = { [weak self] in
            self?.reregisterToggle(onToggle)
        }
    }

    deinit {
        unregisterAll()
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
        }
    }

    // MARK: - Public API

    /// Register a hotkey with a specific ID. Returns the ID.
    @discardableResult
    func register(id: UInt32? = nil, combo: KeyCombo, action: @escaping () -> Void) -> UInt32 {
        let hotkeyID: UInt32
        if let id = id {
            hotkeyID = id
            // Unregister existing if reusing ID
            unregister(id: id)
        } else {
            nextID += 1
            hotkeyID = nextID
        }

        var hotKeyRef: EventHotKeyRef?
        let carbonID = EventHotKeyID(signature: OSType(0x434C4950), id: hotkeyID)
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, carbonID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr, let ref = hotKeyRef {
            registrations[hotkeyID] = (ref: ref, action: action)
        }
        return hotkeyID
    }

    /// Unregister a hotkey by ID
    func unregister(id: UInt32) {
        if let reg = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(reg.ref)
        }
    }

    /// Unregister all snippet hotkeys (IDs > toggleID)
    func unregisterSnippetHotkeys() {
        let snippetIDs = registrations.keys.filter { $0 > HotkeyManager.toggleID }
        for id in snippetIDs {
            unregister(id: id)
        }
    }

    /// Register hotkeys for all snippets that have a keyCombo
    func registerSnippetHotkeys(snippets: [(id: UUID, combo: KeyCombo)], action: @escaping (UUID) -> Void) {
        unregisterSnippetHotkeys()
        for (index, snippet) in snippets.enumerated() {
            let snippetID = UInt32(100 + index) // Start snippet IDs at 100
            let uuid = snippet.id
            register(id: snippetID, combo: snippet.combo) {
                action(uuid)
            }
        }
    }

    // MARK: - Private

    private func reregisterToggle(_ onToggle: @escaping () -> Void) {
        unregister(id: HotkeyManager.toggleID)
        register(id: HotkeyManager.toggleID, combo: settings.toggleShortcut, action: onToggle)
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr {
                HotkeyManager.instance?.handleHotkey(id: hotKeyID.id)
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)
    }

    private func handleHotkey(id: UInt32) {
        registrations[id]?.action()
    }

    private func unregisterAll() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
    }
}
