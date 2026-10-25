import Foundation

// Blueprint: | `ContextTurnRuntime.swift` | `ContextPreparedTurn`, request and embedding ticket: generation lease, bounded query-vector handoff and turn feedback/delivery accounting |

/// One-shot, RAM-only handoff for an optional query embedding. A turn waits a
/// bounded moment for it (`value(within:)`); a vector that cannot come says
/// why (`unavailable`), so the turn knows it ranks by words alone.
public final class ContextQueryEmbeddingTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContextQueryEmbeddingValue?
    private var failure: String?
    private struct Waiter {
        let continuation: CheckedContinuation<ContextQueryEmbeddingValue?, Never>
        let deadline: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    public init() {}

    /// A ticket that already knows no vector is coming, and why.
    public convenience init(unavailable cause: String) {
        self.init()
        fail(cause)
    }

    /// The vector once it lands, or nil when none is coming or `nanoseconds`
    /// pass first. Read at the start of a turn, a vector still on its way
    /// would always miss it.
    public func value(within nanoseconds: UInt64) async -> ContextQueryEmbeddingValue? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(returning: nil); return }
                    if let value { continuation.resume(returning: value); return }
                    if failure != nil || nanoseconds == 0 { continuation.resume(returning: nil); return }
                    // Register and read under the writer's lock: completion
                    // cannot fall between the initial read and subscription.
                    let deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: nanoseconds) }
                        catch { return }
                        self?.finishWaiter(id)
                    }
                    waiters[id] = Waiter(continuation: continuation, deadline: deadline)
                }
            }
        } onCancel: {
            self.finishWaiter(id)
        }
    }

    private func finishWaiter(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.deadline.cancel()
        waiter?.continuation.resume(returning: nil)
    }

    private func resume(_ waiters: [Waiter], with value: ContextQueryEmbeddingValue?) {
        for waiter in waiters {
            waiter.deadline.cancel()
            waiter.continuation.resume(returning: value)
        }
    }

    /// Why no vector is coming; nil while one may still land.
    public var unavailable: String? { lock.withLock { failure } }

    public func fail(_ cause: String) {
        let pending: [Waiter] = lock.withLock {
            guard value == nil, failure == nil else { return [] }
            failure = cause
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        resume(pending, with: nil)
    }

    public func publish(
        _ embedding: [Float],
        alternate: [Float]? = nil,
        modelFingerprint: String = "legacy-unverified",
        modelID: String
    ) {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return }
        let fingerprint = modelFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return }
        // The other voice is optional enrichment: a malformed second vector
        // drops out rather than costing the turn its query embedding.
        let alternateVector = alternate.flatMap {
            !$0.isEmpty && $0.allSatisfy(\.isFinite) && $0.count == embedding.count ? $0 : nil
        }
        let (pending, landed): ([Waiter], ContextQueryEmbeddingValue?) = lock.withLock {
            guard value == nil, failure == nil else { return ([], nil) }
            value = ContextQueryEmbeddingValue(
                values: embedding,
                alternateValues: alternateVector,
                modelFingerprint: fingerprint,
                modelID: modelID
            )
            let pending = Array(waiters.values)
            waiters.removeAll()
            return (pending, value)
        }
        resume(pending, with: landed)
    }
}

public struct ContextQueryEmbeddingValue: Sendable, Equatable {
    public let values: [Float]
    /// User, 2026-09-06: the SAME question in the other voice ("me" → the
    /// agent's name, "you" → the user's), embedded in the same batch and
    /// therefore in the same vector space as `values`. Selection takes the
    /// better of the two cosines per atom, which is what the legacy recall
    /// lane has always done (`MemoryV2+RecallQueryExpansion`). nil when the
    /// question reads the same in both voices, or when no names are known.
    public let alternateValues: [Float]?
    public let modelFingerprint: String
    /// The embedder's model id (`embedding.json` `model_id`, or the bundled
    /// MiniLM's), read from the same runtime snapshot as the fingerprint. The
    /// selector's semantic floor is per model (`memorySemanticFloors`).
    public let modelID: String

