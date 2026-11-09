import Foundation
import NativeAgentCore

// Blueprint: | `ContextTurnRuntime.swift` | `ContextPreparedTurn`: turn leases, query handoff and delivery |

/// One-shot handoff for all requested semantic readings. A deadline ends only the wait: the runtime retains the embedding task until settlement. A missing or
/// late result is unavailable, never permission to rank by words.
public final class ContextQueryEmbeddingTicket: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<ContextQueryEmbeddingValue, NativeSemanticQueryError>?
    private let ready = ScopedWaiter()

    public init() {}

    public convenience init(unavailable cause: String, repairRequired: Bool = true) {
        self.init()
        fail(cause, repairRequired: repairRequired)
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
                        "The semantic read is still pending after its bounded wait; no recall selection was made.",
                        repairRequired: false))
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

    public func fail(_ cause: String, repairRequired: Bool = true) {
        let settled = lock.withLock {
            guard result == nil else { return false }
            result = .failure(NativeSemanticQueryError(detail: cause, repairRequired: repairRequired))
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
    /// A pending read or cold model is not evidence of a fault. The reader classifies its own cause.
    public let repairRequired: Bool
    public init(detail: String, repairRequired: Bool = true) {
        self.detail = detail
        self.repairRequired = repairRequired
    }
    public var errorDescription: String? { "Context semantic read unavailable: " + detail }
}

public struct ContextQueryEmbeddingValue: Sendable, Equatable {
    public let values: [Float]
    /// Embed both voices together and keep the better cosine; matching voices or unknown names supply no alternate reading.
    public fileprivate(set) var alternateValues: [Float]?
    /// Score a follow-up's own words and their other voice separately from its contextual query so prior exchanges cannot dilute a self-contained subject.
    /// Empty when the query is the message itself.
    public fileprivate(set) var ownWordsValues: [[Float]]
    public let modelFingerprint: String
    /// Read model ID and fingerprint from one runtime snapshot so selection uses the matching semantic floor.
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
    /// Retained transcript exchanges, oldest first; each holds its user words. Empty exchanges still count toward rest, independently of delivery.
    public let recentExchanges: [[String]]
    public let activeTask: String?
    public let unresolvedQuestion: String?
    public let goal: String?
    public let predictedToolGroups: Set<String>
    public let contextualTerms: Set<String>
    public let cognitiveActivation: [ContextAtomID: Double]
    public let suppressedAtomIDs: Set<ContextAtomID>
    public let queryEmbedding: ContextQueryEmbeddingValue?
    public let allowedPrivacy: Set<ContextPrivacy>
    public let permissionLabels: Set<String>
    public let characterBudget: Int
    /// Retry only `mandatoryBudgetExceeded`, within this ceiling; default to the ordinary budget for strict callers.
    public let maximumCharacterBudget: Int
    /// Reserve ranked-context room so accumulated mandatory corrections cannot crowd out relevant memory and tasks.
    public let postMandatoryCharacterReserve: Int
    /// Every caller declares which persona documents its stable prompt carries verbatim so dynamic context does not duplicate them.
    public let stableSegmentCarriesRequiredDocuments: Bool
    /// The ordered person picture; [] withholds generated facts when recall is disabled or a separately reported read is unavailable.
    public let userMemoryCore: [String]
    public let memoryRecallEnabled: Bool
    /// Publish expansion pointers for every body the caller truncates; zero means whole-body rendering without truncation pointers.
    public let packetAtomExpandThresholdChars: Int
    /// Shared quota for nonmandatory memory and correction atoms. `nil` uses the selector's quota. Mandatory atoms bypass it; other kinds do not count.
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
        userMemoryCore: [String],
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

/// Only mandatory overflow permits expansion; record actual reserved room because the ceiling may grant less than requested.
public struct ContextFlowBudgetExpansion: Sendable, Equatable {
    public let requestedCharacterBudget: Int
    public let effectiveCharacterBudget: Int
    public let maximumCharacterBudget: Int
    public let mandatoryCharacterBudget: Int
    public let grantedPostMandatoryReserve: Int
}

/// Owns the immutable generation lease for the complete provider/tool loop. Copying this reference into derived TurnContext values preserves the pin.
public final class ContextPreparedTurn: @unchecked Sendable {
    public let mode: ContextFlowMode
    public let kernel: StablePromptKernel
    public let mirror: RequiredDocumentMirror
    public let packet: ContextPacket
    public let lease: ContextGenerationLease
    public let generation: ContextStoredGeneration
    public let need: NeedSignal
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

    /// Expansion re-checks the one atom it opens, as the choice did: an atom its owner retired or narrowed since the turn began is not opened.
    public func verify(_ pointer: ContextAtomPointer) async -> ContextTurnExclusion {
        guard let verifier else { return ContextTurnExclusion() }
        return await verifier(generation.atoms.filter { $0.draft.id == pointer.atomID })
    }

    /// Resolve record IDs through the projection owner in the leased generation; attach once before sharing and keep packets, fingerprints and receipts
    /// identity-free.
    public var selectedMemoryRecordIDs: [String] {
        feedbackLock.withLock { memoryRecordProvenance ?? [] }
    }

    /// Scored records explain selection receipts, never memory use.
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

    /// Signal only after canonical confirmation, with exact selected-record attribution; completion, unrelated memories and duplicate retries grant no credit.
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
    /// `ownWords`: the message alone when `text` is it in the context of the recent turns (a follow-up); nil when `text` is the message.
    func beginQueryEmbedding(_ text: String, ownWords: String?, turn: Turn) async -> ContextQueryEmbeddingTicket?
    func prepareContextTurn(_ request: ContextTurnRequest, turn: Turn) async throws -> ContextPreparedTurn
}

public extension ContextTurnPreparing {
    func beginQueryEmbedding(_ text: String, ownWords: String?, turn: Turn) async -> ContextQueryEmbeddingTicket? {
        _ = (text, ownWords, turn)
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
