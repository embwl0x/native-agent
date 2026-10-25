import Foundation
import Observation
import ApprovalInbox
import NativeAgentShared
import PersistenceCore
import ChatTurnRuntime
import ChatTurnContracts
import ChatToolRuntime
import ApprovalTransactions
import Agents
import NativeAgentCore
import DeviceSync
import TrustCenter
// Blueprint: | `EngineApprovals.swift` | `ApprovalsFacade`: one checked records/loading/error publication for health, sidebar, views, actions and phone overview; failed reads retain checked rows and mark them unavailable; shared inline settlement, single-flight resolution and outcome/preflight checks; shared summary/failure wording; Approval reads return their own result; LatestRead orders records/failure publication and committed decisions use write(). |

/// `NativeAgentEngine.approvals` (S10): the ApprovalInbox for one data root, in
/// core types. Every read publishes `records` and its load state for all surfaces.
/// Decisions run
/// through the approval executors (`ApprovalTransactionCoordinator`).
@MainActor
@Observable
public final class ApprovalsFacade {
    public nonisolated let dataRoot: URL

    /// Every approval, pending and decided, newest first, as of the last read.
    public private(set) var records: [ApprovalRecord] = [] {
        didSet { recordsDidChange?() }
    }
    public private(set) var refreshErrorText: String?
    public private(set) var hasLoadedSnapshot = false
    private var readsInFlight = 0
    public var isRefreshing: Bool { readsInFlight > 0 }
    @ObservationIgnored private let latest = LatestRead()

    public var summaryTitle: String {
        if refreshErrorText != nil {
            return hasLoadedSnapshot ? "Approval refresh failed" : "Approval status unavailable"
        }
        guard hasLoadedSnapshot else { return "Checking approvals…" }
        let count = WorkOverviewRead.waitingApprovals(records).count
        return count == 0 ? "No actions need approval" : "\(count) \(count == 1 ? "action needs" : "actions need") approval"
    }

    public var summaryDetail: String {
        if refreshErrorText != nil {
            return hasLoadedSnapshot
                ? "Showing previously loaded approvals. Choose Refresh to check for changes."
                : "Approvals could not be loaded. Choose Refresh to try again."
        }
        guard hasLoadedSnapshot else { return "Checking which actions need your permission." }
        return "Review requests to use tools, change memories, control your Mac or browser, make changes in connected apps, work on Desk tasks, or improve the agent."
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

    /// Returns this read; only a forward publication replaces the shared rows.
    public func list() async throws -> [ApprovalRecord] {
        readsInFlight += 1
        defer { readsInFlight -= 1 }
        let result: Result<[ApprovalRecord], Error> = await latest.read({
            do { return .success(try await inbox.list(filter: .all)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let loaded):
                if records != loaded { records = loaded }
                hasLoadedSnapshot = true
                refreshErrorText = nil
            case .failure(let error):
                refreshErrorText = ApprovalLoadFailurePresentation.banner(error: error, retainedApprovalCount: records.count)
            }
        })
        return try result.get()
    }

    public func refresh() async { _ = try? await list() }

    /// The one file the reader, resolver and app-lifetime observer share.
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
        refreshHealth: @MainActor () async -> Void
    ) async throws {
        do {
            _ = try await resolveApproval(id: id, decision: decision, coordinator: coordinator,
                                          resolutionChanged: resolutionChanged)
            await refreshHealth()
        } catch ApprovalInboxError.alreadyResolved {
            _ = try await list()
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
            let resolved = try await coordinator.resolveApproval(id: trimmedID, decision: decision)
            latest.write {
                if let index = records.firstIndex(where: { $0.id == resolved.id }) {
                    records[index] = resolved
                } else {
                    records.insert(resolved, at: 0)
                }
            }
            return resolved
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

/// Retained approvals are last-known, not evidence that the inbox is healthy.
public enum ApprovalLoadFailurePresentation {
    public static func banner(error: any Error, retainedApprovalCount: Int) -> String {
        let detail = UserFacingError.cause(error, action: "load approvals")
        let retained = retainedApprovalCount == 1
            ? "Approvals couldn't refresh — showing 1 previously loaded approval."
            : retainedApprovalCount > 1
                ? "Approvals couldn't refresh — showing \(retainedApprovalCount) previously loaded approvals."
                : "Approvals couldn't load."
        return "\(retained) \(detail)"
    }
}

extension ApprovalRequest {
    /// The phone's approvals.json row, in the shape the Mac has always sent.
    public init(record: ApprovalRecord) {
        let outcome = record.executedAction.map { _ in record.executionResultClass }
        let summary = record.executedAction.flatMap { _ in record.decisionExperience.face?.words }
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
