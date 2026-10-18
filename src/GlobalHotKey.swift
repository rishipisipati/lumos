import AppKit
import Carbon.HIToolbox

enum GlobalHotKeyError: Error, LocalizedError {
    case handlerFailed(OSStatus)
    case registrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .handlerFailed(let status):
            return "Could not listen for the Option-Space shortcut (error \(status))."
        case .registrationFailed(let status):
            return "Option-Space could not be registered as a global shortcut (error \(status)); another app may already use it. Turn it off in View → Option-Space Shows Lumos."
        }
    }
}

/// System-wide Option-Space. Carbon hot keys need no Accessibility permission
/// and only ever report this one key combination, never other keystrokes.
final class GlobalHotKey {
    private let action: () -> Void
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    init(action: @escaping () -> Void) throws {
        self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        if handlerStatus != noErr {
            throw GlobalHotKeyError.handlerFailed(handlerStatus)
        }
        let identifier = EventHotKeyID(signature: OSType(0x4C4D_4F53), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if registerStatus != noErr {
            RemoveEventHandler(handlerRef)
            handlerRef = nil
            throw GlobalHotKeyError.registrationFailed(registerStatus)
        }
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }
}
