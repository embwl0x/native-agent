import AppKit
import EngineRuntime
import ApprovalTransactions
import AppToolRuntime
import AttentionRouting
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import Connectors
import DeviceSync
import Experiences
import Foundation
import MacControl
import MacIntegration
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ProviderRouting
import SlackBot
import SwiftUI
import TrustCenter

import BackgroundLoops
// Blueprint: | `BodyCardActions.swift` | Body-owned inline interaction answers and verified-control settlement |

@MainActor
final class BodyCardActions {
    let engine: NativeAgentEngine
    let controls: any InlineInteractionControlPort
    let call: @MainActor @Sendable (FaceCall) async throws -> FaceReply
    let restart: @MainActor () async throws -> Void
    private var pending: [String: CardIdentity] = [:]
    /// Controls that open something outside the card (a page, sheet, System Settings, Chrome) and leave it running until the person comes
    /// back. A watched one keeps its watch after a return reopens it. A walking permission card stays answerable while running, and its walk
    /// goes on across returns, so it is not among them.
    private static let returnControls: Set<InlineInteractionDescriptor.Control> = [
        .pairDevice, .connectorManualToken, .trustPostureRequired, .providerGroupModel, .internetAccounts, .chromeSetup, .capabilityFlag,
    ]
    private var observation: Task<Void, Never>?

    init(engine: NativeAgentEngine, controls: any InlineInteractionControlPort,
         call: @escaping @MainActor @Sendable (FaceCall) async throws -> FaceReply,
         restart: @escaping @MainActor () async throws -> Void) {
        self.engine = engine; self.controls = controls; self.call = call; self.restart = restart
    }

    isolated deinit { observation?.cancel() }

    func answer(_ answer: CardAnswer) async throws -> FaceActReply {
        let identity = answer.identity
        let current = try await read(identity)
        guard current.revision == identity.revision else {
            throw PartCallError(code: "card_revision_changed", message: "This request has changed. Read it again before answering.")
        }
        let descriptor = await InlineInteractionResolver.descriptor(for: current, dataRoot: engine.dataRoot)
        if answer.choice == "restart" {
            guard InlineCards.model(current, descriptor: descriptor).restartNote != nil else {
                throw PartCallError(code: "card_restart_unavailable", message: "This request does not need an app restart.")
            }
            try await restart()
            return .card(.init(identity: identity, effects: .known, presentationOperation: nil, failure: nil))
        }
        // A walking permission card stays answerable: Continue starts the one walk over from the first grant still off. The grant watch
        // already carries a running card (its census), and a wake of its own here would read as the person's return from the pane just opened.
        if current.kind == .permission, case .running = current.state, descriptor.control == .macPermissionGrant {
            await InlineInteractionResolver.walk(id: identity.card, sessionID: identity.session, handed: true, asking: true,
                dataRoot: engine.dataRoot)
            pending[identity.card] = identity
            observe()
            await engine.transcripts.refreshCards(in: identity.session)
            return try await result(identity, controlIdentity: identity)
        }
        var values: [String: String] = [:]
        let fields = InlineCards.model(current, descriptor: descriptor).fields
        for (key, value) in answer.fields {
            guard fields.contains(where: { $0.id == key && !$0.isSecret }), case .string(let words) = value else {
                throw PartCallError(code: "card_field_invalid", message: "The request's entry must contain text.")
            }
            values[key] = words
        }
        for (key, bytes) in answer.secrets {
            guard fields.contains(where: { $0.id == key && $0.isSecret }), let words = String(data: bytes, encoding: .utf8) else {
                throw PartCallError(code: "card_secret_invalid", message: "The protected entry is not valid UTF-8.")
            }
            values[key] = words
        }
        let permitted = Set(fields.map(\.id))
        guard Set(values.keys).isSubset(of: permitted) else {
            throw PartCallError(code: "card_fields_changed", message: "The request's entry fields changed. Read it again.")
        }
        let running = try await InlineInteractionResolver.begin(id: identity.card, sessionID: identity.session,
            expectedRevision: identity.revision, dataRoot: engine.dataRoot)
        let controlIdentity = CardIdentity(card: identity.card, session: identity.session, revision: running.revision)
        let turn = TurnRequest(message: "", sessionID: identity.session, surface: "chat",
            envelope: TurnEnvelope.personOnMac("mac_ui:interaction." + identity.card)).turn()
        do {
            try await InlineInteractionResolver.runControl(running, descriptor: descriptor, sessionID: identity.session,
                value: values["value"], choice: ["answer", "begin", "full_setup"].contains(answer.choice) ? nil : answer.choice,
                values: values, fullSetup: answer.choice == "full_setup", turn: turn, controls: controls, dataRoot: engine.dataRoot,
                present: { [self] control in
                    try await present(control, descriptor: descriptor, identity: controlIdentity)
                }, watch: { [self] in watch(controlIdentity) }, refresh: { [engine] in await engine.transcripts.refreshCards(in: identity.session) })
        } catch {
            let cause = FaceSecretRedaction.text(error.localizedDescription, secrets: Array(answer.secrets.values))
            pending[identity.card] = nil
            if pending.isEmpty { observation?.cancel(); observation = nil }
            do {
                _ = try await InlineInteractionResolver.complete(id: identity.card, sessionID: identity.session,
                    expectedRevision: running.revision, setupError: cause, turn: nil, dataRoot: engine.dataRoot)
            } catch {
                throw WireFailure(code: "card_settlement_failed", message: "The request failed and could not record its outcome.",
                    cause: cause + "\n" + FaceSecretRedaction.text(error.localizedDescription, secrets: Array(answer.secrets.values)), effects: .known)
            }
            throw WireFailure(code: "card_control_failed", message: "The request could not complete.", cause: cause, effects: .known)
        }
        return try await result(identity, controlIdentity: controlIdentity)
    }

