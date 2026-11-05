import Foundation

// Blueprint: | `RequiredDocumentMirror.swift` | `RequiredDocumentMirror`, `StablePromptKernel`: required document and stable-prompt ownership |

public struct RequiredDocumentID: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextPersonaID: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Context persona IDs identify slots; MemoryV2 IDs identify agents. Memory is shared across slots under record disclosure, never slot isolation.
    /// PersonaEngine cannot import Context, so it owns the same `canonical` literal.
    public static let resident = ContextPersonaID(rawValue: "canonical")

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ContextSurfaceVariant: RawRepresentable, Hashable, Comparable, Sendable, Codable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Precoverage and stable-prefix rendering must share source identity, document lookup and surface permission checks so naming conventions cannot split their
/// policy.
public enum ContextPersonaSourceNaming {
    public static let owner = "nativeagent.persona"

    public static func locatorPrefix(for personaID: ContextPersonaID) -> String {
        "persona/\(personaID.rawValue)/"
    }

}

public enum RequiredDocumentMirrorError: Error, Equatable, Sendable {
    case emptyDocumentID
    case negativeCanonicalOrder(documentID: RequiredDocumentID)
    case emptySourceHash(documentID: RequiredDocumentID)
    case emptyPersonaID
    case emptySourceFingerprint
    case noRequiredDocuments
    case duplicateDocumentID(RequiredDocumentID)
    case duplicateCanonicalOrder(Int)
    case emptySurfaceVariant
    case kernelPersonaMismatch(expected: ContextPersonaID, actual: ContextPersonaID)
    case kernelFingerprintMismatch(expected: String, actual: String)
    case kernelDocumentCoverageMismatch(surface: ContextSurfaceVariant)
    case duplicateKernelKey(StablePromptKernelKey)
    case logicalByteOverflow
}

/// An exact, immutable RAM copy of one canonical document required in full.
public struct RequiredDocument: Sendable, Equatable {
    public let id: RequiredDocumentID
    public let canonicalOrder: Int
    public let sourceHash: String
    public let text: String
    public let logicalByteCount: Int
    /// Carry source provenance and permitted surfaces with document bytes so stable-prefix permission cannot drift with locator naming. Nil is unproven and
    /// unavailable to that prefix; packet admission still applies its own surface rules.
    public let sourceID: ContextSourceID?
    public let permittedSurfaces: Set<ContextSurface>?

    public var hasSurfaceProvenance: Bool {
        sourceID != nil && permittedSurfaces != nil
    }

    /// Unproven provenance denies prefix admission: withholding leaves the packet route available, while admission would bypass permission.
    public func permitsStablePrefix(on surface: ContextSurface) -> Bool {
        guard let permittedSurfaces, sourceID != nil else { return false }
        return permittedSurfaces.contains(surface)
    }

