import Carbon.HIToolbox
import AppKit

/// System-wide hotkeys — founders record from wherever they are:
///   ⌘⇧R  start / stop recording
///   ⌘⇧X  retake marker while recording ("that take was bad, cut it")
@MainActor
enum HotKeys {
    static var onRecordToggle: (() -> Void)?
    static var onRetakeMarker: (() -> Void)?

    private static var refs: [EventHotKeyRef?] = []

    static func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Dispatcher target, NOT application target — application target only
        // sees events while we're frontmost, which is never true mid-recording.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let which = id.id
            Task { @MainActor in
                if which == 1 { HotKeys.onRecordToggle?() }
                if which == 2 { HotKeys.onRetakeMarker?() }
            }
            return noErr
        }, 1, &eventType, nil, nil)

        register(keyCode: UInt32(kVK_ANSI_R), id: 1)
        register(keyCode: UInt32(kVK_ANSI_X), id: 2)
    }

    private static func register(keyCode: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            keyCode, UInt32(cmdKey | shiftKey),
            EventHotKeyID(signature: OSType(0x4C_5A_53_54), id: id), // "LZST"
            GetEventDispatcherTarget(), 0, &ref
        )
        refs.append(ref)
    }
}
