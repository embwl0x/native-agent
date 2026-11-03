import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine.swift` | `SwiftNativePersonaEngine`: checked read-only canonical document listing and shared reads of authored contents; `PersonaSelection`: sole installation-wide selection for every door |

/// One installation-wide persona selection for every conversation door.
/// Retains the existing preference key so the Mac's saved pick survives upgrades.
public enum PersonaSelection {
    public static func current(defaults: UserDefaults = .standard) -> String? {
        let name = defaults.string(forKey: "chatPersona")?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    public static func select(_ name: String, defaults: UserDefaults = .standard) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty { defaults.removeObject(forKey: "chatPersona") }
        else { defaults.set(clean, forKey: "chatPersona") }
    }
}

// MARK: - PersonaRoot resolution contract
//
// One rule, owned by `PersistenceCore.defaultPersonaRoot`: a checkout's
// `data/` (every dev install) keeps its persona at `<repo>/persona`; any other
// data root holds it at `<dataRoot>/persona`.

// MARK: - Errors

public enum PersonaEngineError: Error, LocalizedError {
    case rootUnreadable(reason: String)
    case missingRequiredDocument(path: String)
    case profileUnavailable(path: String, reason: String)
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .rootUnreadable(let r): return "persona root unreadable: \(r)"
        case .missingRequiredDocument(let path):
            return "Required persona document is missing: \(path). Compilation creates only checked-missing required documents after completed onboarding and a checked profile. Complete or repair onboarding and memory/profile.json, then compile again; existing unreadable documents require restoration or access repair."
        case .profileUnavailable(let path, let reason):
            return "The saved personality profile is unavailable at \(path). Repair or restore access to this file before continuing. \(reason)"
        case .underlying(let m): return m
        }
    }
}

// MARK: - Persona-root resolver

public enum PersonaRootResolver {
    /// Resolve persona strictly inside an injected data root.
    ///
    /// Isolated bodies never use checkout persona seeds: always `<dataRoot>/persona`.
    public static func resolveIsolated(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.appendingPathComponent("persona", isDirectory: true)
    }
}

/// Mutation receipt: `bytesWritten` counts a full replacement; `bytesAppended`
/// counts the appended section. The unused count is `nil`.
public struct PersonaToolWriteResult: Sendable, Equatable {
    public let kind: String
    public let path: String
    public let backupPath: String?
    public let bytesWritten: Int?
    public let bytesAppended: Int?

    public init(kind: String, path: String, backupPath: String?, bytesWritten: Int?, bytesAppended: Int?) {
        self.kind = kind
        self.path = path
        self.backupPath = backupPath
        self.bytesWritten = bytesWritten
        self.bytesAppended = bytesAppended
    }
}

// MARK: - SwiftNative impl

/// Native persona document reader and write owner. Each read loads current
/// disk contents; document snapshots are not cached. Write extensions own
/// locked persona mutations, while MemoryV2 owns the USER.md projection.
/// Actor isolation serializes access to this engine's state.
public actor SwiftNativePersonaEngine {
    private let root: URL
    private let fileManager: FileManager
    /// Data root for the canonical saved profile.
    private let dataRoot: URL

    public init(
        root: URL = PersistenceCore.defaultPersonaRoot(),
        fileManager: FileManager = .default,
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        self.root = root
        self.fileManager = fileManager
        self.dataRoot = dataRoot
    }

    /// Persona engine for an injected/secondary body. Unlike the default
    /// initializer this cannot consult environment, bundle, or checkout seed
    /// roots when the injected persona is absent.
    public static func isolated(dataRoot: URL) -> SwiftNativePersonaEngine {
        SwiftNativePersonaEngine(
            root: PersonaRootResolver.resolveIsolated(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
    }

    public var personaRoot: URL { root }

    /// Shared data root for profile reads and writes.
    public var dataRootURL: URL { dataRoot }

    /// Read authored contents as written; unavailable documents throw to their caller.
    public static func readPersonaDocument(at url: URL) throws -> String {
        try readPersonaDocumentContents(at: url).text
    }

    /// One checked UTF-8 read, retaining the exact bytes for a writer's recovery copy.
    static func readPersonaDocumentContents(at url: URL) throws -> (text: String, data: Data) {
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding, userInfo: [
                NSFilePathErrorKey: url.path, NSStringEncodingErrorKey: String.Encoding.utf8.rawValue
            ])
        }
        return (text, data)
    }

    // MARK: - Persona document listing

    /// List the actual canonical documents. Reading never creates or substitutes content.
    public func listPersonaDocSpecs() async throws -> PersonaDocListing {
        var docs: [PersonaDocSpec] = []
        for spec in Self.personalityDocSpecsFixed {
            let url = root.appendingPathComponent(spec.filename)
            if try Self.personaDocumentIsMissing(at: url) {
                throw PersonaEngineError.missingRequiredDocument(path: url.path)
            }
            let content: String
            do { content = try Self.readPersonaDocument(at: url) }
            catch {
                throw PersonaEngineError.rootUnreadable(
                    reason: "cannot read \(url.path): \(error.localizedDescription). Repair or restore this document before continuing."
                )
            }
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            docs.append(PersonaDocSpec(
                id: spec.id, title: spec.title, filename: spec.filename,
                path: url.path, content: content,
                updatedAt: values.contentModificationDate.map { NativeTimestampFormat.fractionalZulu($0) }
            ))
        }
        return PersonaDocListing(docs: docs, updatedAt: NativeTimestampFormat.fractionalZulu(Date()))
    }

}

// MARK: - PersonaDocSpec / PersonaDocListing

/// One persona document as the Personality tab reads and saves it.
public struct PersonaDocSpec: Sendable, Equatable, Codable {
    public let id: String
    public let title: String
    public let filename: String
    public let path: String
    public let content: String
    public let updatedAt: String?

    public init(id: String, title: String, filename: String, path: String, content: String, updatedAt: String?) {
        self.id = id
        self.title = title
        self.filename = filename
        self.path = path
        self.content = content
        self.updatedAt = updatedAt
    }
}

public struct PersonaDocListing: Sendable, Equatable, Codable {
    public let docs: [PersonaDocSpec]
    public let updatedAt: String?

    public init(docs: [PersonaDocSpec], updatedAt: String?) {
        self.docs = docs
        self.updatedAt = updatedAt
    }
}

extension SwiftNativePersonaEngine {
    /// The saved profile, read and parsed off the main actor.
    public nonisolated static func readPersonality(dataRoot: URL) async throws -> PersonalityProfile {
        try await Task.detached { try PersonaCompiler.compileProfile(dataRoot: dataRoot).sharedProfile }.value
    }
}
