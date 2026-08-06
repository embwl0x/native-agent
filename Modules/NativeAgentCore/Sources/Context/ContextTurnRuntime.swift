import Foundation

/// One-shot, RAM-only handoff for an optional query embedding. Producers can
/// start the existing embedder alongside other turn preparation; consumers
/// either take the vector when it is already available (`valueIfReady`) or wait
/// a BOUNDED interval for it (`value(waitingUpTo:)`) — never indefinitely.
public final class ContextQueryEmbeddingTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContextQueryEmbeddingValue?
    private var waiters: [UUID: CheckedContinuation<ContextQueryEmbeddingValue?, Never>] = [:]

    public init() {}

    public var embeddingIfReady: [Float]? {
        lock.withLock { value?.values }
    }

    public var valueIfReady: ContextQueryEmbeddingValue? { lock.withLock { value } }

    /// Sweep R4 A5: the vector, waiting up to `timeoutNanoseconds` for a cold
    /// embedder to warm. Returns nil on timeout — the caller then proceeds
    /// exactly as the old never-wait behavior did, so a permanently cold or
    /// unwired embedder can add at most this bounded delay and can NEVER hang
    /// the turn. Continuation-based, so a vector that lands early resumes
    /// immediately rather than sitting out the full interval.
    public func value(
        waitingUpTo timeoutNanoseconds: UInt64
    ) async -> ContextQueryEmbeddingValue? {
        if let ready = valueIfReady { return ready }
        guard timeoutNanoseconds > 0 else { return nil }
        let id = UUID()
        // The timeout must not be armed until the waiter is REGISTERED: a
        // timeout that fires before `waiters[id]` exists removes nothing, and
        // the continuation then parks with no one left to resume it — an
        // unbounded hang, the exact failure this API exists to prevent
        // (gpt-5.5 review 2026-08-06, blocking #1). The continuation closure
        // runs synchronously before suspension, so arming inside it — after
        // the lock — closes the window.
        let timeoutHolder = TaskHolder()
        defer { timeoutHolder.cancel() }
        return await withCheckedContinuation {
            (continuation: CheckedContinuation<ContextQueryEmbeddingValue?, Never>) in
            // Re-check UNDER the lock: `publish` may have landed between the
            // fast path above and here, and a continuation parked after the
            // one-shot publish would only ever be resumed by the timeout.
            var immediate: ContextQueryEmbeddingValue?
            var alreadyResolved = false
            lock.withLock {
                if let ready = value {
                    immediate = ready
                    alreadyResolved = true
                } else {
                    waiters[id] = continuation
                }
            }
            if alreadyResolved {
                continuation.resume(returning: immediate)
            } else {
                timeoutHolder.store(Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    self?.resumeWaiter(id)
                })
            }
        }
    }

    /// Tiny lock-guarded holder so the timeout task can be armed inside the
    /// continuation closure yet cancelled by the caller's `defer`.
    private final class TaskHolder: @unchecked Sendable {
        private let holderLock = NSLock()
        private var task: Task<Void, Never>?
        func store(_ t: Task<Void, Never>) {
            holderLock.lock(); defer { holderLock.unlock() }
            task = t
        }
        func cancel() {
            holderLock.lock(); defer { holderLock.unlock() }
            task?.cancel()
        }
    }

    /// Resume ONE waiter with whatever the ticket holds now (nil on timeout).
    /// Removing from the dictionary under the lock is what makes resume
    /// exactly-once across the publish/timeout race.
    private func resumeWaiter(_ id: UUID) {
        var continuation: CheckedContinuation<ContextQueryEmbeddingValue?, Never>?
        var current: ContextQueryEmbeddingValue?
        lock.withLock {
            continuation = waiters.removeValue(forKey: id)
            current = value
        }
        continuation?.resume(returning: current)
    }

    public func publish(_ embedding: [Float], modelFingerprint: String = "legacy-unverified") {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return }
        let fingerprint = modelFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return }
        var resolved: ContextQueryEmbeddingValue?
        var pending: [CheckedContinuation<ContextQueryEmbeddingValue?, Never>] = []
        lock.withLock {
            guard value == nil else { return }
            let published = ContextQueryEmbeddingValue(
                values: embedding,
                modelFingerprint: fingerprint
            )
            value = published
            resolved = published
            pending = Array(waiters.values)
            waiters.removeAll()
        }
        // Resume OUTSIDE the lock: a continuation can resume its task inline.
        for continuation in pending { continuation.resume(returning: resolved) }
    }
}