    public init(
        values: [Float],
        alternateValues: [Float]? = nil,
        modelFingerprint: String,
        modelID: String
    ) {
        self.values = values
        self.alternateValues = alternateValues
        self.modelFingerprint = modelFingerprint
        self.modelID = modelID
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
    /// Phase 5 B0: memory atoms she rejected for this kind of message.
    public let suppressedAtomIDs: Set<ContextAtomID>
    public let queryEmbedding: [Float]?
    /// The question in the other voice, same vector space as `queryEmbedding`.
    /// See `ContextQueryEmbeddingValue.alternateValues`.
    public let alternateQueryEmbedding: [Float]?
    public let queryEmbeddingModelFingerprint: String?
    /// See `ContextQueryEmbeddingValue.modelID`.
    public let queryEmbeddingModelID: String?
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
    /// The caller's STABLE system-prompt segment already carries the persona's
    /// required documents verbatim, so the packet must not mirror them a second
    /// time into the per-turn (dynamic, uncached) block.
    ///
    /// Default `false` keeps every other call site — harnesses, evals, direct
    /// context callers — byte-identical to today, where only the kernel's own
    /// documents (SOUL/VOICE + surface guidance) are precovered and the rest of
    /// the persona rides the packet.
    public let stableSegmentCarriesRequiredDocuments: Bool
    /// Nil is the pre-pin transition; [] withholds all generated USER facts.
    public let userMemoryCore: [String]?
    /// Automatic memory disclosure, including correction/identity atoms.
    public let memoryRecallEnabled: Bool
    /// Body length above which the caller's packet renderer replaces an atom's
    /// full text with a lead plus a `context_expand` pointer. The selector uses
    /// it for ONE thing: publishing an expandable pointer for every atom the
    /// renderer will truncate, so the full body stays reachable. `0` (default)
    /// means the caller renders atoms whole and no truncation pointers are
    /// published — today's behavior.
    public let packetAtomExpandThresholdChars: Int
    /// One owner for how many `.memory` atoms the packet may carry. `nil`
    /// (default) leaves the selector's own per-kind quota in charge, which is
    /// what every pre-existing caller got. Identity, correction and instruction
    /// atoms are never counted against it.
    public let memoryAtomRowLimit: Int?

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
        suppressedAtomIDs: Set<ContextAtomID> = [],
        queryEmbedding: [Float]? = nil,
        alternateQueryEmbedding: [Float]? = nil,
        queryEmbeddingModelFingerprint: String? = nil,
        queryEmbeddingModelID: String? = nil,
        allowedPrivacy: Set<ContextPrivacy> = [.localPrivate, .trustedRemote, .publicSafe],
        permissionLabels: Set<String> = [],
        characterBudget: Int = 6_000,
        maximumCharacterBudget: Int? = nil,
        postMandatoryCharacterReserve: Int = 0,
        stableSegmentCarriesRequiredDocuments: Bool = false,
        userMemoryCore: [String]? = nil,
        memoryRecallEnabled: Bool = true,
        packetAtomExpandThresholdChars: Int = 0,
        memoryAtomRowLimit: Int? = nil
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
        self.suppressedAtomIDs = suppressedAtomIDs
        self.queryEmbedding = queryEmbedding.flatMap { vector in
            !vector.isEmpty && vector.allSatisfy(\.isFinite) ? vector : nil
        }
        self.alternateQueryEmbedding = self.queryEmbedding == nil
            ? nil
            : alternateQueryEmbedding.flatMap { vector in
                !vector.isEmpty && vector.allSatisfy(\.isFinite) ? vector : nil
            }
        let fingerprint = queryEmbeddingModelFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.queryEmbeddingModelFingerprint = self.queryEmbedding == nil
            ? nil
            : ((fingerprint?.isEmpty == false) ? fingerprint : nil)
        self.queryEmbeddingModelID = self.queryEmbedding == nil ? nil : queryEmbeddingModelID
        self.allowedPrivacy = allowedPrivacy
        self.permissionLabels = permissionLabels
        self.characterBudget = max(1, characterBudget)
        self.maximumCharacterBudget = max(
            self.characterBudget,
            maximumCharacterBudget ?? self.characterBudget
        )
        self.postMandatoryCharacterReserve = max(0, postMandatoryCharacterReserve)
        self.stableSegmentCarriesRequiredDocuments = stableSegmentCarriesRequiredDocuments
        self.userMemoryCore = userMemoryCore
        self.memoryRecallEnabled = memoryRecallEnabled
        self.packetAtomExpandThresholdChars = max(0, packetAtomExpandThresholdChars)
        self.memoryAtomRowLimit = memoryAtomRowLimit.map { max(0, $0) }
    }
}

/// Exact outcome of the one permitted mandatory-context budget retry.
///
/// A present value proves the coordinator retried only after mandatory atoms
/// exceeded the ordinary packet budget. The granted reserve is the ACTUAL room
/// left after mandatory context at the configured ceiling; it may be smaller
/// than the request when the ceiling itself is the limiting factor.
public struct ContextFlowBudgetExpansion: Sendable, Equatable {
    public let requestedCharacterBudget: Int
    public let effectiveCharacterBudget: Int
    public let maximumCharacterBudget: Int
    public let mandatoryCharacterBudget: Int
    public let grantedPostMandatoryReserve: Int

