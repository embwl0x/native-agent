import Foundation

public struct ContextExpansionConfiguration: Equatable, Sendable {
    public let maximumCharacters: Int

    public init(maximumCharacters: Int = 12_000) {
        self.maximumCharacters = max(1, maximumCharacters)
    }
}

public enum ContextExpansionError: Error, Equatable, Sendable {
    case invalidCharacterLimit
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
}

/// Resolves a selector-issued, on-demand pointer without mutating context state
/// or deriving any new authority from the pointed-to atom.
public struct ContextExpander: Sendable {
    public let configuration: ContextExpansionConfiguration

    public init(configuration: ContextExpansionConfiguration = .init()) {
        self.configuration = configuration
    }

    public func expand(
        _ pointer: ContextAtomPointer,
        for need: NeedSignal,
        from generation: ContextStoredGeneration,
        pinnedTo snapshot: ContextGenerationSnapshot? = nil,
        maximumCharacters requestedMaximum: Int? = nil
    ) throws -> ContextExpansionResult {
        if let requestedMaximum, requestedMaximum <= 0 {
            throw ContextExpansionError.invalidCharacterLimit
        }
        let characterLimit = min(requestedMaximum ?? configuration.maximumCharacters,
                                 configuration.maximumCharacters)
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
        guard Self.isValidAt(generationID, from: atom.validFromGeneration,
                             through: atom.validToGeneration) else {
            throw ContextExpansionError.atomGenerationMismatch(atom.draft.id)
        }
        guard Self.isValidAt(generationID, from: source.validFromGeneration,
                             through: source.validToGeneration) else {
            throw ContextExpansionError.sourceGenerationMismatch(source.descriptor.id)
        }
        guard source.health != .removed else {
            throw ContextExpansionError.sourceRemoved(source.descriptor.id)
        }
        guard atom.draft.injectionPolicy == .onDemand else {
            throw ContextExpansionError.atomNotExpandable(policy: atom.draft.injectionPolicy)
        }
        guard source.descriptor.injectionPolicy != .neverInject else {
            throw ContextExpansionError.sourceInjectionDenied(source.descriptor.id)
        }

        if need.deletedAtomIDs.contains(atom.draft.id) {
            throw ContextExpansionError.deleted(atom.draft.id)
        }
        if need.tombstonedAtomIDs.contains(atom.draft.id) {
            throw ContextExpansionError.tombstoned(atom.draft.id)
        }
        if need.staleRuntimeAtomIDs.contains(atom.draft.id) {
            throw ContextExpansionError.staleRuntime(atom.draft.id)
        }
        if need.secretBearingAtomIDs.contains(atom.draft.id) {
            throw ContextExpansionError.secretBearing(atom.draft.id)
        }
        guard need.authorization.allowedOrigins.contains(need.origin) else {
            throw ContextExpansionError.originDenied(need.origin)
        }
        guard need.authorization.allowedSourceIDs.contains(source.descriptor.id) else {
            throw ContextExpansionError.sourcePermissionDenied(source.descriptor.id)
        }
        if let allowedAtomIDs = need.authorization.allowedAtomIDs,
           !allowedAtomIDs.contains(atom.draft.id) {
            throw ContextExpansionError.atomPermissionDenied(atom.draft.id)
        }
        guard source.descriptor.permittedSurfaces.contains(need.surface) else {
            throw ContextExpansionError.sourceSurfaceDenied(
                source: source.descriptor.id,
                surface: need.surface
            )
        }
        guard atom.draft.permittedSurfaces.contains(need.surface) else {
            throw ContextExpansionError.atomSurfaceDenied(
                atom: atom.draft.id,
                surface: need.surface
            )
        }
        guard need.authorization.allowedPrivacy.contains(source.descriptor.privacy) else {
            throw ContextExpansionError.sourcePrivacyDenied(
                source: source.descriptor.id,
                privacy: source.descriptor.privacy
            )
        }
        guard need.authorization.allowedPrivacy.contains(atom.draft.privacy) else {
            throw ContextExpansionError.atomPrivacyDenied(
                atom: atom.draft.id,
                privacy: atom.draft.privacy
            )
        }
        guard !atom.draft.freshness.isExpired(at: need.evaluationTime) else {
            throw ContextExpansionError.expired(atom.draft.id)
        }

        let sourceRangeByteCount = atom.draft.sourceRange.utf8End
            - atom.draft.sourceRange.utf8Start
        let bodyUTF8ByteCount = atom.draft.body.utf8.count
        guard sourceRangeByteCount == bodyUTF8ByteCount else {
            throw ContextExpansionError.invalidSourceUTF8Range(
                atom: atom.draft.id,
                range: atom.draft.sourceRange,
                bodyUTF8ByteCount: bodyUTF8ByteCount
            )
        }

        let fullCharacterCount = atom.draft.body.count
        let text = String(atom.draft.body.prefix(characterLimit))
        let returnedCharacterCount = text.count
        let truncated = returnedCharacterCount < fullCharacterCount
        let receiptID = ContextStableID.digest(parts: [
            "context-expansion-v1",
            need.deterministicFingerprint,
            String(generationID),
            generation.generation.sourceFingerprint,
            pointer.atomID.rawValue,
            pointer.sourceID.rawValue,
            pointer.sourceHash,
            String(pointer.sourceRange.utf8Start),
            String(pointer.sourceRange.utf8End),
            String(characterLimit),
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
            fullCharacterCount: fullCharacterCount,
            returnedCharacterCount: returnedCharacterCount,
            returnedUTF8ByteCount: text.utf8.count,
            truncated: truncated
        )
        return ContextExpansionResult(pointer: pointer, text: text, receipt: receipt)
    }

    private static func isValidAt(
        _ generationID: Int64,
        from validFrom: Int64,
        through validTo: Int64?
    ) -> Bool {
        validFrom <= generationID && (validTo.map { $0 >= generationID } ?? true)
    }
}
