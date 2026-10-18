import AppKit
import MacEvenCore
import Carbon

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var activate: (@MainActor () -> Void)?

    func setEnabled(_ enabled: Bool) -> String? {
        stop()
        guard enabled else { return nil }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.activate?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { stop(); return localized("无法注册快捷键事件：\(result)") }
        let identity = EventHotKeyID(signature: 0x4d634576, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | optionKey | controlKey), identity,
            GetApplicationEventTarget(), 0, &hotKey)
        guard status == noErr else { stop(); return localized("快捷键 Control+Option+Command+M 不可用（\(status)）。") }
        return nil
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
