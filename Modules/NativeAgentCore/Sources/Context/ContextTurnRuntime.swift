import Foundation
import NativeAgentCore

// Blueprint: | `ContextTurnRuntime.swift` | `ContextPreparedTurn`, request and embedding ticket: generation lease, bounded query-vector handoff (the query, its other voice and a follow-up's own words) and turn feedback/delivery accounting |

/// One-shot, RAM-only handoff for an optional query embedding. A turn waits a
/// bounded moment for it (`value(within:)`); a vector that cannot come says
/// why (`unavailable`), so the turn knows it ranks by words alone.
///
/// The primary reading lands first (`publish(…, readingsFollow: true)`)
/// and the message's further readings attach after it (`attachReadings`), so
/// the query vector never waits on them. A waiter takes the value once every
/// reading has landed, or, at its deadline, whatever has: the primary alone
/// when the others are late, and the selector's bar counts only the readings
/// it got.
public final class ContextQueryEmbeddingTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContextQueryEmbeddingValue?
    /// False between a primary published with readings to follow and their
    /// arrival (or their failure).
    private var readingsComplete = true
    private var failure: String?
    private let ready = ScopedWaiter()

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
        guard !Task.isCancelled else { return nil }
        let initial = lock.withLock { (failure != nil || (value != nil && readingsComplete) || nanoseconds == 0, value) }
        if initial.0 { return initial.1 }
        return await withTaskGroup(of: ContextQueryEmbeddingValue?.self) { group in
            group.addTask {
                await self.ready.park()
                return self.lock.withLock { Task.isCancelled ? nil : self.value }
            }
            group.addTask {
                do { try await Task.sleep(nanoseconds: nanoseconds) }
                catch { return nil }
                // Capture at the deadline, before the race joins either branch.
                return self.lock.withLock { Task.isCancelled ? nil : self.value }
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return Task.isCancelled ? nil : first
        }
    }

    /// Why no vector is coming; nil while one may still land.
    public var unavailable: String? { lock.withLock { failure } }

    /// Nothing more is coming. Before the primary reading: no vector, and
    /// why. After it, with readings still to follow: the primary alone.
    public func fail(_ cause: String) {
        let completed = lock.withLock {
            if value != nil {
                guard !readingsComplete else { return false }
                readingsComplete = true
            } else {
                guard failure == nil else { return false }
                failure = cause
            }
            return true
        }
        if completed { ready.resume() }
    }

    public func publish(
        _ embedding: [Float],
        alternate: [Float]? = nil,
        ownWords: [[Float]] = [],
        modelFingerprint: String = "legacy-unverified",
        modelID: String,
        readingsFollow: Bool = false
    ) {
        guard !embedding.isEmpty, embedding.allSatisfy(\.isFinite) else { return }
        let fingerprint = modelFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fingerprint.isEmpty else { return }
        let completed = lock.withLock {
            guard value == nil, failure == nil else { return false }
            value = ContextQueryEmbeddingValue(
                values: embedding,
                alternateValues: alternate,
                ownWordsValues: ownWords,
                modelFingerprint: fingerprint,
                modelID: modelID
            )
            readingsComplete = !readingsFollow
            return readingsComplete
        }
        if completed { ready.resume() }
    }

    /// The further readings of a primary published with `readingsFollow`.
    /// Malformed ones drop out; empty (they failed) completes the value with
    /// the primary alone. Either way, every waiter is released.
    public func attachReadings(_ readings: ContextQueryEmbeddingValue) {
        let completed = lock.withLock {
            guard var current = value, !readingsComplete else { return false }
            if readings.values.count == current.values.count {
                current.alternateValues = current.alternateValues ?? readings.alternateValues
                current.ownWordsValues += readings.ownWordsValues
            }
            value = current
            readingsComplete = true
            return true
        }
        if completed { ready.resume() }
    }
}

public struct ContextQueryEmbeddingValue: Sendable, Equatable {
    public let values: [Float]
    /// The question's other voice ("me" → agent, "you" → user), embedded with `values`.
    /// Selection takes the better cosine; nil when voices match or names are unknown.
    public fileprivate(set) var alternateValues: [Float]?
    /// A follow-up's query is its words in the context of the recent
    /// turns; these are its OWN words (and their other voice), embedded in the
    /// same batch. Each is a separate reading the memory lane scores on its
    /// own (`ContextSelector.memoryRelevance`): a self-contained follow-up
    /// ("…headphones… connect over Bluetooth?") kept its subject only as a
    /// fifth of a window filled by the previous exchange. Empty when the
    /// query is the message itself.
    public fileprivate(set) var ownWordsValues: [[Float]]
    public let modelFingerprint: String
    /// The embedder's model id (`embedding.json` `model_id`), read from the
    /// same runtime snapshot as the fingerprint. The
    /// selector's meaning scale is per model (`memorySemanticFloors`).
    public let modelID: String

    public init(
        values: [Float],
        alternateValues: [Float]? = nil,
        ownWordsValues: [[Float]] = [],
        modelFingerprint: String,
        modelID: String
    ) {
        self.values = values
        // Malformed enrichment never costs the primary reading.
        func usable(_ vector: [Float]) -> Bool {
            !vector.isEmpty && vector.allSatisfy(\.isFinite) && vector.count == values.count
        }
        self.alternateValues = alternateValues.flatMap { usable($0) ? $0 : nil }
        self.ownWordsValues = ownWordsValues.filter(usable)
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
    /// Memory atoms she rejected for this kind of message.
    public let suppressedAtomIDs: Set<ContextAtomID>
    public let queryEmbedding: ContextQueryEmbeddingValue?
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
        suppressedAtomIDs: Set<ContextAtomID> = [],
        queryEmbedding: ContextQueryEmbeddingValue? = nil,
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
        self.suppressedAtomIDs = suppressedAtomIDs
        self.queryEmbedding = queryEmbedding
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

    /// The projection owner resolves selected memory/correction locators in the leased generation to record IDs.
    /// IDs attach once before sharing; unattached means empty; packets, fingerprints and receipts stay identity-free.
    public var selectedMemoryRecordIDs: [String] {
        feedbackLock.withLock { memoryRecordProvenance ?? [] }
    }

    /// The memory record behind one atom the selection scored,
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
    /// `ownWords`: the message alone when `text` is it in the context of the
    /// recent turns (a follow-up); nil when `text` is the message.
    func beginQueryEmbedding(_ text: String, ownWords: String?) async -> ContextQueryEmbeddingTicket?
    func prepareContextTurn(_ request: ContextTurnRequest) async throws -> ContextPreparedTurn
}

public extension ContextTurnPreparing {
    func beginQueryEmbedding(_ text: String, ownWords: String?) async -> ContextQueryEmbeddingTicket? {
        _ = (text, ownWords)
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