    /// Watch a card until its owner verifies it: page changes, and for a permission card the grant watch that carries its walk.
    private func watch(_ identity: CardIdentity) {
        pending[identity.card] = identity
        observe()
        InlineInteractionResolver.GrantWatch.shared.watchUntilGranted(identity.card, sessionID: identity.session,
            dataRoot: engine.dataRoot) { [weak self] in
                guard let self else { return }
                await self.verifyPending()
            }
    }

    /// `returned` is the person back from the control (the chat showing again, or Check); a page or sheet left unfinished then puts the card
    /// back to pending. A page's own changes verify without it, and leave the card running while the person is still there.
    func verify(_ identity: CardIdentity, returned: Bool = true) async throws -> FaceActReply {
        let current = try await read(identity)
        if current.state.isOpen {
            let selection = try await InlineInteractionResolver.selectionForReturn(current, dataRoot: engine.dataRoot)
            let scope: InlineInteraction.Scope? = current.kind == .modelChoice ? .persistent : nil
            let control = await InlineInteractionResolver.descriptor(for: current, dataRoot: engine.dataRoot).control
            if returned, Self.returnControls.contains(control), current.state == .running, current.revision == identity.revision {
                await InlineInteractionResolver.settleOrReopen(identity.card, sessionID: identity.session, expectedRevision: current.revision,
                    selection: selection, scope: scope, dataRoot: engine.dataRoot)
            } else {
                _ = await InlineInteractionResolver.completeIfVerified(id: identity.card, sessionID: identity.session,
                    expectedRevision: current.revision, selection: selection, scope: scope, dataRoot: engine.dataRoot)
            }
        }
        return try await result(identity, controlIdentity: identity, onlyWhileRunning: true)
    }

    private func read(_ identity: CardIdentity) async throws -> InlineInteraction {
        guard let card = try await InlineInteractionResolver.interaction(id: identity.card, sessionID: identity.session,
            dataRoot: engine.dataRoot) else {
            throw PartCallError(code: "card_unavailable", message: "This request has no saved interaction. Refresh its conversation.")
        }
        return card
    }

    /// `onlyWhileRunning`: a verification names its control only while the card still runs it; unverified and not running, nothing is
    /// underway to come back from, so the watch on it ends here and on the face.
    private func result(_ identity: CardIdentity, controlIdentity: CardIdentity,
                        onlyWhileRunning: Bool = false) async throws -> FaceActReply {
        let current = try await read(identity)
        let verified = current.state.outcome != nil
        let watched = verified || !onlyWhileRunning || current.state == .running
        let failure = current.state.failureReason.map {
            WireFailure(code: "card_control_failed", message: TurnSecretRedactor.redactText($0), cause: nil, effects: .known)
        }
        if verified, let shown = pending[identity.card] {
            try BodyInboxCardActionEffects.requirePresentation(try await call(.closeCardControl(shown)))
            pending[identity.card] = nil
        }
        if !watched { pending[identity.card] = nil }
        if pending.isEmpty { observation?.cancel(); observation = nil }
        return .card(.init(identity: identity, effects: .known, presentationOperation: nil, failure: failure,
            controlIdentity: watched ? controlIdentity : nil, verified: verified))
    }

    private func present(_ control: InlineInteractionDescriptor.Control, descriptor: InlineInteractionDescriptor,
                         identity: CardIdentity) async throws {
        let presentation: CardControlPresentation
        switch control {
        case .internetAccounts:
            guard let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"),
                  NSWorkspace.shared.open(url) else {
                throw PartCallError(code: "internet_accounts_unavailable", message: "System Settings could not open Internet Accounts.")
            }
            return
        case .pairDevice: presentation = .page("Connectors")
        case .connectorManualToken: presentation = descriptor.target == "telegram" ? .page("Connectors") : .connector(descriptor.target)
        case .trustPostureRequired: presentation = .page("Trust")
        case .providerGroupModel: presentation = .page("Providers")
        default:
            throw PartCallError(code: "card_presentation_unavailable", message: "This request has no setup presentation.")
        }
        pending[identity.card] = identity
        observe()
        try BodyInboxCardActionEffects.requirePresentation(try await call(.showCardControl(identity: identity, presentation: presentation)))
    }

    private func observe() {
        guard observation == nil else { return }
        observation = Task { [weak self, engine] in
            let sink = await engine.face.attachSink()
            do {
                for try await batch in sink.batches {
                    guard !Task.isCancelled else { break }
                    if batch.values.keys.contains(where: { key in
                        switch key {
                        case .settings, .counts, .page("providers"), .page("connectors"): true
                        default: false
                        }
                    }) { await self?.verifyPending() }
                }
            } catch {
                if !Task.isCancelled { SystemToastCenter.shared.push(error: error.localizedDescription) }
            }
            await engine.face.detachSink(sink.epoch)
        }
    }

    private func verifyPending() async {
        for identity in pending.values {
            do { _ = try await verify(identity, returned: false) }
            catch { SystemToastCenter.shared.push(error: error.localizedDescription) }
        }
    }
}
