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
                }, watch: { [self] in
                    pending[identity.card] = controlIdentity
                    observe()
                    InlineInteractionResolver.GrantWatch.shared.watchUntilGranted(identity.card, sessionID: identity.session,
                        dataRoot: engine.dataRoot) { [weak self] in
                            guard let self else { return }
                            await self.verifyPending()
                        }
                }, refresh: { [engine] in await engine.transcripts.refreshCards(in: identity.session) })
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

    func verify(_ identity: CardIdentity) async throws -> FaceActReply {
        let current = try await read(identity)
        if current.state.isOpen {
            let selection = try await InlineInteractionResolver.selectionForReturn(current, dataRoot: engine.dataRoot)
            _ = await InlineInteractionResolver.completeIfVerified(id: identity.card, sessionID: identity.session,
                expectedRevision: current.revision, selection: selection,
                scope: current.kind == .modelChoice ? .persistent : nil, dataRoot: engine.dataRoot)
        }
        return try await result(identity, controlIdentity: identity)
    }

    private func read(_ identity: CardIdentity) async throws -> InlineInteraction {
        guard let card = try await InlineInteractionResolver.interaction(id: identity.card, sessionID: identity.session,
            dataRoot: engine.dataRoot) else {
            throw PartCallError(code: "card_unavailable", message: "This request has no saved interaction. Refresh its conversation.")
        }
        return card
    }

    private func result(_ identity: CardIdentity, controlIdentity: CardIdentity) async throws -> FaceActReply {
        let current = try await read(identity)
        let verified = current.state.outcome != nil
        let failure = current.state.failureReason.map {
            WireFailure(code: "card_control_failed", message: TurnSecretRedactor.redactText($0), cause: nil, effects: .known)
        }
        if verified, let shown = pending[identity.card] {
            try BodyInboxCardActionEffects.requirePresentation(try await call(.closeCardControl(shown)))
            pending[identity.card] = nil
        }
        if pending.isEmpty { observation?.cancel(); observation = nil }
        return .card(.init(identity: identity, effects: .known, presentationOperation: nil, failure: failure,
            controlIdentity: controlIdentity, verified: verified))
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
                if !Task.isCancelled { SystemToastCenter.shared.push(error: error.localizedDescription, autoDismissAfter: nil) }
            }
            await engine.face.detachSink(sink.epoch)
        }
    }

    private func verifyPending() async {
        for identity in pending.values {
            do { _ = try await verify(identity) }
            catch { SystemToastCenter.shared.push(error: error.localizedDescription, autoDismissAfter: nil) }
        }
    }
}
