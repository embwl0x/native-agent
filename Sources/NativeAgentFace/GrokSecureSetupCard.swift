import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `GrokSecureSetupCard.swift` | Shared protected routine entry sends transient credentials to the native Grok owner |

struct GrokSecureSetupCard: View {
    let contact: String
    let operation: UUID
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    private var face: PartFace {
        PartFace(title: "Routine credentials", sections: [
            .init(id: "grok.bot", rows: [], block: .init(kind: "form", key: "grok.bot", fields: [
                .init(id: "name", label: "Bot name", required: true)
            ], submit: [.init(id: "bot", label: "Use this Bot", call: .init("agent.grok_bot"))])),
            .init(id: "grok.import", rows: [.init(id: "grok.import", title: "Routine", actions: [
                .init(id: "import", label: "Read routine securely", call: .init("agent.grok_import"))])])
        ])
    }
    var body: some View {
        ProtectedFaceEntry {
            VStack(alignment: .leading, spacing: 12) {
                FaceView(face: face, door: door, session: session)
                FaceProtectedForm(face: PartFace(sections: [
                    .init(id: "grok.credentials", rows: [], block: .init(kind: "form", key: "grok.credentials", fields: [
                        .init(id: "credentials", label: "Routine credentials", kind: "secret",
                            placeholder: "Paste the JSON object with url and key", required: true)
                    ], submit: [.init(id: "save", label: "Save to Keychain", role: .primary, call: .init("grok.credentials.save"))],
                        protected: true, receiver: FaceSecretReceiver.importGrokCredentials.name, doors: ["mac"]))
                ]), receiver: .importGrokCredentials, session: session) { input in
                    do {
                        guard let secret = input.secrets["credentials"] else {
                            throw WireFailure(code: "grok_credentials_required", message: "Enter the routine credentials.",
                                cause: nil, effects: input.submission.checking ? .unknown : .none)
                        }
                        let request = GrokCredentialWrite(operation: operation, contact: contact, secret: secret)
                        if input.submission.checking {
                            return try FaceActOutcome.reply(await appModel.protectedFormAct(.readCredential(.grok(request))))
                        }
                        let reply = try await appModel.protectedFormAct(.importGrokCredentials(request))
                        return try .protectedCommit(reply, words: "Routine credentials saved to Keychain.", fields: [.init(id: "credentials")])
                    } catch { return .interrupted(error) }
                }
            }
        }
    }
    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "Grok setup") { submission in
            do {
                let bot = submission.action == "bot"
                let value = bot ? submission.values?["name"] : nil
                let call = PartFace.Call(bot ? "agent.grok_bot" : "agent.grok_import", ["agent": .string(contact)])
                let reply = try await appModel.protectedFormAct(.pageAct(.init(page: "connectors",
                    row: (bot ? "agent-grok-bot:" : "agent-grok:") + contact, action: bot ? "set" : "import", value: value,
                    expectedRevision: nil, expectedCall: value.map { call.setting($0) } ?? call,
                    answers: true, operation: submission.id, checking: submission.checking)))
                let outcome = try FaceActOutcome.reply(reply)
                return outcome
            } catch { return .interrupted(error) }
        }
    }
}