    public init(
        id: RequiredDocumentID,
        canonicalOrder: Int,
        sourceHash: String,
        text: String,
        sourceID: ContextSourceID? = nil,
        permittedSurfaces: Set<ContextSurface>? = nil
    ) throws {
        guard !id.rawValue.isEmpty else {
            throw RequiredDocumentMirrorError.emptyDocumentID
        }
        guard canonicalOrder >= 0 else {
            throw RequiredDocumentMirrorError.negativeCanonicalOrder(documentID: id)
        }
        guard !sourceHash.isEmpty else {
            throw RequiredDocumentMirrorError.emptySourceHash(documentID: id)
        }
        self.id = id
        self.canonicalOrder = canonicalOrder
        self.sourceHash = sourceHash
        self.text = text
        self.sourceID = sourceID
        self.permittedSurfaces = permittedSurfaces
        // Absent provenance contributes zero logical bytes.
        let provenanceBytes = try ContextLogicalByteAccounting.checkedSum(
            [sourceID?.rawValue.utf8.count ?? 0]
                + (permittedSurfaces?.map { $0.rawValue.utf8.count } ?? []),
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        self.logicalByteCount = try ContextLogicalByteAccounting.checkedSum(
            [
                48,
                id.rawValue.utf8.count,
                sourceHash.utf8.count,
                text.utf8.count,
                provenanceBytes,
            ],
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
    }

}

public struct StablePromptKernelKey: Hashable, Comparable, Sendable {
    public let personaID: ContextPersonaID
    public let surfaceVariant: ContextSurfaceVariant
    public let sourceFingerprint: String

    public init(
        personaID: ContextPersonaID,
        surfaceVariant: ContextSurfaceVariant,
        sourceFingerprint: String
    ) throws {
        guard !personaID.rawValue.isEmpty else {
            throw RequiredDocumentMirrorError.emptyPersonaID
        }
        guard !surfaceVariant.rawValue.isEmpty else {
            throw RequiredDocumentMirrorError.emptySurfaceVariant
        }
        guard !sourceFingerprint.isEmpty else {
            throw RequiredDocumentMirrorError.emptySourceFingerprint
        }
        self.personaID = personaID
        self.surfaceVariant = surfaceVariant
        self.sourceFingerprint = sourceFingerprint
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.personaID != rhs.personaID { return lhs.personaID < rhs.personaID }
        if lhs.surfaceVariant != rhs.surfaceVariant { return lhs.surfaceVariant < rhs.surfaceVariant }
        return lhs.sourceFingerprint < rhs.sourceFingerprint
    }
}

/// Pre-rendered stable prompt bytes. Dynamic turn, runtime, and organism state must remain outside this value.
public struct StablePromptKernel: Sendable, Equatable {
    public let key: StablePromptKernelKey
    /// Selection captured by the builder of this published kernel, not the preference observed after asynchronous compilation. Nil means default.
    public let requestedPersonaOverride: String?
    public let renderedPrompt: String
    /// Surface instructions follow the permission-checked documents.
    public let surfaceGuidance: String
    public let includedDocumentIDs: [RequiredDocumentID]
    public let logicalByteCount: Int

    public init(
        key: StablePromptKernelKey,
        renderedPrompt: String,
        includedDocumentIDs: [RequiredDocumentID],
        requestedPersonaOverride: String? = nil,
        surfaceGuidance: String = ""
    ) throws {
        self.key = key
        self.requestedPersonaOverride = requestedPersonaOverride
        self.renderedPrompt = renderedPrompt
        self.surfaceGuidance = surfaceGuidance
        self.includedDocumentIDs = includedDocumentIDs
        let includedIDBytes = try ContextLogicalByteAccounting.checkedSum(
            includedDocumentIDs.map { $0.rawValue.utf8.count },
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        self.logicalByteCount = try ContextLogicalByteAccounting.checkedSum(
            [
                64,
                key.personaID.rawValue.utf8.count,
                key.surfaceVariant.rawValue.utf8.count,
                key.sourceFingerprint.utf8.count,
                renderedPrompt.utf8.count,
                surfaceGuidance.utf8.count,
                includedIDBytes,
                requestedPersonaOverride?.utf8.count ?? 0,
            ],
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
    }
}

/// Store required documents in canonical order within one persona/source generation.
public struct RequiredDocumentMirror: Sendable, Equatable {
    public let personaID: ContextPersonaID
    public let sourceFingerprint: String
    public let documents: [RequiredDocument]
    public let kernels: [ContextSurfaceVariant: StablePromptKernel]
    public let logicalByteCount: Int

    public init(
        personaID: ContextPersonaID,
        sourceFingerprint: String,
        documents: [RequiredDocument],
        kernels: [StablePromptKernel] = []
    ) throws {
        guard !personaID.rawValue.isEmpty else {
            throw RequiredDocumentMirrorError.emptyPersonaID
        }
        guard !sourceFingerprint.isEmpty else {
            throw RequiredDocumentMirrorError.emptySourceFingerprint
        }
        guard !documents.isEmpty else {
            throw RequiredDocumentMirrorError.noRequiredDocuments
        }

        let orderedDocuments = documents.sorted {
            if $0.canonicalOrder != $1.canonicalOrder {
                return $0.canonicalOrder < $1.canonicalOrder
            }
            return $0.id < $1.id
        }
        var documentIDs = Set<RequiredDocumentID>()
        var orders = Set<Int>()
        for document in orderedDocuments {
            guard documentIDs.insert(document.id).inserted else {
                throw RequiredDocumentMirrorError.duplicateDocumentID(document.id)
            }
            guard orders.insert(document.canonicalOrder).inserted else {
                throw RequiredDocumentMirrorError.duplicateCanonicalOrder(document.canonicalOrder)
            }
        }

        let canonicalIDs = orderedDocuments.map(\.id)
        var kernelsBySurface: [ContextSurfaceVariant: StablePromptKernel] = [:]
        for kernel in kernels {
            guard kernel.key.personaID == personaID else {
                throw RequiredDocumentMirrorError.kernelPersonaMismatch(
                    expected: personaID,
                    actual: kernel.key.personaID
                )
            }
            guard kernel.key.sourceFingerprint == sourceFingerprint else {
                throw RequiredDocumentMirrorError.kernelFingerprintMismatch(
                    expected: sourceFingerprint,
                    actual: kernel.key.sourceFingerprint
                )
            }
            let includedSet = Set(kernel.includedDocumentIDs)
            let canonicalProjection = canonicalIDs.filter(includedSet.contains)
            guard !kernel.includedDocumentIDs.isEmpty,
                  includedSet.count == kernel.includedDocumentIDs.count,
                  canonicalProjection == kernel.includedDocumentIDs else {
                throw RequiredDocumentMirrorError.kernelDocumentCoverageMismatch(
                    surface: kernel.key.surfaceVariant
                )
            }
            guard kernelsBySurface.updateValue(kernel, forKey: kernel.key.surfaceVariant) == nil else {
                throw RequiredDocumentMirrorError.duplicateKernelKey(kernel.key)
            }
        }

        self.personaID = personaID
        self.sourceFingerprint = sourceFingerprint
        self.documents = orderedDocuments
        self.kernels = kernelsBySurface
        let documentBytes = try ContextLogicalByteAccounting.checkedSum(
            orderedDocuments.map(\.logicalByteCount),
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        let kernelBytes = try ContextLogicalByteAccounting.checkedSum(
            kernels.map(\.logicalByteCount),
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        self.logicalByteCount = try ContextLogicalByteAccounting.checkedSum(
            [
                64,
                personaID.rawValue.utf8.count,
                sourceFingerprint.utf8.count,
                documentBytes,
                kernelBytes,
            ],
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
    }

    public func document(id: RequiredDocumentID) -> RequiredDocument? {
        documents.first { $0.id == id }
    }

    public func kernel(for surfaceVariant: ContextSurfaceVariant) -> StablePromptKernel? {
        kernels[surfaceVariant]
    }
}

enum ContextLogicalByteAccounting {
    static func checkedSum<E: Error>(_ values: [Int], overflowError: @autoclosure () -> E) throws -> Int {
        var total = 0
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else { throw overflowError() }
            total = addition.partialValue
        }
        return total
    }
}
