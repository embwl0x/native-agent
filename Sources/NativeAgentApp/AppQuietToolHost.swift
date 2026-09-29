import Connectors
import ProviderRouting
import AppToolRuntime
import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import ChatOrchestration

@MainActor final class AppQuietToolHost: AppQuietSettingsHost, QuietToolHost {
    var activeChatSessionId: String { appModel.activeChatSessionId }
    func pageRead(_ page: QuietToolPage) async -> (content: [JSONValue], rows: [JSONValue], truncated: Bool) {
        // The presentation port resolved this value from the same immutable page catalog.
        let read = await QuietSelfAdminRender.pageRead(for: QuietPages.page(named: page.id)!, appModel: appModel)
        return (read.content, read.rows, read.truncated)
    }
    func composerState() async -> [String: JSONValue] { await QuietComposerVerbs.state(appModel: appModel) }
    func runComposer(verb: String, value: String, choice: String) async -> QuietComposerOutcome {
        let outcome = await QuietComposerVerbs.run(verb: verb, value: value, choice: choice, appModel: appModel)
        return QuietComposerOutcome(changed: outcome.changed, element: outcome.element, detail: outcome.detail, refusal: outcome.refusal)
    }
    func saveProviderKey(_ key: String, provider: String) async -> QuietProviderKeyOutcome {
        let outcome = await InlineConnectorSetup.saveProviderKey(key, provider: provider, appModel: appModel)
        return QuietProviderKeyOutcome(error: outcome.error, note: outcome.note)
    }
}

@MainActor struct AppToolInteractionResolver: ToolInteractionResolving {
    func interaction(id: String, sessionID: String, dataRoot: URL) async -> InlineInteraction? {
        await InlineInteractionResolver.interaction(id: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    func originEnvelope(of id: String, sessionID: String, dataRoot: URL) async -> TurnEnvelope? {
        await InlineInteractionResolver.originEnvelope(of: id, sessionID: sessionID, dataRoot: dataRoot)
    }
    func descriptor(for interaction: InlineInteraction, dataRoot: URL) -> InlineInteractionDescriptor {
        InlineInteractionResolver.descriptor(for: interaction, dataRoot: dataRoot)
    }
    func begin(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.begin(id: id, sessionID: sessionID, expectedRevision: expectedRevision, dataRoot: dataRoot)
    }
    func decline(id: String, sessionID: String, expectedRevision: Int?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.decline(id: id, sessionID: sessionID, expectedRevision: expectedRevision, dataRoot: dataRoot)
    }
    func returnToPending(_ interaction: InlineInteraction, sessionID: String, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.returnToPending(interaction, sessionID: sessionID, dataRoot: dataRoot)
    }
    func complete(id: String, sessionID: String, selection: String?, scope: InlineInteraction.Scope?, expectedRevision: Int?, attribution: String?, setupError: String?, note: String?, dataRoot: URL) async throws -> InlineInteraction {
        try await InlineInteractionResolver.complete(id: id, sessionID: sessionID, selection: selection, scope: scope, expectedRevision: expectedRevision, attribution: attribution, setupError: setupError, note: note, dataRoot: dataRoot)
    }
    func takeContinuationHandBack(id: String) -> String? {
        InlineInteractionResolver.takeContinuationHandBack(id: id)
    }
    func cardFields(_ interaction: InlineInteraction, descriptor: InlineInteractionDescriptor) -> [String: JSONValue] {
        let card = InlineCardProjection.model(interaction, descriptor: descriptor)
        return [
                "title": .string(card.title),
                "state": .string(card.state.rawValue),
                "why": .string(card.why),
                "primary": .string(card.primaryLabel),
                "secondary": .string(card.secondaryLabel),
                "scope_lines": .array(card.scopeLines.map { .string($0) }),
                "outcome": card.outcome.map { JSONValue.string($0) } ?? .null,
                "outcome_meta": card.outcomeMeta.map { JSONValue.string($0) } ?? .null,
                "can_retry": .bool(card.canRetry),
                "revision": .int(Int64(interaction.revision)),
            ]
    }
    func receiptEnvelope(_ interaction: InlineInteraction) -> JSONValue {
        InlineInteractionResolver.receiptEnvelope(interaction)
    }
    func liveOutcomeSummary(_ interaction: InlineInteraction, dataRoot: URL) async -> String? {
        await InlineInteractionResolver.liveProjection(interaction, dataRoot: dataRoot).state.outcome?.summary
    }
    func saveConnectorToken(_ value: String, connector: String, dataRoot: URL) async -> String? {
            let result: OAuthFlowResult
            switch connector {
            case "notion": result = await NativeOAuthFlow.saveNotionToken(value, dataRoot: dataRoot)
            case "github": result = await NativeOAuthFlow.saveGitHubToken(value, dataRoot: dataRoot, credentialStore: AppGitHubOAuthCredentials())
            default: result = OAuthFlowResult(ok: false, error: "No token route for \(connector).")
            }
            if !result.ok {
                return InlineConnectorSetup.failureReason(
                    result.error ?? "",
                    service: InlineInteractionRegistry.connectorDisplayName(connector, dataRoot: dataRoot),
                    typed: [value]
                )
            }
        return nil
    }
}
