import Carbon
import os

private let logger = Logger(subsystem: "com.mcmonad.core", category: "HotkeyManager")

/// Signature for MCMonad hotkeys: "MCMN" as UInt32
private let kHotkeySignature: UInt32 = 0x4D43_4D4E

@MainActor
final class HotkeyManager {
    var onHotkeyPressed: (@MainActor (Int) -> Void)?

    private var registeredRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    fileprivate static var shared: HotkeyManager?

    init() {}

    func register(_ hotkeys: [HotkeySpec]) {
        unregisterAll()

        // Install Carbon event handler if not already installed
        if eventHandlerRef == nil {
            installEventHandler()
        }

        // Store self for the C callback
        HotkeyManager.shared = self

        for spec in hotkeys {
            var hotkeyId = EventHotKeyID()
            hotkeyId.signature = OSType(kHotkeySignature)
            hotkeyId.id = UInt32(spec.id)

            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                spec.keyCode,
                spec.modifiers,
                hotkeyId,
                GetApplicationEventTarget(),
                0,
                &ref
            )

            if status == noErr, let ref {
                registeredRefs.append(ref)
                logger.info("Registered hotkey id=\(spec.id) keyCode=\(spec.keyCode) modifiers=\(spec.modifiers)")
            } else {
                logger.error("Failed to register hotkey id=\(spec.id): OSStatus \(status)")
            }
        }
    }

    func unregisterAll() {
        for ref in registeredRefs {
            UnregisterEventHotKey(ref)
        }
        registeredRefs.removeAll()
    }

    // MARK: - Private

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status != noErr {
            logger.error("Failed to install hotkey event handler: OSStatus \(status)")
        }
    }
}

// MARK: - Carbon Event Handler (C function pointer)

private func hotkeyEventHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotkeyId = EventHotKeyID()
    let status = GetEventParameter(
        event,
        UInt32(kEventParamDirectObject),
        UInt32(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyId
    )

    guard status == noErr else {
        return OSStatus(eventNotHandledErr)
    }

    guard hotkeyId.signature == OSType(kHotkeySignature) else {
        return OSStatus(eventNotHandledErr)
    }

    let hotkeyIdValue = Int(hotkeyId.id)
    DispatchQueue.main.async { @MainActor in
        HotkeyManager.shared?.onHotkeyPressed?(hotkeyIdValue)
    }

    return noErr
}
