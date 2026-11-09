import Foundation
import NativeAgentShared
// Blueprint: | `ComposerControlCommand.swift` | Checked native composer requests retain their conversation and real body result |

struct ComposerControlCommand: Identifiable {
    struct Issue: Identifiable {
        let id: UUID
        let message: String
    }

    enum Operation {
        case model(String, provider: String)
        case reasoning(String)
        case fast(Bool)
        case trust(MobileTrustAction.Preset, confirmed: Bool)
        case handBack(UInt64)

        var savesChoice: Bool {
            switch self {
            case .model, .reasoning, .fast: true
            case .trust, .handBack: false
            }
        }

        var words: String {
            switch self {
            case .model: "save the Chat model"
            case .reasoning: "save the thinking level"
            case .fast: "save Fast mode"
            case .trust: "change Trust"
            case .handBack: "hand back Mac control"
            }
        }
    }

    let id = UUID()
    let session: String
    let operation: Operation

    @MainActor func perform(_ appModel: AppModel) async throws {
        try Task.checkCancellation()
        let routing = QuietComposerCommands.Routing(appModel: appModel, sessionID: session)
        switch operation {
        case .model(let model, let provider): try await routing.select(model: model, provider: provider)
        case .reasoning(let effort): try await routing.setEffort(effort)
        case .fast(let enabled): try await routing.setFast(enabled)
        case .trust(let preset, let confirmed):
            let read = PageActRequest(page: "trust", row: "policy", action: "read_revision",
                                      value: nil, expectedRevision: nil, expectedCall: nil)
            guard case .result(.string(let revision)) = try await appModel.chatAct(.pageAct(read)) else {
                throw appModel.chatProtocolFailure("the current Trust revision.")
            }
            try Task.checkCancellation()
            let request = TrustPresetRequest(preset: preset.rawValue, confirmed: confirmed, expectedRevision: revision)
            guard case .trust = try await appModel.chatAct(.applyTrustPreset(request)) else {
                throw appModel.chatProtocolFailure("the saved Trust settings.")
            }
        case .handBack(let generation):
            try await appModel.client.act(.handBackMacControl(expectedGeneration: generation)).checkedAcknowledgement()
        }
    }
}
