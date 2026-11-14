import Foundation
import AppKit
import SwiftUI
import NativeAgentShared
// Blueprint: | `CardControls.swift` | Native card presentations and checked verification; mounted hosts own return work and feedback |

@MainActor @Observable
final class CardControls {
    static let shared = CardControls()
    var connectorSheet: ConnectorSheetRequest?
    @ObservationIgnored private var awaitingReturn: [String: CardIdentity] = [:]

    func disconnect() {
        connectorSheet = nil
        awaitingReturn.removeAll()
    }

    struct ConnectorSheetRequest: Identifiable, Equatable {
        let id: String
        let provider: String
        let sessionID: String
        let revision: Int
    }

    @discardableResult
    func begin(_ answer: CardAnswer, appModel: AppModel) async throws -> CardActionResult {
        let reply = try await appModel.protectedFormAct(.answerCard(answer))
        guard case .card(let result) = reply, result.identity == answer.identity else {
            throw PartCallError(code: "card_unconfirmed", message: "This reply does not identify the request you answered.")
        }
        if let failure = result.failure { throw failure }
        if let control = result.controlIdentity { awaitingReturn[control.card] = control }
        if result.verified { closeVerifiedControl(result.controlIdentity ?? answer.identity) }
        return result
    }

    func pendingReturn(in session: String) -> [CardIdentity] {
        awaitingReturn.values.filter { $0.session == session }.sorted { $0.card < $1.card }
    }

    private func isAwaiting(_ identity: CardIdentity) -> Bool { awaitingReturn[identity.card] == identity }

    func verify(_ identity: CardIdentity, appModel: AppModel) async throws {
        try Task.checkCancellation()
        guard isAwaiting(identity) else { return }
        let reply = try await appModel.checkedFaceAct(.verifyCardOnReturn(
            card: identity.card, session: identity.session, revision: identity.revision))
        try Task.checkCancellation()
        // Verification can close its control before the correlated result arrives.
        guard case .card(let result) = reply, result.identity == identity else {
            throw PartCallError(code: "card_unconfirmed", message: "The request's verification has no matching reply.")
        }
        if let failure = result.failure { throw failure }
        if result.verified { closeVerifiedControl(identity) }
        else if isAwaiting(identity), let control = result.controlIdentity { awaitingReturn[control.card] = control }
    }

    func show(_ identity: CardIdentity, presentation: CardControlPresentation) throws {
        switch presentation {
        case .page(let page):
            guard let item = SidebarItem(rawValue: page) else {
                throw PartCallError(code: "card_page_unknown", message: "The request names an unavailable setup page.")
            }
            openPage(item, for: identity.card, sessionID: identity.session, revision: identity.revision)
        case .connector(let provider):
            awaitingReturn[identity.card] = identity
            connectorSheet = .init(id: identity.card, provider: provider, sessionID: identity.session, revision: identity.revision)
        }
    }

    /// A setup page opens in place, as every page does; the card is verified when its chat shows again.
    func openPage(_ item: SidebarItem, for id: String? = nil, sessionID: String = "", revision: Int? = nil) {
        if let id, let revision { awaitingReturn[id] = .init(card: id, session: sessionID, revision: revision) }
        _ = ApplicationLifetime.shared.request(.sidebar(item))
    }
    func connectorSheetClosed() {
        if let request = connectorSheet {
            awaitingReturn[request.id] = .init(card: request.id, session: request.sessionID, revision: request.revision)
        }
        connectorSheet = nil
    }

    /// The body's presentation router closes controls only after its owner verifies the request.
    func closeVerifiedControl(_ identity: CardIdentity) {
        guard awaitingReturn[identity.card] == identity else { return }
        awaitingReturn[identity.card] = nil
        if connectorSheet?.id == identity.card { connectorSheet = nil }
    }
}

extension AppModel {
    func answerProtectedCard(_ answer: CardAnswer) async throws -> CardActionResult {
        try await CardControls.shared.begin(answer, appModel: self)
    }
}
