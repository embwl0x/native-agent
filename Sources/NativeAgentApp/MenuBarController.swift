// PATCH-2026-05-07: summon-1 Universal summon — global hotkey + enhanced menu bar
import SwiftUI
import AppKit
import Carbon.HIToolbox

// MARK: - GlobalHotkeyManager

/// Registers a global hotkey using Carbon's RegisterEventHotKey.
/// Default: ⌘-⇧-J (configurable via AppStorage "globalHotkey").
/// Tap = open/toggle window. Hold >200ms = voice push-to-talk (wired to VoiceInputController).
@MainActor
final class GlobalHotkeyManager: NSObject {
    enum RegistrationTransition: Equatable, Sendable {
        case none, register, unregister
    }

    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var pressStart: Date?
    private var pressToken: UUID?
    private var voiceStartTask: Task<Void, Never>?
    private var voiceHoldActive = false
    private(set) var isRegistered = false

    // The voice input callback — set by whoever cares (e.g. ChatView)
    var onVoiceStart: (() -> Void)?
    var onVoiceEnd: (() -> Void)?
    var onOpenWindow: (() -> Void)?

    // Default: cmd(cmdKey=256) + shift(512) + j(keycode=38)
    private let defaultKeyCode: UInt32 = 38      // kVK_ANSI_J
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
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = eventHandlerRef {
            RemoveEventHandler(handler)
            eventHandlerRef = nil
        }
        voiceStartTask?.cancel()
        voiceStartTask = nil
        pressStart = nil
        pressToken = nil
        voiceHoldActive = false
        isRegistered = false
    }

    func isVoiceHoldCurrent() -> Bool {
        pressStart != nil && pressToken != nil && voiceHoldActive
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
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
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

    private func handleKeyDown() {
        pressStart = Date()
        let token = UUID()
        pressToken = token
        voiceHoldActive = false
        voiceStartTask?.cancel()
        voiceStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, self.pressToken == token, self.pressStart != nil, !self.voiceHoldActive else { return }
            self.voiceHoldActive = true
            self.onVoiceStart?()
        }
    }

    private func handleKeyUp() {
        guard let start = pressStart else { return }
        let held = Date().timeIntervalSince(start)
        pressStart = nil
        pressToken = nil
        voiceStartTask?.cancel()
        voiceStartTask = nil
        if held >= 0.2, voiceHoldActive {
            onVoiceEnd?()
        } else {
            onOpenWindow?()
        }
        voiceHoldActive = false
    }
}

// MARK: - Four-char code helper

private func fourCharCode(_ string: String) -> FourCharCode {
    var result: FourCharCode = 0
    for char in string.unicodeScalars {
        result = (result << 8) + FourCharCode(char.value)
    }
    return result
}

struct HotkeyControlView: View {
    @AppStorage("globalHotkeyEnabled") private var enabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.sm) {
            Toggle("Enable ⌘⇧J global hotkey", isOn: $enabled)
                .onChange(of: enabled) { _, newValue in
                    GlobalHotkeyManager.shared.setEnabled(newValue)
                }
            Text("⌘⇧J — Tap to open quick chat. Hold to activate voice input.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
            Text("Tap works without Accessibility access. Hold-to-talk needs Microphone and Speech Recognition permission.")
                .font(NativeAgentFont.label)
                .foregroundStyle(.secondary)
        }
    }
}
