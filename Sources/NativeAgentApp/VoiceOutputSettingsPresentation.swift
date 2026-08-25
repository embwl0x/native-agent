import Foundation

/// The voice-output controls need the same distinction as the playback
/// boundary: a known local selection is not the same as an unreadable Trust
/// policy that happens to fall back to the Mac voice.  Keep this presentation
/// pure so the mounted Trust card and its evaluation share the exact state
/// contract.
enum VoiceOutputSettingsPresentation {
    enum PolicyReadState: Equatable {
        case loading
        case available
        case unavailable
        case saving
        case saveFailed
    }

    struct State: Equatable {
        let readState: PolicyReadState
        let title: String
        let detail: String
        let status: String
        let systemImage: String
        let remoteVoiceEnabled: Bool?
        let canChangeRemoteVoice: Bool
        let canRetry: Bool
    }

    static func resolve(
        trustPolicy: TrustPolicy?,
        hasReadAttempted: Bool,
        isSaving: Bool,
        saveFailure: String?
    ) -> State {
        if let saveFailure, !saveFailure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           trustPolicy == nil {
            return State(
                readState: .saveFailed,
                title: "Voice output policy was not saved",
                detail: "The policy can no longer be confirmed. \(saveFailure)",
                status: "warn",
                systemImage: "exclamationmark.triangle.fill",
                remoteVoiceEnabled: nil,
                canChangeRemoteVoice: false,
                canRetry: true
            )
        }
        guard let trustPolicy else {
            if hasReadAttempted {
                return State(
                    readState: .unavailable,
                    title: "Voice output policy unavailable",
                    detail: "The Trust policy could not be read. OpenAI voice cannot be selected; read aloud will use the Mac voice with an availability notice.",
                    status: "warn",
                    systemImage: "exclamationmark.triangle.fill",
                    remoteVoiceEnabled: nil,
                    canChangeRemoteVoice: false,
                    canRetry: true
                )
            }
            return State(
                readState: .loading,
                title: "Loading voice output policy",
                detail: "Checking the Trust policy before showing the selected voice route.",
                status: "info",
                systemImage: "hourglass",
                remoteVoiceEnabled: nil,
                canChangeRemoteVoice: false,
                canRetry: false
            )
        }

        let remoteVoiceEnabled = trustPolicy.multimodalPolicy?.tts_openai == true
        if isSaving {
            return State(
                readState: .saving,
                title: "Saving voice output policy",
                detail: "The previously confirmed voice route remains active until this Trust policy write completes.",
                status: "info",
                systemImage: "arrow.triangle.2.circlepath",
                remoteVoiceEnabled: remoteVoiceEnabled,
                canChangeRemoteVoice: false,
                canRetry: false
            )
        }
        if let saveFailure, !saveFailure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return State(
                readState: .saveFailed,
                title: "Voice output policy was not saved",
                detail: "The prior Trust policy remains active. \(saveFailure)",
                status: "warn",
                systemImage: "exclamationmark.triangle.fill",
                remoteVoiceEnabled: remoteVoiceEnabled,
                canChangeRemoteVoice: true,
                canRetry: true
            )
        }
        return State(
            readState: .available,
            title: remoteVoiceEnabled ? "OpenAI voice selected" : "Mac voice selected",
            detail: remoteVoiceEnabled
                ? "OpenAI voice is allowed by the saved Trust policy. Preflight denials still fall back to the Mac voice with a visible reason."
                : "The saved Trust policy selects the Mac voice. OpenAI voice remains off until you explicitly allow it.",
            status: remoteVoiceEnabled ? "ok" : "info",
            systemImage: remoteVoiceEnabled ? "speaker.wave.3.fill" : "speaker.wave.2",
            remoteVoiceEnabled: remoteVoiceEnabled,
            canChangeRemoteVoice: true,
            canRetry: false
        )
    }
}
