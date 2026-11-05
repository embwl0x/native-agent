import SwiftUI
import AppKit
import Carbon.HIToolbox

// Blueprint: | `MenuBarController.swift` | `GlobalHotkey`: Carbon summon registration and tap/hold push-to-talk state with cancellable voice lifecycle |

@MainActor
final class GlobalHotkey: NSObject {
    enum RegistrationTransition: Equatable, Sendable {
        case none, register, unregister
    }

    static let shared = GlobalHotkey()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var pressState = GlobalHotkeyPressState()
    private var voiceStartTask: Task<Void, Never>?
    private(set) var isRegistered = false

    var onVoiceStart: (() -> Void)?
    var onVoiceEnd: (() -> Void)?
    var onVoiceCancel: (() -> Void)?
    var onOpenWindow: (() -> Void)?

    // Carbon uses modifier bits 256 + 512 and keycode 38 for the default Command-Shift-J.
    private let defaultKeyCode: UInt32 = 38
    private let defaultModifiers: UInt32 = UInt32(cmdKey | shiftKey)

    private override init() { super.init() }

    static func registrationTransition(enabled: Bool, isRegistered: Bool) -> RegistrationTransition {
        switch (enabled, isRegistered) {
        case (true, false): .register
        case (false, true): .unregister
        case (true, true), (false, false): .none
        }
    }

    func setEnabled(_ enabled: Bool) {
        switch Self.registrationTransition(enabled: enabled, isRegistered: isRegistered) {
        case .register: register()
        case .unregister: unregister()
        case .none: break
        }
    }

    func register() {
        unregister()
        let hotKeyID = EventHotKeyID(signature: fourCharCode("NASP"), id: 1)
        let keyCode = defaultKeyCode
        let mods = defaultModifiers

        var ref: EventHotKeyRef?
        let err = RegisterEventHotKey(keyCode, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard err == noErr else {
            print("[GlobalHotkey] RegisterEventHotKey failed: \(err)")
            return
        }
        hotKeyRef = ref
        installEventHandler()
        isRegistered = true
        print("[GlobalHotkey] Registered ⌘⇧J global hotkey")
    }

    func unregister() {
        voiceStartTask?.cancel()
        voiceStartTask = nil
        pressState.cancel()
        onVoiceCancel?()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        isRegistered = false
    }

    func isVoiceHoldCurrent() -> Bool {
        pressState.isVoiceHoldCurrent
    }

    private func installEventHandler() {
        var eventTypes = [
            EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: UInt32(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                // Pass unrelated hot keys through because the other global shortcut shares this event target.
                guard let id = hotKeyID(of: event), id.signature == fourCharCode("NASP"), id.id == 1 else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                let eventKind = GetEventKind(event)
                Task { @MainActor in
                    if eventKind == UInt32(kEventHotKeyPressed) {
                        manager.handleKeyDown()
                    } else if eventKind == UInt32(kEventHotKeyReleased) {
                        manager.handleKeyUp()
                    }
                }
                return noErr
            },
            2,
            &eventTypes,
            selfPtr,
            &eventHandlerRef
        )
    }

    func handleKeyDown() {
        guard isRegistered else { return }
        let token = pressState.keyDown()
        voiceStartTask?.cancel()
        voiceStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, self.pressState.activateVoice(for: token) else { return }
            self.onVoiceStart?()
        }
    }

    func handleKeyUp() {
        guard isRegistered else { return }
        guard let action = pressState.keyUp() else { return }
        voiceStartTask?.cancel()
        voiceStartTask = nil
        switch action {
        case .endVoice:
            onVoiceEnd?()
        case .openWindow:
            onOpenWindow?()
        }
    }
}

struct GlobalHotkeyPressState: Sendable {
    enum ReleaseAction: Equatable, Sendable { case openWindow, endVoice }

    private(set) var pressToken: UUID?
    private(set) var voiceHoldActive = false

    var isVoiceHoldCurrent: Bool {
        pressToken != nil && voiceHoldActive
    }

    mutating func keyDown() -> UUID {
        let token = UUID()
        pressToken = token
        voiceHoldActive = false
        return token
    }

    mutating func activateVoice(for token: UUID) -> Bool {
        guard pressToken == token, !voiceHoldActive else { return false }
        voiceHoldActive = true
        return true
    }

    mutating func keyUp() -> ReleaseAction? {
        guard pressToken != nil else { return nil }
        let action: ReleaseAction = voiceHoldActive ? .endVoice : .openWindow
        cancel()
        return action
    }

    mutating func cancel() {
        pressToken = nil
        voiceHoldActive = false
    }
}

// MARK: - Four-char code helper

func hotKeyID(of event: EventRef) -> EventHotKeyID? {
    var id = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &id
    )
    return status == noErr ? id : nil
}

func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for byte in string.utf8 {
        result = (result << 8) | FourCharCode(byte)
    }
    return result
}
