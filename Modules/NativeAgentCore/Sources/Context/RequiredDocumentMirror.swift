import Foundation

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

    /// The persona-slot id PersonaEngine resolves when no custom persona is
    /// active (its resolver's "Default" branch). Context persona ids are SLOT
    /// ids ("canonical", or a custom subdir name like "Agent") — a DIFFERENT
    /// vocabulary from MemoryV2 record persona ids, which are agent names
    /// (MemoryV2Defaults.personaID, legacy display names). The two only meet
    /// at the coordinator's memory-scope gate: the resident default persona
    /// owns the whole MemoryV2 store, so that gate admits every memory scope
    /// for this id, while custom personas see only their own scope + shared.
    /// PersonaEngine cannot import Context, so it keeps its own "canonical"
    /// literal; a conformance test pins the two together.
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

/// The live PersonaCompiler full-document contract. Custom personas may still
/// supply arbitrary declarations; this is the default order for personas that
/// use the standard NativeAgent document set.
public enum RequiredPersonaDocumentKind: String, CaseIterable, Sendable, Codable {
    case soul = "SOUL.md"
    case voice = "VOICE.md"
    case user = "USER.md"
    case growth = "GROWTH.md"
    case memory = "MEMORY.md"
    case agents = "AGENTS.md"

    public var id: RequiredDocumentID {
        RequiredDocumentID(rawValue: rawValue)
    }

    public var canonicalOrder: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }

    public var isOptional: Bool {
        self == .memory
    }

    public static func defaultOrder(includeMemory: Bool) -> [Self] {
        includeMemory ? allCases : allCases.filter { !$0.isOptional }
    }
}

public enum RequiredDocumentMirrorError: Error, Equatable, Sendable {
    case emptyDocumentID
    case negativeCanonicalOrder(documentID: RequiredDocumentID)
    case emptySourceHash(documentID: RequiredDocumentID)
    case negativeTokenCount(documentID: RequiredDocumentID)
    case negativeKernelTokenCount
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
    public let tokenCount: Int
    public let characterCount: Int
    public let utf8ByteCount: Int
    public let logicalByteCount: Int

    public init(
        id: RequiredDocumentID,
        canonicalOrder: Int,
        sourceHash: String,
        text: String,
        tokenCount: Int
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
        guard tokenCount >= 0 else {
            throw RequiredDocumentMirrorError.negativeTokenCount(documentID: id)
        }

        self.id = id
        self.canonicalOrder = canonicalOrder
        self.sourceHash = sourceHash
        self.text = text
        self.tokenCount = tokenCount
        self.characterCount = text.count
        self.utf8ByteCount = text.utf8.count
        self.logicalByteCount = try ContextLogicalByteAccounting.checkedSum(
            [48, id.rawValue.utf8.count, sourceHash.utf8.count, text.utf8.count],
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
    }

    public init(
        kind: RequiredPersonaDocumentKind,
        sourceHash: String,
        text: String,
        tokenCount: Int
    ) throws {
        try self.init(
            id: kind.id,
            canonicalOrder: kind.canonicalOrder,
            sourceHash: sourceHash,
            text: text,
            tokenCount: tokenCount
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

/// Pre-rendered stable prompt bytes. Dynamic turn, runtime, and organism state
/// must remain outside this value.
public struct StablePromptKernel: Sendable, Equatable {
    public let key: StablePromptKernelKey
    public let renderedPrompt: String
    public let includedDocumentIDs: [RequiredDocumentID]
    public let tokenCount: Int
    public let characterCount: Int
    public let utf8ByteCount: Int
    public let logicalByteCount: Int

    public init(
        key: StablePromptKernelKey,
        renderedPrompt: String,
        includedDocumentIDs: [RequiredDocumentID],
        tokenCount: Int
    ) throws {
        guard tokenCount >= 0 else {
            throw RequiredDocumentMirrorError.negativeKernelTokenCount
        }

        self.key = key
        self.renderedPrompt = renderedPrompt
        self.includedDocumentIDs = includedDocumentIDs
        self.tokenCount = tokenCount
        self.characterCount = renderedPrompt.count
        self.utf8ByteCount = renderedPrompt.utf8.count
        let includedIDBytes = try ContextLogicalByteAccounting.checkedSum(
            includedDocumentIDs.map { $0.rawValue.utf8.count },
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        self.logicalByteCount = try ContextLogicalByteAccounting.checkedSum(
            [
                48,
                key.personaID.rawValue.utf8.count,
                key.surfaceVariant.rawValue.utf8.count,
                key.sourceFingerprint.utf8.count,
                renderedPrompt.utf8.count,
                includedIDBytes,
            ],
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
    }
}

/// Exact required documents and all valid stable prompt projections for one
/// persona/source generation. Documents are always stored in canonical order.
public struct RequiredDocumentMirror: Sendable, Equatable {
    public let personaID: ContextPersonaID
    public let sourceFingerprint: String
    public let documents: [RequiredDocument]
    public let kernels: [StablePromptKernelKey: StablePromptKernel]
    public let characterCount: Int
    public let tokenCount: Int
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
        var kernelsByKey: [StablePromptKernelKey: StablePromptKernel] = [:]
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
            guard kernelsByKey.updateValue(kernel, forKey: kernel.key) == nil else {
                throw RequiredDocumentMirrorError.duplicateKernelKey(kernel.key)
            }
        }

        self.personaID = personaID
        self.sourceFingerprint = sourceFingerprint
        self.documents = orderedDocuments
        self.kernels = kernelsByKey
        self.characterCount = try ContextLogicalByteAccounting.checkedSum(
            orderedDocuments.map(\.characterCount),
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
        self.tokenCount = try ContextLogicalByteAccounting.checkedSum(
            orderedDocuments.map(\.tokenCount),
            overflowError: RequiredDocumentMirrorError.logicalByteOverflow
        )
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
        guard let key = try? StablePromptKernelKey(
            personaID: personaID,
            surfaceVariant: surfaceVariant,
            sourceFingerprint: sourceFingerprint
        ) else {
            return nil
        }
        return kernels[key]
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
