import Foundation
import NativeAgentShared
import NativeAgentCore
import PersistenceCore
// Blueprint: | `PersonaEngine.swift` | `SwiftNativePersonaEngine`, `PersonaSelection`. |

/// Use one installation-wide persona choice for every conversation door.
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
// PersistenceCore.defaultPersonaRoot owns resolution: checkout data uses sibling persona; other data roots use their own persona.

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
            return """
                Required persona document is missing: \(path). Compilation creates only checked-missing required documents after completed onboarding and a \
                checked profile. Complete or repair onboarding and memory/profile.json, then compile again; existing unreadable documents require restoration \
                or access repair.
                """
        case .profileUnavailable(let path, let reason):
            return "The saved personality profile is unavailable at \(path). Repair or restore access to this file before continuing. \(reason)"
        case .underlying(let m): return m
        }
    }
}

// MARK: - Persona-root resolver

public enum PersonaRootResolver {
    /// Injected bodies resolve only inside their data root so absence cannot select checkout seeds.
    public static func resolveIsolated(dataRoot: URL) -> URL {
        dataRoot.standardizedFileURL.appendingPathComponent("persona", isDirectory: true)
    }
}

/// Keep replacement and append byte counts distinct; leave the unused count absent.
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

/// Read current disk contents without document snapshots; extensions own locked writes and MemoryV2 owns USER projection.
/// Actor isolation serializes engine state.
public actor SwiftNativePersonaEngine {
    private let root: URL
    private let fileManager: FileManager
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

    /// Injected bodies cannot consult environment, bundle or checkout seeds when their persona is absent.
    public static func isolated(dataRoot: URL) -> SwiftNativePersonaEngine {
        SwiftNativePersonaEngine(
            root: PersonaRootResolver.resolveIsolated(dataRoot: dataRoot),
            dataRoot: dataRoot
        )
    }

    public var personaRoot: URL { root }

    public var dataRootURL: URL { dataRoot }

    /// Read authored contents unchanged; unavailable documents throw.
    public static func readPersonaDocument(at url: URL) throws -> String {
        try readPersonaDocumentContents(at: url).text
    }

    /// Retain exact checked UTF-8 bytes so recovery copies preserve the original.
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

    /// List actual canonical documents without creating or substituting content.
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


public struct PersonaDocListing: Sendable, Equatable, Codable {
    public let docs: [PersonaDocSpec]
    public let updatedAt: String?

    public init(docs: [PersonaDocSpec], updatedAt: String?) {
        self.docs = docs
        self.updatedAt = updatedAt
    }
}

extension SwiftNativePersonaEngine {
    /// Read and parse saved profile off the main actor.
    public nonisolated static func readPersonality(dataRoot: URL) async throws -> PersonalityProfile {
        try await Task.detached { try PersonaCompiler.compileProfile(dataRoot: dataRoot).sharedProfile }.value
    }
}