public struct ContextQueryEmbeddingValue: Sendable, Equatable {
    public let values: [Float]
    public let modelFingerprint: String

    public init(values: [Float], modelFingerprint: String) {
        self.values = values
        self.modelFingerprint = modelFingerprint
    }
}

public struct ContextTurnRequest: Sendable, Equatable {
    public let surface: ContextSurface
    public let origin: ContextOriginClass
    public let userMessage: String
    public let personaIDHint: String?
    public let sessionID: String?
    public let recentTurns: [String]
    public let activeTask: String?
    public let unresolvedQuestion: String?
    public let goal: String?
    public let predictedToolGroups: Set<String>
    public let contextualTerms: Set<String>
    public let cognitiveActivation: [ContextAtomID: Double]
    public let workingAtomIDs: Set<ContextAtomID>
    public let queryEmbedding: [Float]?
    public let queryEmbeddingModelFingerprint: String?
    public let allowedPrivacy: Set<ContextPrivacy>
    public let permissionLabels: Set<String>
    public let characterBudget: Int
    /// Optional bounded escape hatch for authoritative mandatory context that
    /// grows beyond `characterBudget`. The coordinator retries only a
    /// `mandatoryBudgetExceeded` selection and never exceeds this ceiling.
    /// Defaults to `characterBudget`, preserving strict callers and tests.
    public let maximumCharacterBudget: Int
    /// Ranked-context room retained after mandatory atoms on an expanded
    /// retry. This keeps accumulated authoritative corrections from silently
    /// crowding all relevant memory and task context out of the packet.
    public let postMandatoryCharacterReserve: Int

    public init(
        surface: ContextSurface,
        origin: ContextOriginClass,
        userMessage: String,
        personaIDHint: String? = nil,
        sessionID: String? = nil,
        recentTurns: [String] = [],
        activeTask: String? = nil,
        unresolvedQuestion: String? = nil,
        goal: String? = nil,
        predictedToolGroups: Set<String> = [],
        contextualTerms: Set<String> = [],
        cognitiveActivation: [ContextAtomID: Double] = [:],
        workingAtomIDs: Set<ContextAtomID> = [],
        queryEmbedding: [Float]? = nil,
        queryEmbeddingModelFingerprint: String? = nil,
        allowedPrivacy: Set<ContextPrivacy> = [.localPrivate, .trustedRemote, .publicSafe],
        permissionLabels: Set<String> = [],
        characterBudget: Int = 6_000,
        maximumCharacterBudget: Int? = nil,
        postMandatoryCharacterReserve: Int = 0
    ) {
        self.surface = surface
        self.origin = origin
        self.userMessage = userMessage
        self.personaIDHint = personaIDHint
        self.sessionID = sessionID
        self.recentTurns = recentTurns
        self.activeTask = activeTask
        self.unresolvedQuestion = unresolvedQuestion
        self.goal = goal
        self.predictedToolGroups = predictedToolGroups
        self.contextualTerms = contextualTerms
        self.cognitiveActivation = cognitiveActivation
        self.workingAtomIDs = workingAtomIDs
        self.queryEmbedding = queryEmbedding.flatMap { vector in
            !vector.isEmpty && vector.allSatisfy(\.isFinite) ? vector : nil
        }
        let fingerprint = queryEmbeddingModelFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.queryEmbeddingModelFingerprint = self.queryEmbedding == nil
            ? nil
            : ((fingerprint?.isEmpty == false) ? fingerprint : nil)
        self.allowedPrivacy = allowedPrivacy
        self.permissionLabels = permissionLabels
        self.characterBudget = max(1, characterBudget)
        self.maximumCharacterBudget = max(
            self.characterBudget,
            maximumCharacterBudget ?? self.characterBudget
        )
        self.postMandatoryCharacterReserve = max(0, postMandatoryCharacterReserve)
    }
}

