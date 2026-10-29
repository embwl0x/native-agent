import Foundation

// Blueprint: | `ContextExpansion.swift` | `ContextExpander.expand`: expands selector-offered pointers without mutating context or deriving authority from their contents |

public enum ContextExpansionError: Error, Equatable, Sendable {
    case invalidCharacterLimit
    case invalidCharacterOffset
    case requestedGenerationMismatch(requested: Int64, actual: Int64)
    case pointerGenerationMismatch(pointer: Int64, generation: Int64)
    case snapshotGenerationMismatch(snapshot: Int64, generation: Int64)
    case snapshotFingerprintMismatch
    case atomNotFound(ContextAtomID)
    case ambiguousAtom(ContextAtomID)
    case sourceNotFound(ContextSourceID)
    case ambiguousSource(ContextSourceID)
    case pointerSourceMismatch(pointer: ContextSourceID, atom: ContextSourceID)
    case pointerSourceHashMismatch(pointer: String, atom: String)
    case pointerKindMismatch(pointer: ContextAtomKind, atom: ContextAtomKind)
    case pointerHeadingPathMismatch
    case pointerSourceRangeMismatch
    case sourceHashMismatch(source: String, atom: String)
    case atomGenerationMismatch(ContextAtomID)
    case sourceGenerationMismatch(ContextSourceID)
    case sourceRemoved(ContextSourceID)
    case atomNotExpandable(policy: ContextInjectionPolicy)
    case sourceInjectionDenied(ContextSourceID)
    case originDenied(ContextOriginClass)
    case sourcePermissionDenied(ContextSourceID)
    case atomPermissionDenied(ContextAtomID)
    case sourceSurfaceDenied(source: ContextSourceID, surface: ContextSurface)
    case atomSurfaceDenied(atom: ContextAtomID, surface: ContextSurface)
    case sourcePrivacyDenied(source: ContextSourceID, privacy: ContextPrivacy)
    case atomPrivacyDenied(atom: ContextAtomID, privacy: ContextPrivacy)
    case deleted(ContextAtomID)
    case tombstoned(ContextAtomID)
    case staleRuntime(ContextAtomID)
    case secretBearing(ContextAtomID)
    case expired(ContextAtomID)
    case invalidSourceUTF8Range(
        atom: ContextAtomID,
        range: ContextSourceRange,
        bodyUTF8ByteCount: Int
    )
}

public struct ContextExpansionReceipt: Codable, Equatable, Sendable {
    public let id: String
    public let generationID: Int64
    public let sourceFingerprint: String
    public let atomID: ContextAtomID
    public let sourceID: ContextSourceID
    public let surface: ContextSurface
    public let origin: ContextOriginClass
    public let sourceRange: ContextSourceRange
    public let characterLimit: Int
    public let characterOffset: Int
    public let fullCharacterCount: Int
    public let returnedCharacterCount: Int
    public let returnedUTF8ByteCount: Int
    public let truncated: Bool
}

public struct ContextExpansionResult: Codable, Equatable, Sendable {
    public let pointer: ContextAtomPointer
    public let text: String
    public let receipt: ContextExpansionReceipt

    public var characterCount: Int { receipt.returnedCharacterCount }
    public var truncated: Bool { receipt.truncated }
    public var nextOffset: Int? {
        receipt.truncated ? receipt.characterOffset + receipt.returnedCharacterCount : nil
    }
}

/// Resolves a selector-issued, on-demand pointer without mutating context state
/// or deriving any new authority from the pointed-to atom.
public struct ContextExpander: Sendable {
    private static let maximumCharacters = 12_000

    public init() {}

