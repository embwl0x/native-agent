import Foundation
import Observation
import ApprovalInbox
import NativeAgentShared
import PersistenceCore
import ChatOrchestration
import ApprovalTransactions
import Agents
import SlackConnector

public extension ExternalSendExecutionDependencies {
    static let production = ExternalSendExecutionDependencies(
        slackSend: { input, idempotencyKey, dataRoot in
            do {
                let result = try await SlackConnectorActions.postMessage(
                    input: input,
                    idempotencyKey: idempotencyKey,
                    dataRoot: dataRoot
                )
                return ExternalSendProviderOutcome.classifySlack(result)
            } catch {
                return ExternalSendProviderOutcome.classifySlackFailure(error)
            }
        },
        agentMailSend: { input, idempotencyKey, dataRoot in
            let result = await AgentMailActions.sendNow(
                input: input,
                approvalId: nil,
                idempotencyKey: idempotencyKey,
                dataRoot: dataRoot,
                recordReceipt: false
            )
            return ExternalSendProviderOutcome.classifyAgentMail(result)
        }
    )
}
import NativeAgentCore
import DeviceSync
import TrustCenter

/// `NativeAgentEngine.approvals` (S10): the ApprovalInbox for one data root, in
/// core types. Every surface that shows approvals renders `records`; the read
/// is nonisolated so the phone lanes use the same owner. Decisions run
/// through the approval executors (`ApprovalTransactionCoordinator`).
@MainActor
@Observable
public final class ApprovalsFacade {
    public nonisolated let dataRoot: URL

    /// Every approval, pending and decided, newest first, as of the last read.
    public var records: [ApprovalRecord] = [] {
        didSet { recordsDidChange?() }
    }
    @ObservationIgnored public var recordsDidChange: (@MainActor () -> Void)?
    @ObservationIgnored private var resolutionTasks: [String: Task<ApprovalRecord, Error>] = [:]
    @ObservationIgnored private var resolutionDecisions: [String: String] = [:]

    public nonisolated init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    nonisolated private var inbox: SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: dataRoot)
    }

    /// Every approval record, newest first.
    public nonisolated func list() async throws -> [ApprovalRecord] {
        try await inbox.list(filter: .all)
    }

    /// The one file the reader and the resolver share; mounted pages watch it.
    public nonisolated func requestsPath() async -> URL {
        await inbox.approvalsPath
    }

    public enum Resolution: Equatable, Sendable {
        case applied(ApprovalRecord)
        case noOpInFlight(id: String)
        case noOpAlreadyResolved(id: String, status: String)
        case unavailable(String)
    }

    public func resolveOnce(
        id: String, using operation: @MainActor (String) async throws -> ApprovalRecord
    ) async throws -> Resolution {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return .unavailable("The approval request has no identifier.")
        }
        guard !isResolving(id: trimmedID) else {
            return .noOpInFlight(id: trimmedID)
        }

        do {
            return .applied(try await operation(trimmedID))
        } catch let ApprovalInboxError.alreadyResolved(id: resolvedID, status: status) {
            return .noOpAlreadyResolved(id: resolvedID, status: status)
        }
    }

    public func settleInlineCard(
        id: String, decision: String, coordinator: ApprovalTransactionCoordinator,
        resolutionChanged: @MainActor (String, Bool) -> Void,
        didResolve: @MainActor (String) -> Void,
        refreshHealth: @MainActor () async -> Void
    ) async throws {
        do {
            _ = try await resolveApproval(id: id, decision: decision, coordinator: coordinator,
                                          resolutionChanged: resolutionChanged)
            didResolve(decision)
            await refreshHealth()
        } catch ApprovalInboxError.alreadyResolved {
            records = (try? await list()) ?? records
            didResolve(records.first(where: { $0.id == id })?.decision ?? "")
        }
    }

    public func isResolving(id: String) -> Bool {
        resolutionTasks[id.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
    }

    public func resolveApproval(
        id: String, decision: String, coordinator: ApprovalTransactionCoordinator,
        resolutionChanged: @MainActor (String, Bool) -> Void
    ) async throws -> ApprovalRecord {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            throw NSError(domain: "NativeAgentApproval", code: 400, userInfo: [
                NSLocalizedDescriptionKey: "The approval request has no identifier."
            ])
        }
        let normalizedDecision = decision.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let task = resolutionTasks[trimmedID] {
            // Only the same decision can join an executor already in flight.
            if let inFlight = resolutionDecisions[trimmedID], inFlight != normalizedDecision {
                throw NSError(domain: "NativeAgentApproval", code: 409, userInfo: [
                    NSLocalizedDescriptionKey:
                        "This request is already being \(inFlight). That decision was not sent."
                ])
            }
            return try await task.value
        }
        let task = Task<ApprovalRecord, Error> { @MainActor in
            return try await coordinator.resolveApproval(id: trimmedID, decision: decision)
        }
        resolutionTasks[trimmedID] = task
        resolutionDecisions[trimmedID] = normalizedDecision
        resolutionChanged(trimmedID, true)
        defer {
            resolutionTasks.removeValue(forKey: trimmedID)
            resolutionDecisions.removeValue(forKey: trimmedID)
            resolutionChanged(trimmedID, false)
        }
        return try await task.value
    }
}

