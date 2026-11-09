import Foundation
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
import Privacy
// Blueprint: | `EngineApprovals.swift` | `ApprovalsFacade`: actor-owned approval reads, comparisons, face values and single-flight decisions |

/// Share checked approval rows and load state across surfaces; keep decisions in `ApprovalExecution`.
public actor ApprovalsFacade {
    public nonisolated let dataRoot: URL
    private let counts: CountsFeedProjection
    private var records: [ApprovalRecord] = []
    private var refreshErrorText: String?
    private var hasLoadedSnapshot = false
    private var readsInFlight: Set<UUID> = []
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
        let readID = UUID()
        readsInFlight.insert(readID)
        await publishFace()
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
        readsInFlight.remove(readID)
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
            rows: Dictionary(records.map {
                ($0.id, ApprovalsFace.Row(id: $0.id, title: NativeAppSecretRedactor.redactText($0.title), status: $0.status))
            }, uniquingKeysWith: { first, _ in first }),
            waitingCount: hasLoadedSnapshot ? WorkOverviewRead.waitingApprovals(records).count : nil,
            hasLoadedSnapshot: hasLoadedSnapshot, error: refreshErrorText.map(NativeAppSecretRedactor.redactText),
            isRefreshing: !readsInFlight.isEmpty
        )
        await counts.updateApprovals(value)
    }

    public enum Resolution: Equatable, Sendable {
        case applied(ApprovalRecord)
        case noOpInFlight(id: String)
        case noOpAlreadyResolved(id: String, status: String)
        case unavailable(String)
    }

    public func resolveOnce(
        id: String, using operation: @MainActor @Sendable (String) async throws -> ApprovalRecord
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

    public func isResolving(id: String) -> Bool {
        resolutionTasks[id.trimmingCharacters(in: .whitespacesAndNewlines)] != nil
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
            // Route the phone card to the conversation that received the approval’s chat card, or its originating conversation.
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
        // Replay original arguments through the shared dispatcher and ordinary gate; card resolution grants no sibling authority. Keep the filer so
        // confirmations reach the person.
        InlineInteractionResolver.replayBlockedTool = { toolName, argumentsJSON, sessionID, turn in
            guard case .object(let input)? = try? JSONValue.parse(Data(argumentsJSON.utf8))
            else { return .failed("the blocked call's arguments are no longer readable") }
            let dataRoot = PersistenceCore.defaultDataRoot()
            // Bind the card’s recorded origin and surface so remote restrictions cannot become local authority during replay.
            guard let origin = turn.envelope else {
                return .failed("The blocked call has no recorded origin. Review this card on its originating surface before continuing.")
            }
            let originSurface = origin.surface
            let approvalFiler = NativeAgentChatApprovalFiler(dataRoot: dataRoot)
            let gated = makeGatedToolDispatchClient(
                tools: NativeAgentEngine.live.toolDispatchClient(
                    // Resolve autonomy once at the outer gate; reconstructed origin must not trigger another decision.
                    enforceAppAutonomy: false
                ),
                fileAccess: "auto",
                approvalFiler: approvalFiler,
                dataRoot: dataRoot
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

        // Persist a MAC over the card identity, never the signed-turn verdict; replay must verify against the live pairing secret, refusing missing or rotated
        // authority.
        InlineInteractionSignatureWitness.install(
            mint: { canonical in
                guard let secret = try? PairingSecret.loadOrGenerateSecret()
                else { return nil }
                return BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
            },
            verify: { canonical, receipt in
                guard let secret = try? PairingSecret.loadOrGenerateSecret()
                else { return false }
                let expected = BridgeMessage.hmacHex(of: Data(canonical.utf8), secret: secret)
                return BridgeMessage.constantTimeEqual(receipt, expected)
            }
        )

    }
}
