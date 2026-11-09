import Foundation
import Carbon.HIToolbox

/// Registers system-wide hot keys through Carbon's RegisterEventHotKey, which works
/// without Accessibility permission because it never taps the event stream.
public final class HotKeyManager {
    private struct Registration {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x5263_4272 // 'RcBr'

    public init() {}

    deinit {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.ref)
        }
        registrations.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    public func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        if let existing = registrations.removeValue(forKey: id) {
            UnregisterEventHotKey(existing.ref)
        }

        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            NSLog("RecBar: could not register hot key %u (status %d)", id, status)
            return
        }
        registrations[id] = Registration(ref: ref, action: action)
    }

    fileprivate func perform(id: UInt32) {
        guard let registration = registrations[id] else { return }
        DispatchQueue.main.async {
            registration.action()
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            recBarHotKeyHandler,
            1,
            &eventType,
            userData,
            &eventHandler
        )
    }
}

private func recBarHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

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
    guard status == noErr else { return status }

    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.perform(id: hotKeyID.id)
    return noErr
}
