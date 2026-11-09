import Carbon.HIToolbox
import os

/// A system-wide shortcut, through Carbon's hot keys: they need no Accessibility permission, and
/// fire on the main thread whichever app is in front.
@MainActor
final class GlobalHotKey {
    /// ⌃⌥⌘D: shows Yab's tab in front in the desk.
    static let showBrowserTab = (keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey | cmdKey))

    private static var installed: [UInt32: GlobalHotKey] = [:]
    private static var handler: EventHandlerRef?
    private static let logger = Logger(subsystem: "com.bugenzhao.PRDesk", category: "HotKey")

    private var ref: EventHotKeyRef?
    private var action: () -> Void

    private init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers the shortcut once; later calls only replace its action. Another app (or another
    /// copy of PR Desk) holding it leaves it to them, and the menu's shortcut still works here.
    static func register(_ key: (keyCode: UInt32, modifiers: UInt32), action: @escaping () -> Void) {
        let id = key.keyCode << 16 | key.modifiers & 0xFFFF
        if let hotKey = installed[id] {
            hotKey.action = action
            return
        }
        installHandler()
        let hotKey = GlobalHotKey(action: action)
        let status = RegisterEventHotKey(
            key.keyCode, key.modifiers, EventHotKeyID(signature: OSType(0x5052_444B), id: id),
            GetApplicationEventTarget(), 0, &hotKey.ref
        )
        guard status == noErr else {
            logger.error("Registering a hot key failed: \(status)")
            return
        }
        installed[id] = hotKey
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let id = hotKeyID.id
            MainActor.assumeIsolated { GlobalHotKey.installed[id]?.action() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