extension ApprovalRequest {
    /// The phone's approvals.json row, in the shape the Mac has always sent.
    public init(record: ApprovalRecord) {
        let outcome = record.executedAction.map(ChatToolOutcome.exactResultClass)
        let summary = record.executedAction.map { receipt in
            var fields: [String: JSONValue] = { if case .object(let fields) = receipt { return fields }; return [:] }()
            if fields["detail"] == nil, let detail = record.detail { fields["detail"] = .string(detail) }
            let value = JSONValue.object(fields)
            return [ChatToolOutcome.explanation(value), ChatToolOutcome.remedy(value)]
                .compactMap { $0 }.joined(separator: " ")
        }
        self.init(
            id: record.id,
            title: record.title,
            action: record.action,
            risk: record.risk,
            reason: record.reason,
            status: record.status,
            createdAt: record.createdAt,
            resolvedAt: record.resolvedAt,
            decision: record.decision,
            payloadPreview: record.payloadPreview,
            localOnly: record.localOnly,
            remoteResolvable: record.remoteResolvable,
            // Where the phone draws its inline card: the conversation the
            // approval's chat card went to, else the one that asked.
            chatOriginSessionId: record.chatCardSessionId ?? record.chatOriginSessionId,
            lastRequestedAt: record.lastRequestedAt,
            executionOutcome: outcome?.rawValue,
            executionSummary: summary?.isEmpty == false ? summary : nil
        )
    }
}


extension NativeAgentEngine {
    @MainActor
    public static func configureInlineInteractionsAtLaunch(startTurn: @escaping InlineInteractionResolver.TurnStarter) {
        InlineInteractionResolver.startTurn = startTurn
        // The blocked call, replayed with the arguments the model originally
        // wrote, through the ORDINARY gate: the same membrane a first call
        // passes, with no autonomy bypass and no approval inherited from the
        // card. Resolving "connect GitHub" is not permission to act as GitHub.
        //
        // It is the SAME dispatcher and the SAME approval inbox Mac chat uses.
        // A bare SwiftToolDispatcher cannot reach the app-owned tools at all,
        // and a nil filer makes every CONFIRM-tier call fail closed with no
        // request ever landing in front of the person — a card resolved into
        // silence.
        InlineInteractionResolver.replayBlockedTool = { toolName, argumentsJSON, sessionID, origin in
            guard case .object(let input)? = try? JSONValue.parse(Data(argumentsJSON.utf8))
            else { return .failed("the blocked call's arguments are no longer readable") }
            let dataRoot = PersistenceCore.defaultDataRoot()
            // The ORIGIN surface answers for this call, not the Mac.
            //
            // The replay used to build the Mac profile and dispatch under
            // surface "chat" whatever the card came from, so a card raised from
            // the phone with remote_from_ios_allowed false — or from a Telegram
            // chat that is not on the allowlist — replayed as a trusted local
            // call. The envelope the raising turn wrote on the card's own row is
            // bound here instead, including its surface.
            // Absent (a card older than the envelope) keeps the Mac default,
            // which is the only honest reading of a local-only transcript.
            let originSurface = origin?.surface ?? NativeAgentAppChatSurfaceProfile.mac.rawValue
            let approvalFiler = NativeAgentChatApprovalFiler(dataRoot: dataRoot)
            let gated = makeGatedToolDispatchClient(
                tools: NativeAgentEngine.live.toolDispatchClient(
                    // The gate below resolves autonomy once, as it does for an
                    // ordinary Mac turn; the inner dispatcher must not re-run
                    // that decision from a reconstructed origin.
                    enforceAppAutonomy: false,
                    swarmApprovalFiler: approvalFiler
                ),
                fileAccess: "auto",
                approvalFiler: approvalFiler,
                dataRoot: dataRoot
            )
            // Only the replayed tool is rehydrated: a lazy gate must not answer
            // `not_loaded` for the one call being replayed, and no sibling tool
            // gets an accidental capability out of it.
            do {
                let result = try await LLMCallContext.$turnActiveTools.withValue([toolName]) {
                    // The whole origin envelope — verified chat/user ids and
                    // the reply route included — so the gate resolves trust
                    // from the same identities the first attempt was judged on.
                    try await ChatToolSessionContext.$envelope.withValue(origin) {
                    try await ChatToolSessionContext.$verifiedChatId
                        .withValue(origin?.verifiedChatId) {
                    try await ChatToolSessionContext.$verifiedUserId
                        .withValue(origin?.verifiedUserId) {
                    try await ChatToolSessionContext.$commandSignatureVerified
                        .withValue(origin?.commandSignatureVerified) {
                    try await ChatToolSessionContext.$verifiedSessionId.withValue(sessionID) {
                        try await ChatToolSessionContext.$replyRoute
                            .withValue(origin?.deliveryRoute) {
                                try await gated.dispatch(
                                    tool: toolName, input: input, surface: originSurface
                                )
                            }
                    }
                    }
                    }
                    }
                    }
                }
                return .dispatched(try? result.serialize(pretty: false))
            } catch {
                // A throw means the call never completed. Reported as such so
                // the resolver does not record a replay that did not happen.
                return .failed("\(error)")
            }
        }

        // The pairing half of the card's signature receipt.
        //
        // A card raised by a signed iPhone turn has to be able to replay AS a
        // signed turn, and the persisted envelope must never carry that
        // verdict itself. So the continuation carries a MAC over its own row
        // identity, minted here from the live pairing secret and re-checked
        // here at replay. A rotated or missing secret simply stops verifying,
        // and the card says "sign in from the phone again" instead of
        // replaying with authority it can no longer prove.
        InlineInteractionSignatureWitness.install(
            mint: { canonical in
                guard let secret = try? PairingSecretManager.loadOrGenerateSecret()
                else { return nil }
                return BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
            },
            verify: { canonical, receipt in
                guard let secret = try? PairingSecretManager.loadOrGenerateSecret()
                else { return false }
                let expected = BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
                let a = Array(receipt.utf8), b = Array(expected.utf8)
                guard a.count == b.count else { return false }
                var diff: UInt8 = 0
                for i in 0..<a.count { diff |= a[i] ^ b[i] }
                return diff == 0
            }
        )

    }
}
