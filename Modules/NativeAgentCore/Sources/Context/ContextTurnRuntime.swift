import Foundation
import NativeAgentCore

// Blueprint: | `ContextTurnRuntime.swift` | `ContextPreparedTurn`, request and embedding ticket: generation lease, bounded query-vector handoff (the query, its other voice and a follow-up's own words) and turn feedback/delivery accounting |

/// One-shot handoff for all requested semantic readings. A deadline ends
/// only the wait: the runtime retains the embedding task until settlement.
/// A missing or late result is unavailable, never permission to rank by words.
public final class ContextQueryEmbeddingTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ContextQueryEmbeddingValue, NativeSemanticQueryError>?
    private let ready = ScopedWaiter()

    public init() {}

    public convenience init(unavailable cause: String) {
        self.init()
        fail(cause)
    }

    public func value(within nanoseconds: UInt64) async -> ContextQueryEmbeddingValue? {
        do { return try await checkedValue(within: nanoseconds) }
        catch { return nil }
    }

    /// Checked turn preparation retains failure versus deadline versus cancellation.
    public func checkedValue(within nanoseconds: UInt64) async throws -> ContextQueryEmbeddingValue {
        try Task.checkCancellation()
        if let settled = lock.withLock({ result }) { return try settled.get() }
        let waited = await withTaskGroup(of: Result<ContextQueryEmbeddingValue, NativeSemanticQueryError>.self) { group in
            group.addTask {
                await self.ready.park()
                return self.lock.withLock {
                    self.result ?? .failure(NativeSemanticQueryError(detail: "The semantic wait ended without complete readings."))
                }
            }
            group.addTask {
                do { try await Task.sleep(nanoseconds: nanoseconds) }
                catch { return .failure(NativeSemanticQueryError(detail: "The semantic wait was cancelled.")) }
                // Snapshot at expiry; joining the cancelled parker cannot admit a late value.
                return self.lock.withLock {
                    self.result ?? .failure(NativeSemanticQueryError(detail:
                        "The semantic read is still pending after its bounded wait; no recall selection was made."))
                }
            }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
        try Task.checkCancellation()
        return try waited.get()
    }

    public var unavailable: String? {
        lock.withLock {
            if case .failure(let error) = result { return error.detail }
            return nil
        }
    }

    public func fail(_ cause: String) {
        let settled = lock.withLock {
            guard result == nil else { return false }
            result = .failure(NativeSemanticQueryError(detail: cause))
            return true
        }
        if settled { ready.resume() }
    }

    public func publish(
        _ embedding: [Float],
        alternate: [Float]? = nil,
        ownWords: [[Float]] = [],
        modelFingerprint: String,
        modelID: String
    ) {
        let value = ContextQueryEmbeddingValue(values: embedding, alternateValues: alternate,
            ownWordsValues: ownWords, modelFingerprint: modelFingerprint, modelID: modelID)
        guard value.isUsable else { fail("The semantic reader returned malformed readings."); return }
        let settled = lock.withLock {
            guard result == nil else { return false }
            result = .success(value)
            return true
        }
        if settled { ready.resume() }
    }
}

public struct NativeSemanticQueryError: Error, LocalizedError, Sendable {
    public let detail: String
    public init(detail: String) { self.detail = detail }
    public var errorDescription: String? { "Context semantic read unavailable: " + detail }
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
        self.alternateValues = alternateValues
        self.ownWordsValues = ownWordsValues
        self.modelFingerprint = modelFingerprint
        self.modelID = modelID
    }

    public var isUsable: Bool {
        !modelFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !values.isEmpty
            && ([values] + (alternateValues.map { [$0] } ?? []) + ownWordsValues)
                .allSatisfy { $0.count == values.count && $0.allSatisfy(\.isFinite) }
    }
}

public struct ContextTurnRequest: Sendable, Equatable {
    public let surface: ContextSurface
    public let origin: ContextOriginClass
    public let userMessage: String
    public let personaIDHint: String?
    public let sessionID: String?
    public let recentTurns: [String]
    /// Retained transcript exchanges, oldest first; each holds its user words.
    /// Empty exchanges still count toward rest, independently of delivery.
    public let recentExchanges: [[String]]
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
    /// Every caller explicitly states its document contract.
    public let stableSegmentCarriesRequiredDocuments: Bool
    /// Nil means the USER memory projection is unavailable; [] withholds all generated facts.
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
    /// Shared quota for nonmandatory memory and correction atoms. `nil` uses
    /// the selector's quota. Mandatory atoms bypass it; other kinds do not count.
    public let memoryAtomRowLimit: Int?

    public init(
        surface: ContextSurface,
        origin: ContextOriginClass,
        userMessage: String,
        personaIDHint: String? = nil,
        sessionID: String? = nil,
        recentTurns: [String] = [],
        recentExchanges: [[String]] = [],
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
        stableSegmentCarriesRequiredDocuments: Bool,
        userMemoryCore: [String]?,
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
        self.recentExchanges = recentExchanges
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
    func contextFlowMode() async throws -> ContextFlowMode
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
