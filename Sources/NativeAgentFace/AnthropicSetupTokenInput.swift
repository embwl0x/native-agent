import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `AnthropicSetupTokenInput.swift` | A protected shared form sends transient setup-token bytes to the Anthropic owner |

struct AnthropicSetupTokenInput: View {
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    var body: some View {
        ProtectedFaceEntry {
            FaceProtectedForm(face: PartFace(sections: [
                .init(id: "anthropic.setup", title: "Or use a setup token", footer: "Run claude setup-token in Terminal, then paste it here.", rows: [],
                    block: .init(kind: "form", key: "anthropic.setup", fields: [
                        .init(id: "token", label: "Setup token", kind: "secret", placeholder: "sk-ant-oat01-…", required: true)
                    ], submit: [.init(id: "save", label: "Save token", role: .primary, call: .init("anthropic.setup.save"))],
                    protected: true, receiver: FaceSecretReceiver.saveAnthropicSetupToken.name, doors: ["mac"]))
            ]), receiver: .saveAnthropicSetupToken, session: session) { input in
                do {
                    guard let secret = input.secrets["token"] else {
                        throw WireFailure(code: "token_required", message: "Enter a setup token.", cause: nil, effects: .none)
                    }
                    if input.submission.checking {
                        return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.anthropic(secret))))
                    }
                    let reply = try await appModel.protectedFormAct(.saveAnthropicSetupToken(secret: secret))
                    return try .protectedCommit(reply, words: "Setup token saved.", fields: [.init(id: "token")])
                } catch { return .interrupted(error) }
            }
        }
    }
}
