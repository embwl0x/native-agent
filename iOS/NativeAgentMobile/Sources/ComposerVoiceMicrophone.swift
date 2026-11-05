import SwiftUI
import NativeAgentShared
// Blueprint: | `ComposerVoiceMicrophone.swift` | Mic gestures and accessible dictation, voice-note recording, cancel and lock |

struct ComposerVoiceMicrophone: View {
    let input: VoiceInputController
    let begin: (Bool) -> Void
    let release: () -> Void
    let cancel: () -> Void
    @State private var holdTask: Task<Void, Never>?
    @State private var pressed = false
    @State private var held = false
    @State private var cancelled = false
    @State private var lockRequested = false
    @State private var gestureCanRecord = false

    var body: some View {
        gestured
            .onChange(of: input.isListening) { _, listening in
                if listening && lockRequested { input.lock() }
            }
            .onDisappear { holdTask?.cancel() }
            .accessibilityElement()
            .accessibilityLabel(input.isListening ? "Stop recording" : "Microphone")
            .accessibilityHint("Tap to dictate. Hold to record a voice note; slide left to cancel or up to lock.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { accessibleTap() }
            .accessibilityAction(named: "Record voice note hands-free") { lockRequested = true; begin(true) }
            .accessibilityAction(named: "Lock recording") { input.lock() }
            .accessibilityAction(named: "Cancel recording", cancel)
    }

    private func accessibleTap() {
        if input.isListening {
            if input.isVoiceNote { release() } else { input.stop() }
        } else { begin(false) }
    }

    // Split the view so the type checker handles two short modifier chains.
    private var gestured: some View {
        Image(systemName: input.isLocked ? "lock.fill" : "mic.fill")
            .font(.system(size: 18))
            .foregroundStyle(input.isListening ? Color.accentColor : Color.secondary)
            .frame(width: 44, height: 44).contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !input.isFinalizing else { return }
                    if !pressed {
                        pressed = true; held = false; cancelled = false; lockRequested = false
                        gestureCanRecord = !(input.isListening || input.isStarting)
                        if input.isListening || input.isStarting { return }
                        holdTask = Task { @MainActor in
                            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                            guard pressed, !cancelled else { return }
                            held = true
                            begin(true)
                        }
                    }
                    // Movement during the hold delay is intent; a subsequently still finger must not turn cancellation into send.
                    guard gestureCanRecord, !cancelled, !lockRequested else { return }
                    if value.translation.width < -70 {
                        cancelled = true; cancel()
                    } else if value.translation.height < -65 {
                        lockRequested = true; input.lock()
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel(); holdTask = nil
                    defer { pressed = false }
                    guard !cancelled, !input.isFinalizing else { return }
                    if !held && lockRequested { return }
                    if held {
                        if !lockRequested { release() }
                    } else if input.isListening || input.isStarting {
                        if input.isVoiceNote { release() } else { input.stop() }
                    } else { begin(false) }
                })
    }
}
