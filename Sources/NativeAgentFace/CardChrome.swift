import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `CardChrome.swift` | Shared protected card forms retain nonsecret edits and route secret bytes to the card's own control |

struct CardChrome: View {
    let card: SecureCardFace
    @Environment(AppModel.self) private var appModel
    @State private var session = FacePageSession()
    private var key: String { "card:" + card.identity.session + ":" + card.identity.card }
    private var form: PartFace.Block {
        var actions: [PartFace.Action] = []
        if card.acceptsEntry {
            if !card.fields.isEmpty { actions.append(.init(id: "answer", label: card.primaryLabel, call: .init("card.answer"))) }
            if let label = card.signInLabel { actions.append(.init(id: "signIn", label: label, call: .init("card.signIn"))) }
            if let label = card.fullSetupLabel { actions.append(.init(id: "full_setup", label: label, call: .init("card.full_setup"))) }
        }
        if card.restartNote != nil { actions.append(.init(id: "restart", label: "Restart NativeAgent", call: .init("card.restart"))) }
        return .init(kind: "form", key: key, revision: String(card.identity.revision), fields: (card.acceptsEntry ? card.fields : []).map { field in
            .init(id: field.id, label: field.label, kind: field.secret ? "secret" : "line", placeholder: field.placeholder,
                required: !field.optional)
        }, submit: actions, protected: true, receiver: FaceSecretReceiver.answerCard.name, doors: ["mac"])
    }
    private var guidance: String { (card.fields.compactMap(\.helper) + [card.busyNote, card.restartNote].compactMap { $0 }).joined(separator: "\n") }
    var body: some View {
        ProtectedFaceEntry {
            FaceProtectedForm(face: PartFace(sections: [.init(id: key, footer: guidance, rows: [], block: form)]),
                receiver: .answerCard, session: session, validationFree: ["signIn", "full_setup", "restart"]) { input in
                do {
                    let identity = card.identity
                    let result: CardActionResult
                    if input.submission.checking {
                        let reply = try await appModel.protectedFormAct(.verifyCardOnReturn(
                            card: identity.card, session: identity.session, revision: identity.revision))
                        guard case .card(let saved) = reply else { throw unconfirmed() }
                        result = saved
                    } else {
                        let choice = input.submission.action == "signIn" ? "answer" : input.submission.action
                        let entering = choice == "answer"
                        let answer = CardAnswer(identity: identity, choice: choice,
                            fields: entering ? input.submission.values ?? [:] : [:], secrets: entering ? input.secrets : [:])
                        result = try await appModel.answerProtectedCard(answer)
                    }
                    if let failure = result.failure { throw failure }
                    guard result.identity.card == identity.card, result.identity.session == identity.session else { throw unconfirmed() }
                    if input.submission.checking, !result.verified {
                        return .init(words: "This request is still waiting on its setup owner.", effects: .unknown)
                    }
                    return .init(words: result.verified ? "The request is settled." : "The setup owner accepted your answer.",
                        effects: result.effects, accepted: true, committed: card.fields.map { .init(id: $0.id) })
                } catch { return .interrupted(error) }
            }
        }
    }
    private func unconfirmed() -> WireFailure {
        .init(code: "card_unconfirmed", message: "The card owner did not confirm this answer.", cause: nil, effects: .unknown)
    }
}