    /// - Parameter offeredSelectedItems: selected representations whose
    ///   pointers this turn's packet offered. Empty admits only `.onDemand`.
    public func expand(
        _ pointer: ContextAtomPointer,
        for need: NeedSignal,
        from generation: ContextStoredGeneration,
        pinnedTo snapshot: ContextGenerationSnapshot? = nil,
        maximumCharacters requestedMaximum: Int? = nil,
        offset: Int = 0,
        offeredSelectedItems: [ContextPacketItem] = []
    ) throws -> ContextExpansionResult {
        if let requestedMaximum, requestedMaximum <= 0 {
            throw ContextExpansionError.invalidCharacterLimit
        }
        guard offset >= 0 else {
            throw ContextExpansionError.invalidCharacterOffset
        }
        let characterLimit = min(requestedMaximum ?? Self.maximumCharacters,
                                 Self.maximumCharacters)
        let generationID = generation.generation.id

        if let requested = need.availableGenerationID, requested != generationID {
            throw ContextExpansionError.requestedGenerationMismatch(
                requested: requested,
                actual: generationID
            )
        }
        guard pointer.generationID == generationID else {
            throw ContextExpansionError.pointerGenerationMismatch(
                pointer: pointer.generationID,
                generation: generationID
            )
        }
        if let snapshot {
            guard snapshot.generationID == generationID else {
                throw ContextExpansionError.snapshotGenerationMismatch(
                    snapshot: snapshot.generationID,
                    generation: generationID
                )
            }
            guard snapshot.sourceFingerprint == generation.generation.sourceFingerprint else {
                throw ContextExpansionError.snapshotFingerprintMismatch
            }
        }

        let matchingAtoms = generation.atoms.filter { $0.draft.id == pointer.atomID }
        guard let atom = matchingAtoms.first else {
            throw ContextExpansionError.atomNotFound(pointer.atomID)
        }
        guard matchingAtoms.count == 1 else {
            throw ContextExpansionError.ambiguousAtom(pointer.atomID)
        }
        guard pointer.sourceID == atom.draft.sourceID else {
            throw ContextExpansionError.pointerSourceMismatch(
                pointer: pointer.sourceID,
                atom: atom.draft.sourceID
            )
        }
        guard pointer.sourceHash == atom.draft.sourceHash else {
            throw ContextExpansionError.pointerSourceHashMismatch(
                pointer: pointer.sourceHash,
                atom: atom.draft.sourceHash
            )
        }
        guard pointer.kind == atom.draft.kind else {
            throw ContextExpansionError.pointerKindMismatch(
                pointer: pointer.kind,
                atom: atom.draft.kind
            )
        }
        guard pointer.headingPath == atom.draft.headingPath else {
            throw ContextExpansionError.pointerHeadingPathMismatch
        }
        guard pointer.sourceRange == atom.draft.sourceRange else {
            throw ContextExpansionError.pointerSourceRangeMismatch
        }

        let matchingSources = generation.sources.filter {
            $0.descriptor.id == atom.draft.sourceID
        }
        guard let source = matchingSources.first else {
            throw ContextExpansionError.sourceNotFound(atom.draft.sourceID)
        }
        guard matchingSources.count == 1 else {
            throw ContextExpansionError.ambiguousSource(atom.draft.sourceID)
        }
        guard source.sourceHash == atom.draft.sourceHash else {
            throw ContextExpansionError.sourceHashMismatch(
                source: source.sourceHash,
                atom: atom.draft.sourceHash
            )
        }
        if let failure = ContextSelector.commonEligibilityFailure(
            for: atom, generationID: generationID, source: source, need: need
        ) { throw failure.expansionError }
        // Admission follows the offered representation, not the full body's
        // length: a short summary can omit a body below the render threshold.
        let omittedInPacket = offeredSelectedItems.contains { item in
                item.pointer == pointer
                    && item.isExpandable(thresholdChars: need.packetAtomExpandThresholdChars)
            }
        guard atom.draft.injectionPolicy == .onDemand || omittedInPacket else {
            throw ContextExpansionError.atomNotExpandable(policy: atom.draft.injectionPolicy)
        }

        let (sourceRangeByteCount, overflow) = atom.draft.sourceRange.utf8End
            .subtractingReportingOverflow(atom.draft.sourceRange.utf8Start)
        let bodyUTF8ByteCount = atom.draft.body.utf8.count
        guard !overflow, atom.draft.sourceRange.utf8Start >= 0,
              sourceRangeByteCount == bodyUTF8ByteCount else {
            throw ContextExpansionError.invalidSourceUTF8Range(
                atom: atom.draft.id,
                range: atom.draft.sourceRange,
                bodyUTF8ByteCount: bodyUTF8ByteCount
            )
        }

        let fullCharacterCount = atom.draft.body.count
        guard offset <= fullCharacterCount else {
            throw ContextExpansionError.invalidCharacterOffset
        }
        let text = String(atom.draft.body.dropFirst(offset).prefix(characterLimit))
        let returnedCharacterCount = text.count
        let truncated = offset + returnedCharacterCount < fullCharacterCount
        let receiptID = ContextStableID.digest(parts: [
            "context-expansion-v2",
            need.deterministicFingerprint,
            String(generationID),
            generation.generation.sourceFingerprint,
            pointer.atomID.rawValue,
            pointer.sourceID.rawValue,
            pointer.sourceHash,
            String(pointer.sourceRange.utf8Start),
            String(pointer.sourceRange.utf8End),
            String(characterLimit),
            String(offset),
            String(returnedCharacterCount),
        ])
        let receipt = ContextExpansionReceipt(
            id: receiptID,
            generationID: generationID,
            sourceFingerprint: generation.generation.sourceFingerprint,
            atomID: atom.draft.id,
            sourceID: source.descriptor.id,
            surface: need.surface,
            origin: need.origin,
            sourceRange: atom.draft.sourceRange,
            characterLimit: characterLimit,
            characterOffset: offset,
            fullCharacterCount: fullCharacterCount,
            returnedCharacterCount: returnedCharacterCount,
            returnedUTF8ByteCount: text.utf8.count,
            truncated: truncated
        )
        return ContextExpansionResult(pointer: pointer, text: text, receipt: receipt)
    }

}
