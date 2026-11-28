import Foundation
import MacNerves
import NativeAgentShared
import PersistenceCore
import MindCore
import NativeAgentCore
import DeskCore
// Blueprint: | `EngineApprovals.swift` | `ApprovalsFacade`: actor-owned approval reads, comparisons, face values and single-flight decisions |

/// Share checked approval rows and load state across surfaces; keep decisions in `ApprovalExecution`.
public actor ApprovalsFacade {
    public nonisolated let dataRoot: URL
    private let counts: CountsFeedProjection
    private var records: [ApprovalRecord] = []
    private var refreshErrorText: String?
    private var hasLoadedSnapshot = false
    private let latest = LatestRead()
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    private var resolutionTasks: [String: Task<ApprovalRecord, Error>] = [:]
    private var resolutionDecisions: [String: String] = [:]

    public init(dataRoot: URL, counts: CountsFeedProjection) {
        self.dataRoot = dataRoot
        self.counts = counts
    }

    deinit {
        for continuation in observers.values { continuation.finish() }
    }

    nonisolated private var inbox: SwiftNativeApprovalInbox {
        SwiftNativeApprovalInbox(root: dataRoot)
    }

    /// Return this read; only forward publication replaces shared rows.
    public func list() async throws -> [ApprovalRecord] {
        var changed = false
        let result: Result<[ApprovalRecord], Error> = await latest.read({
            do { return .success(try await inbox.list(filter: .all)) }
            catch { return .failure(error) }
        }, publish: { result in
            switch result {
            case .success(let loaded):
                let rowsChanged = records != loaded
                changed = rowsChanged || !hasLoadedSnapshot || refreshErrorText != nil
                if rowsChanged { records = loaded }
                hasLoadedSnapshot = true
                refreshErrorText = nil
            case .failure(let error):
                let detail = ApprovalLoadFailurePresentation.banner(error: error, retainedApprovalCount: records.count)
                changed = refreshErrorText != detail
                refreshErrorText = detail
            }
        })
        await publishFace()
        if changed { signalChange() }
        return try result.get()
    }

    public func refresh() async {
        do { _ = try await list() }
        catch { /* The checked read publishes its cause beside retained rows. */ }
    }

    struct Snapshot: Sendable {
        let records: [ApprovalRecord]
        let status: String?
    }

    func snapshot() -> Snapshot {
        Snapshot(records: records,
                 status: refreshErrorText.map(NativeAppSecretRedactor.redactText) ?? (hasLoadedSnapshot ? nil : "Checking approvals…"))
    }

    public func changes() -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        observers[id] = continuation
        continuation.yield()
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return stream
    }

    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    private func signalChange() {
        for continuation in observers.values { continuation.yield() }
    }

    private func publishFace() async {
        let value = ApprovalsFace(
            waitingCount: hasLoadedSnapshot ? WorkOverviewRead.waitingApprovals(records).count : nil,
            error: refreshErrorText.map(NativeAppSecretRedactor.redactText)
        )
        await counts.updateApprovals(value)
    }

    public func resolveApproval(
        id: String, decision: String, coordinator: ApprovalExecution, turn: Turn
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
        let task = Task<ApprovalRecord, Error> {
            let resolved = try await coordinator.resolveApproval(id: trimmedID, decision: decision, turn: turn)
            let changed = !records.contains(resolved)
            latest.write {
                if let index = records.firstIndex(where: { $0.id == resolved.id }) {
                    if records[index] != resolved { records[index] = resolved }
                } else {
                    records.insert(resolved, at: 0)
                }
            }
            await publishFace()
            if changed { signalChange() }
            return resolved
        }
        resolutionTasks[trimmedID] = task
        resolutionDecisions[trimmedID] = normalizedDecision
        defer {
            resolutionTasks.removeValue(forKey: trimmedID)
            resolutionDecisions.removeValue(forKey: trimmedID)
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
    public init(record: ApprovalRecord) {
        let outcome = record.executedAction.map { _ in record.executionResultClass }
        let summary = record.executedAction.map { _ in record.decisionWords }
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
            // Route the phone card to the conversation that received the approval’s chat card, or its originating conversation.
            chatOriginSessionId: record.chatCardSessionId ?? record.chatOriginSessionId,
            lastRequestedAt: record.lastRequestedAt,
            executionOutcome: outcome?.rawValue,
            executionSummary: summary?.isEmpty == false ? summary : nil
        )
    }
}


extension InlineInteractionCoordinator {
    func startTurn(_ prompt: String, _ sessionID: String, _ hideUserBubble: Bool, _ turn: Turn) async throws -> Bool {
        guard let route = turn.envelope?.replyRoute, AgentBridgeCompletionRoute.Kind(surface: route.surface) != .local else {
            return try await platform.startLocalTurn(prompt, sessionID: sessionID, hideUserBubble: hideUserBubble, turn: turn)
        }
        let owner = try engine.resolve()
        try await owner.turnContinuationRuntime().continueInteractionCard(sessionID: sessionID, turn: turn, prompt: prompt)
        return true
    }

    func replayBlockedTool(_ toolName: String, _ argumentsJSON: String, _ sessionID: String, _ turn: Turn) async -> ReplayOutcome {
        guard case .object(let input)? = try? JSONValue.parse(Data(argumentsJSON.utf8))
        else { return .failed("the blocked call's arguments are no longer readable") }
        let owner: NativeAgentEngine
        do { owner = try engine.resolve() }
        catch { return .failed(error.localizedDescription) }
        // Bind the card’s recorded origin and surface so remote restrictions cannot become local authority during replay.
        guard let origin = turn.envelope else {
            return .failed("The blocked call has no recorded origin. Review this card on its originating surface before continuing.")
        }
        let originSurface = origin.surface
        let approvalFiler = NativeAgentChatApprovalFiler(dataRoot: dataRoot)
        let gated = makeGatedToolDispatchClient(
            tools: owner.toolDispatchClient(
                // Resolve autonomy once at the outer gate; reconstructed origin must not trigger another decision.
                enforceAppAutonomy: false
            ),
            jobStore: owner.agentJobs.store, fileAccess: "auto",
            approvalFiler: approvalFiler,
            dataRoot: dataRoot,
            // The replay's receipt is traced like any call, naming the card it runs on.
            tracePeerTurn: true
        )
        // Rehydrate only the replayed tool so it is available without admitting siblings.
        do {
            // The continuation owns this act, including restored peer steering and approval provenance.
            var replayTurn = turn
            replayTurn.verifiedSessionID = sessionID
            replayTurn.offeredTools = [toolName]
            let result = try await gated.dispatch(tool: toolName, input: input, surface: originSurface, turn: replayTurn, invocation: .init())
            return .dispatched(try? result.serialize(pretty: false))
        } catch {
            // Report thrown calls as incomplete so the resolver cannot record a replay that never happened.
            return .failed("\(error)")
        }
    }
}
