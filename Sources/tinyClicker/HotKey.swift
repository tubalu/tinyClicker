import Carbon.HIToolbox
import Foundation

/// Registers a single global hotkey (default F10) that invokes a handler.
/// macOS Accessibility permission is NOT required to register a Carbon hotkey,
/// but the user must not have another app bound to the same key.
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handler: (() -> Void)?
    private static var registry: [UInt32: HotKey] = [:]
    private static var nextId: UInt32 = 1
    private static var monitorInstalled = false

    /// `keyCode` is a Carbon virtual keycode. Defaults to F10 (kVK_F10 = 109).
    init(keyCode: UInt32 = UInt32(kVK_F10), modifiers: UInt32 = 0) {
        let id = HotKey.nextId
        HotKey.nextId += 1

        HotKey.installMonitorIfNeeded()

        let hotKeyId = EventHotKeyID(signature: OSType(0x544B4359), id: id) // 'TKCY'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyId,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            self.ref = ref
            HotKey.registry[id] = self
        }
    }

    deinit {
        if let ref = ref {
            UnregisterEventHotKey(ref)
        }
        HotKey.registry = HotKey.registry.filter { $0.value !== self }
    }

    func onPress(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    fileprivate func fire() {
        handler?()
    }

    private static func installMonitorIfNeeded() {
        guard !monitorInstalled else { return }
        monitorInstalled = true

        let callback: EventHandlerUPP = { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            if status == noErr {
                if let hotKey = HotKey.registry[hkID.id] {
                    DispatchQueue.main.async { hotKey.fire() }
                }
            }
            return noErr
        }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &spec,
            nil,
            nil
        )
    }
}