    public init(
        requestedCharacterBudget: Int,
        effectiveCharacterBudget: Int,
        maximumCharacterBudget: Int,
        mandatoryCharacterBudget: Int,
        grantedPostMandatoryReserve: Int
    ) {
        self.requestedCharacterBudget = requestedCharacterBudget
        self.effectiveCharacterBudget = effectiveCharacterBudget
        self.maximumCharacterBudget = maximumCharacterBudget
        self.mandatoryCharacterBudget = mandatoryCharacterBudget
        self.grantedPostMandatoryReserve = grantedPostMandatoryReserve
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
    /// Non-nil only when the coordinator consumed the bounded mandatory-context
    /// expansion setting for this prepared turn.
    public let budgetExpansion: ContextFlowBudgetExpansion?
    private let feedbackHandler: (@Sendable (
        ContextFeedbackSignal,
        [ContextAtomID],
        [String]
    ) async -> Void)?
    private let feedbackLock = NSLock()
    private var outcomeRecorded = false
    private var deliveryRecorded = false
    private let deliveryHandler: (@Sendable ([ContextPacketItem]) async -> Void)?
    private let verifier: (@Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion)?
    private var memoryRecordProvenance: [String]?
    private var atomMemoryRecords: [ContextAtomID: String] = [:]
    private var listedMemoryRecords: [ContextAtomID: String] = [:]
    private var correctedRecordIDs: Set<String> = []

    public init(
        mode: ContextFlowMode,
        kernel: StablePromptKernel,
        mirror: RequiredDocumentMirror,
        packet: ContextPacket,
        lease: ContextGenerationLease,
        generation: ContextStoredGeneration,
        need: NeedSignal,
        budgetExpansion: ContextFlowBudgetExpansion? = nil,
        deliveryHandler: (@Sendable ([ContextPacketItem]) async -> Void)? = nil,
        feedbackHandler: (@Sendable (
            ContextFeedbackSignal,
            [ContextAtomID],
            [String]
        ) async -> Void)? = nil,
        verifier: (@Sendable ([ContextStoredAtom]) async -> ContextTurnExclusion)? = nil
    ) {
        self.verifier = verifier
        self.mode = mode
        self.kernel = kernel
        self.mirror = mirror
        self.packet = packet
        self.lease = lease
        self.generation = generation
        self.need = need
        self.budgetExpansion = budgetExpansion
        self.feedbackHandler = feedbackHandler
        self.deliveryHandler = deliveryHandler
    }

    /// Expansion re-checks the one atom it opens, as the choice did: an atom its
    /// owner retired or narrowed since the turn began is not opened.
    public func verify(_ pointer: ContextAtomPointer) async -> ContextTurnExclusion {
        guard let verifier else { return ContextTurnExclusion() }
        return await verifier(generation.atoms.filter { $0.draft.id == pointer.atomID })
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

    /// Phase 5 B0: the memory record behind one atom the selection scored,
    /// selected or not, once attached: the why receipt's source, never use.
    public func memoryRecordID(for atomID: ContextAtomID) -> String? {
        feedbackLock.withLock { listedMemoryRecords[atomID] }
    }

    public func attachMemoryRecordProvenance(
        _ recordIDs: [String], atomRecords: [ContextAtomID: String] = [:]
    ) {
        let bounded = Array(Set(recordIDs.filter { !$0.isEmpty })).sorted().prefix(32)
        feedbackLock.withLock {
            guard memoryRecordProvenance == nil else { return }
            memoryRecordProvenance = Array(bounded)
            let selected = Set(packet.receipt.selectedAtomIDs)
            let acceptedRecords = Set(bounded)
            atomMemoryRecords = atomRecords.filter {
                selected.contains($0.key) && acceptedRecords.contains($0.value)
            }
            listedMemoryRecords = atomRecords
        }
    }

    /// Called only AFTER the canonical memory owner confirms a correction.
    /// Exact selected-record attribution, independent of turn completion;
    /// unrelated memories and duplicate tool retries receive no signal.
    public func recordAppliedMemoryCorrection(recordID: String, replacementID: String) async {
        guard !replacementID.isEmpty, replacementID != recordID else { return }
        let atoms: [ContextAtomID] = feedbackLock.withLock {
            let matched = atomMemoryRecords.filter { $0.value == recordID }.map(\.key).sorted()
            guard !matched.isEmpty, correctedRecordIDs.insert(recordID).inserted else { return [] }
            return matched
        }
        guard !atoms.isEmpty else { return }
        await feedbackHandler?(.correction(.contradicts), atoms, ["memory-correction:\(replacementID)"])
    }

    public func recordExpansion(atomID: ContextAtomID, receiptID: String) async {
        await feedbackHandler?(.expansion, [atomID], [receiptID])
    }

    public func recordDelivery() async {
        let first = feedbackLock.withLock {
            let first = !deliveryRecorded
            deliveryRecorded = true
            return first
        }
        if first { await deliveryHandler?(packet.selectedItems) }
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

public enum ContextTurnPreparationError: Error, Equatable, Sendable, LocalizedError {
    case coordinatorNotStarted
    case generationUnavailable
    case kernelUnavailable(surface: ContextSurface, personaIDHint: String?)
    case personaSelectionUnavailable

    public var errorDescription: String? {
        switch self {
        case .coordinatorNotStarted: "Context Flow has not started"
        case .generationUnavailable: "Context Flow has no published context yet; it is building one on its own, so retry shortly"
        case .kernelUnavailable(let surface, let personaID):
            "no persona context is built for \(surface.rawValue) (persona \(personaID ?? "default"))"
        case .personaSelectionUnavailable:
            "The selected persona is still being prepared; it applies on its own, so retry shortly."
        }
    }
}