/// Owns the immutable generation lease for the complete provider/tool loop.
/// Copying this reference into derived TurnContext values preserves the pin.
public final class ContextPreparedTurn: @unchecked Sendable {
    public let mode: ContextFlowMode
    public let kernel: StablePromptKernel
    public let mirror: RequiredDocumentMirror
    public let packet: ContextPacket
    public let lease: ContextGenerationLease
    public let generation: ContextStoredGeneration
    public let need: NeedSignal
    private let feedbackHandler: (@Sendable (
        ContextFeedbackSignal,
        [ContextAtomID],
        [String]
    ) async -> Void)?
    private let feedbackLock = NSLock()
    private var outcomeRecorded = false
    private var memoryRecordProvenance: [String]?

    public init(
        mode: ContextFlowMode,
        kernel: StablePromptKernel,
        mirror: RequiredDocumentMirror,
        packet: ContextPacket,
        lease: ContextGenerationLease,
        generation: ContextStoredGeneration,
        need: NeedSignal,
        feedbackHandler: (@Sendable (
            ContextFeedbackSignal,
            [ContextAtomID],
            [String]
        ) async -> Void)? = nil
    ) {
        self.mode = mode
        self.kernel = kernel
        self.mirror = mirror
        self.packet = packet
        self.lease = lease
        self.generation = generation
        self.need = need
        self.feedbackHandler = feedbackHandler
    }

    /// Packet provenance (2026-07-11): the memory RECORD identities behind this
    /// turn's selected `.memory`/`.correction` atoms. Atom/source IDs in the
    /// packet are one-way digests, so only the projection owner (app layer) can
    /// resolve them — it attaches the resolved IDs here after preparation.
    /// Attach-once: the preparer sets it before the turn is shared; later calls
    /// are ignored so a mid-turn re-attach can never mutate what the engine
    /// already read. Never attached == empty == pre-provenance behavior.
    /// This rides the prepared-turn object, NOT the packet: the packet, its
    /// fingerprint, and selection receipts stay identity-free.
    public var selectedMemoryRecordIDs: [String] {
        feedbackLock.withLock { memoryRecordProvenance ?? [] }
    }

    public func attachMemoryRecordProvenance(_ recordIDs: [String]) {
        let bounded = Array(Set(recordIDs.filter { !$0.isEmpty })).sorted().prefix(32)
        feedbackLock.withLock {
            guard memoryRecordProvenance == nil else { return }
            memoryRecordProvenance = Array(bounded)
        }
    }

    public func recordExpansion(atomID: ContextAtomID, receiptID: String) async {
        await feedbackHandler?(.expansion, [atomID], [receiptID])
    }

    public func recordRetry() async {
        await feedbackHandler?(.retry, packet.receipt.selectedAtomIDs, [packet.receipt.id])
    }

    public func recordOutcome(_ outcome: ContextTurnOutcome) async {
        let shouldRecord = feedbackLock.withLock {
            let value = !outcomeRecorded
            outcomeRecorded = true
            return value
        }
        guard shouldRecord else { return }
        await feedbackHandler?(
            .outcome(outcome),
            packet.receipt.selectedAtomIDs,
            [packet.receipt.id]
        )
    }

    deinit {
        lease.release()
    }
}

public protocol ContextTurnPreparing: Sendable {
    func contextFlowMode() async -> ContextFlowMode
    func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket?
    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn
}

public extension ContextTurnPreparing {
    func beginQueryEmbedding(_ text: String) async -> ContextQueryEmbeddingTicket? {
        _ = text
        return nil
    }
}

public enum ContextTurnPreparationError: Error, Equatable, Sendable {
    case coordinatorNotStarted
    case generationUnavailable
    case kernelUnavailable(surface: ContextSurface, personaIDHint: String?)
}

/// Mutation-free revision read used to prove that a frozen evaluation epoch
/// stayed on one immutable Context generation. This carries identifiers only;
/// no atom text or personal content leaves the owner.
public struct ContextFrozenRevision: Sendable, Equatable, Codable {
    public let generationID: Int64
    public let sourceFingerprint: String
    public let arenaGenerationID: Int64

    public init(generationID: Int64, sourceFingerprint: String, arenaGenerationID: Int64) {
        self.generationID = generationID
        self.sourceFingerprint = sourceFingerprint
        self.arenaGenerationID = arenaGenerationID
    }
}
