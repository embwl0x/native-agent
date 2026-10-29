import Context
import DreamREMCycle
import Foundation
import Senses
import MemoryV2
import NativeAgentCore
import PersonaEngine
import PersistenceCore
import TurnTrace
import WorkshopExecution
import NativeAgentShared
// Blueprint: | `PersonaContextFlowProvider.swift` | `PersonaContextFlowProvider` actor; persona source registrations and required-document mirrors share one compiler batch and surface provenance |

actor PersonaContextFlowProvider: ContextRequiredDocumentMirrorProviding {
    private struct Build: Sendable {
        let mirrors: [RequiredDocumentMirror]
        let registrations: [ContextSourceRegistration]
        let allowedRoots: [URL]
    }

    private static let owner = ContextPersonaSourceNaming.owner
    private static let surfaces: [ContextSurface] = [
        .chat, .telegram, .ios, .slack, .workshop, .bridge, .bot,
    ]

    private let compiler: PersonaCompiler
    private var cachedBuild: Build?

    init(
        dataRoot: URL = PersistenceCore.defaultDataRoot()
    ) {
        let standardizedRoot = dataRoot.standardizedFileURL
        let persona = standardizedRoot
            == PersistenceCore.defaultDataRoot().standardizedFileURL
            ? SwiftNativePersonaEngine(dataRoot: standardizedRoot)
            : SwiftNativePersonaEngine.isolated(dataRoot: standardizedRoot)
        self.compiler = PersonaCompiler(engine: persona)
    }

    func refreshContextSources(in registry: ContextSourceRegistry) async throws {
        let build = try await makeBuild()
        for root in build.allowedRoots {
            try await registry.addAllowedRoot(root)
        }
        let owners = Set(build.registrations.map(\.descriptor.owner)).union([
            Self.owner,
            "nativeagent.markdown.skill-bodies",
        ])
        for owner in owners.sorted() {
            try await registry.replaceOwned(owner: owner, with: build.registrations)
        }
        cachedBuild = build
    }

    func requiredDocumentMirrors() async throws -> [RequiredDocumentMirror] {
        if let cachedBuild { return cachedBuild.mirrors }
        let build = try await makeBuild()
        cachedBuild = build
        return build.mirrors
    }

    private func makeBuild() async throws -> Build {
        let requestedOverride = PersonaSelection.current()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedOverride = requestedOverride?.isEmpty == false ? requestedOverride : nil
        let snapshots = try await compiler.contextSourceSnapshots(
            surfaces: Self.surfaces.map(\.rawValue),
            personaOverrides: selectedOverride.map { ["chat": $0] } ?? [:]
        )

        var registrations: [ContextSourceID: ContextSourceRegistration] = [:]
        var allowedRoots = Set<URL>()
        for snapshot in snapshots {
            allowedRoots.insert(snapshot.personaRoot)
            for document in snapshot.documents {
                let locator = Self.locator(
                    personaID: snapshot.packet.personaId,
                    document: document
                )
                let sourceID = ContextStableID.source(owner: Self.owner, locator: locator)
                let surface = document.surfaceOverride
                    ? ContextSurface(rawValue: String(document.id.dropFirst("surface:".count)))
                    : nil
                let descriptor = ContextSourceDescriptor(
                    id: sourceID,
                    owner: Self.owner,
                    kind: .persona,
                    canonicalLocator: locator,
                    authority: Self.authority(for: document.id),
                    privacy: .localPrivate,
                    permittedSurfaces: surface.map { [$0] } ?? Set(Self.surfaces),
                    injectionPolicy: Self.injectionPolicy(for: document.id)
                )
                let registration = ContextSourceRegistration(
                    descriptor: descriptor,
                    fileURL: document.fileURL,
                    allowedRoot: snapshot.personaRoot
                )
                registrations[sourceID] = registration
            }
        }

        let grouped = Dictionary(grouping: snapshots, by: { $0.packet.personaId })
        let mirrors = try grouped.keys.sorted().map { personaID in
            try Self.makeMirror(
                personaID: personaID,
                snapshots: grouped[personaID] ?? [],
                requestedPersonaOverride: selectedOverride
            )
        }
        return Build(
            mirrors: mirrors,
            registrations: registrations.values.sorted { $0.descriptor.id < $1.descriptor.id },
            allowedRoots: allowedRoots.sorted { $0.path < $1.path }
        )
    }

    static func makeMirror(
        personaID: String,
        snapshots: [PersonaContextSourceSnapshot],
        requestedPersonaOverride: String? = nil
    ) throws -> RequiredDocumentMirror {
        guard let canonical = snapshots.first else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard !snapshots.contains(where: { snapshot in
            snapshot.documents.contains { ContextSecretContentPolicy.containsSecretLikeContent($0.content) }
                || snapshot.packet.activeDocs.values.contains {
                    ContextSecretContentPolicy.containsSecretLikeContent($0)
                }
        }) else {
            throw ContextMarkdownCompilerError.secretLikeContent
        }
        let canonicalDocuments = canonical.documents
            .filter { !$0.surfaceOverride }
            .sorted { $0.canonicalOrder < $1.canonicalOrder }
        let documents = try canonicalDocuments.map { source in
            // Mirror provenance shares makeBuild's descriptor inputs; only canonical
            // documents reach this map, and they permit every surface.
            let locator = Self.locator(personaID: personaID, document: source)
            return try RequiredDocument(
                id: RequiredDocumentID(rawValue: "\(source.id).md"),
                canonicalOrder: source.canonicalOrder,
                sourceHash: ContextStableID.digest(parts: [source.content]),
                text: source.content,
                sourceID: ContextStableID.source(owner: Self.owner, locator: locator),
                permittedSurfaces: Set(Self.surfaces)
            )
        }
        let fingerprint = ContextStableID.digest(parts: documents.flatMap {
            [$0.id.rawValue, $0.sourceHash]
        })
        let contextPersonaID = ContextPersonaID(rawValue: personaID)
        let kernels = try snapshots.sorted { $0.packet.surface < $1.packet.surface }.map { snapshot in
            let activeKernelDocuments = snapshot.documents.filter {
                !$0.surfaceOverride && ($0.id == "SOUL" || $0.id == "VOICE")
            }.sorted { $0.canonicalOrder < $1.canonicalOrder }
            let includedIDs = activeKernelDocuments.map { RequiredDocumentID(rawValue: "\($0.id).md") }
            let renderedPrompt = PersonaCompiler.renderPrompt(
                documents: snapshot.packet.activeDocs.filter {
                    $0.key == "SOUL" || $0.key == "VOICE"
                },
                surface: snapshot.packet.surface
            )
            let surfaceGuidance = PersonaCompiler.renderPrompt(
                documents: snapshot.packet.activeDocs.filter { $0.key == "surface:\(snapshot.packet.surface)" },
                surface: snapshot.packet.surface
            )
            guard !ContextSecretContentPolicy.containsSecretLikeContent(renderedPrompt),
                  !ContextSecretContentPolicy.containsSecretLikeContent(surfaceGuidance) else {
                throw ContextMarkdownCompilerError.secretLikeContent
            }
            let key = try StablePromptKernelKey(
                personaID: contextPersonaID,
                surfaceVariant: ContextSurfaceVariant(rawValue: snapshot.packet.surface),
                sourceFingerprint: fingerprint
            )
            return try StablePromptKernel(
                key: key,
                renderedPrompt: renderedPrompt,
                includedDocumentIDs: includedIDs,
                requestedPersonaOverride: snapshot.packet.surface == ContextSurface.chat.rawValue
                    ? requestedPersonaOverride : nil,
                surfaceGuidance: surfaceGuidance
            )
        }
        return try RequiredDocumentMirror(
            personaID: contextPersonaID,
            sourceFingerprint: fingerprint,
            documents: documents,
            kernels: kernels
        )
    }

    private static func locator(
        personaID: String,
        document: PersonaContextDocumentSource
    ) -> String {
        let component = document.surfaceOverride
            ? "surfaces/\(document.id.dropFirst("surface:".count)).md"
            : "\(document.id).md"
        return "persona/\(personaID)/\(component)"
    }

    private static func authority(for documentID: String) -> ContextAuthority {
        switch documentID {
        case "SOUL", "VOICE": .identity
        case "USER": .explicitCorrection
        case "MEMORY": .approved
        default: .canonical
        }
    }

    static func injectionPolicy(for documentID: String) -> ContextInjectionPolicy {
        switch documentID {
        case "SOUL", "VOICE": .always
        case let value where value.hasPrefix("surface:"): .always
        default: .adaptive
        }
    }
}
