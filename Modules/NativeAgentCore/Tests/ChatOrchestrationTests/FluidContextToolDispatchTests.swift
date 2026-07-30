import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import Context

@Suite("Fluid Context tool dispatch")
struct FluidContextToolDispatchTests {
    private let generationID: Int64 = 7
    private let generationFingerprint = "fluid-context-generation-7"

    @Test
    func requestedBuiltInSchemasAreConstructedWithoutTheFullCatalogPayload() throws {
        let dispatcher = makeDispatcher()
        let requested: Set<String> = ["read_file", "image_generate"]

        let selected = dispatcher.builtInToolSchemas(requestedNames: requested)
        let full = dispatcher.builtInToolSchemas()
        let ordinaryHotNames = SwiftToolDispatcher.alwaysOnCoreNames.subtracting(["context_expand"])
        let hotCore = dispatcher.builtInToolSchemas(requestedNames: ordinaryHotNames)

        #expect(selected.map(\.name) == ["read_file", "image_generate"])
        #expect(full.count > selected.count * 20)
        #expect(schemaBytes(selected) < schemaBytes(full) / 10)
        #expect(hotCore.count <= ordinaryHotNames.count)
        #expect(schemaBytes(hotCore) < schemaBytes(full))
        print(
            "[fluid-context-metric] tool schemas hot=\(hotCore.count)/\(schemaBytes(hotCore))B "
                + "full=\(full.count)/\(schemaBytes(full))B"
        )
    }

    @Test
    func contextExpandIsHiddenWithoutOfferedPointers() async throws {
        let dispatcher = makeDispatcher()
        let prepared = try makePreparedTurn(offeredAtomIDs: [])

        let names = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.listAvailableTools()
        }
        let schemas = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.listAvailableToolSchemas()
        }

        #expect(!names.contains("context_expand"))
        #expect(!schemas.contains { $0.name == "context_expand" })
    }

    @Test
    func contextExpandIsVisibleWithAnOfferedPointer() async throws {
        let dispatcher = makeDispatcher()
        let prepared = try makePreparedTurn(offeredAtomIDs: ["atom:offered"])

        let names = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.listAvailableTools()
        }
        let schemas = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.listAvailableToolSchemas()
        }

        #expect(names.contains("context_expand"))
        #expect(schemas.contains { $0.name == "context_expand" })
    }

    @Test
    func offeredPointerExpandsBoundedText() async throws {
        let dispatcher = makeDispatcher()
        let prepared = try makePreparedTurn(offeredAtomIDs: ["atom:offered"])

        let result = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.dispatch(
                tool: "context_expand",
                input: [
                    "atom_id": .string("atom:offered"),
                    "max_characters": .int(8),
                ],
                surface: "chat"
            )
        }

        guard case .object(let object) = result else {
            Issue.record("expected context expansion object")
            return
        }
        #expect(object["status"] == .string("ok"))
        #expect(object["generation_id"] == .int(generationID))
        #expect(object["atom_id"] == .string("atom:offered"))
        #expect(object["text"] == .string("Complete"))
        #expect(object["truncated"] == .bool(true))
    }

    @Test
    func unofferedPointerIsDeniedEvenWhenPresentInTheGeneration() async throws {
        let dispatcher = makeDispatcher()
        let prepared = try makePreparedTurn(offeredAtomIDs: ["atom:offered"])

        let result = try await FluidContextToolScope.$current.withValue(prepared) {
            try await dispatcher.dispatch(
                tool: "context_expand",
                input: ["atom_id": .string("atom:unoffered")],
                surface: "chat"
            )
        }

        #expect(result == .object([
            "status": .string("failed"),
            "reason": .string("pointer_not_offered_this_turn"),
            "atom_id": .string("atom:unoffered"),
        ]))
    }

    @Test
    func expansionStillEnforcesGenerationAndSurfaceAuthorization() async throws {
        let dispatcher = makeDispatcher()
        let stalePointerTurn = try makePreparedTurn(
            offeredAtomIDs: ["atom:offered"],
            pointerGenerationID: generationID - 1
        )
        let staleError = await dispatchExpansionError(
            dispatcher,
            prepared: stalePointerTurn,
            surface: "chat"
        )
        #expect(staleError == .pointerGenerationMismatch(
            pointer: generationID - 1,
            generation: generationID
        ))

        let deniedSurfaceTurn = try makePreparedTurn(
            offeredAtomIDs: ["atom:offered"],
            needSurface: .telegram
        )
        let surfaceError = await dispatchExpansionError(
            dispatcher,
            prepared: deniedSurfaceTurn,
            surface: "telegram"
        )
        #expect(surfaceError == .sourceSurfaceDenied(
            source: ContextSourceID(rawValue: "source:fixture"),
            surface: .telegram
        ))
    }

    private func dispatchExpansionError(
        _ dispatcher: SwiftToolDispatcher,
        prepared: ContextPreparedTurn,
        surface: String
    ) async -> ContextExpansionError? {
        do {
            _ = try await FluidContextToolScope.$current.withValue(prepared) {
                try await dispatcher.dispatch(
                    tool: "context_expand",
                    input: ["atom_id": .string("atom:offered")],
                    surface: surface
                )
            }
            return nil
        } catch let error as ContextExpansionError {
            return error
        } catch {
            Issue.record("unexpected dispatch error: \(error)")
            return nil
        }
    }

    private func makeDispatcher() -> SwiftToolDispatcher {
        SwiftToolDispatcher(
            dataRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("fluid-context-tool-dispatch-\(UUID().uuidString)")
        )
    }

    private func schemaBytes(_ schemas: [LLMToolSchema]) -> Int {
        schemas.reduce(into: 0) { total, schema in
            total += schema.name.utf8.count
            total += schema.description.utf8.count
            total += schema.parametersJSON.count
        }
    }

    private func makePreparedTurn(
        offeredAtomIDs: Set<String>,
        pointerGenerationID: Int64? = nil,
        needSurface: ContextSurface = .chat
    ) throws -> ContextPreparedTurn {
        let offered = makeAtom(
            id: "atom:offered",
            body: "Complete offered procedure text."
        )
        let unoffered = makeAtom(
            id: "atom:unoffered",
            body: "Unselected generation text."
        )
        let atoms = [offered, unoffered]
        let source = makeSource(for: offered)
        let generation = ContextStoredGeneration(
            generation: ContextGenerationRecord(
                id: generationID,
                parentID: generationID - 1,
                createdAt: Date(timeIntervalSince1970: 10_000),
                reason: "tool dispatch fixture",
                sourceFingerprint: generationFingerprint,
                atomCount: atoms.count,
                sourceCount: 1
            ),
            sources: [source],
            atoms: atoms,
            relationships: []
        )

        let pointerGenerationID = pointerGenerationID ?? generationID
        let pointers = atoms
            .filter { offeredAtomIDs.contains($0.draft.id.rawValue) }
            .map { ContextAtomPointer(atom: $0, generationID: pointerGenerationID) }
        let budget = ContextBudgetUsage(
            characterLimit: 6_000,
            usedCharacters: 0,
            mandatoryCharacters: 0
        )
        let receipt = ContextSelectionReceipt(
            id: "selection-receipt",
            needFingerprint: "need-fingerprint",
            generationID: generationID,
            sourceFingerprint: generationFingerprint,
            selectionTimeBucket: 1,
            eligibility: [],
            candidateScores: [],
            selectedAtomIDs: [],
            pointerAtomIDs: pointers.map(\.atomID),
            mandatoryAtomIDs: [],
            coveredMandatoryAtomIDs: [],
            mandatoryCoverage: 1,
            conflicts: [],
            budget: budget,
            degradedSources: [],
            cacheState: .hit,
            measuredSelectionMicroseconds: 1
        )
        let packet = ContextPacket(
            generationID: generationID,
            sourceFingerprint: generationFingerprint,
            selectedItems: [],
            expandablePointers: pointers,
            conflictSets: [],
            degradedSources: [],
            budget: budget,
            receipt: receipt
        )

        let personaID = ContextPersonaID(rawValue: "fixture-persona")
        let document = try RequiredDocument(
            kind: .soul,
            sourceHash: "soul-hash",
            text: "Fixture identity",
            tokenCount: 2
        )
        let kernelKey = try StablePromptKernelKey(
            personaID: personaID,
            surfaceVariant: ContextSurfaceVariant(rawValue: "chat"),
            sourceFingerprint: generationFingerprint
        )
        let kernel = try StablePromptKernel(
            key: kernelKey,
            renderedPrompt: "# SOUL\nFixture identity",
            includedDocumentIDs: [document.id],
            tokenCount: 4
        )
        let mirror = try RequiredDocumentMirror(
            personaID: personaID,
            sourceFingerprint: generationFingerprint,
            documents: [document],
            kernels: [kernel]
        )
        let snapshot = try ContextGenerationSnapshot(
            generationID: generationID,
            sourceFingerprint: generationFingerprint,
            requiredDocumentMirrors: [mirror]
        )
        let arena = try ContextArena(budget: .mib32)
        _ = arena.publish(snapshot)
        let lease = try arena.acquireSnapshot()
        let need = NeedSignal(
            message: "Expand the offered procedure",
            surface: needSurface,
            origin: .localAuthenticated,
            authorization: ContextSelectionAuthorization(
                allowedOrigins: [.localAuthenticated],
                allowedPrivacy: [.localPrivate],
                allowedSourceIDs: [source.descriptor.id]
            ),
            availableGenerationID: generationID,
            now: Date(timeIntervalSince1970: 20_000),
            timeBucketSeconds: 60
        )

        return ContextPreparedTurn(
            mode: .active,
            kernel: kernel,
            mirror: mirror,
            packet: packet,
            lease: lease,
            generation: generation,
            need: need
        )
    }

    private func makeAtom(id: String, body: String) -> ContextStoredAtom {
        let atomID = ContextAtomID(rawValue: id)
        let draft = ContextAtomDraft(
            id: atomID,
            sourceID: ContextSourceID(rawValue: "source:fixture"),
            kind: .procedure,
            headingPath: ["Procedure"],
            sourceRange: ContextSourceRange(utf8Start: 0, utf8End: body.utf8.count),
            sourceHash: "source-hash-v1",
            body: body,
            deterministicSummary: "Procedure summary",
            authority: .approved,
            confidence: 0.9,
            freshness: ContextFreshness(updatedAt: Date(timeIntervalSince1970: 18_000)),
            privacy: .localPrivate,
            permittedSurfaces: [.chat],
            injectionPolicy: .onDemand,
            contentRole: .procedure
        )
        return ContextStoredAtom(
            versionKey: "\(id)@\(generationID)",
            draft: draft,
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }

    private func makeSource(for atom: ContextStoredAtom) -> ContextStoredSource {
        ContextStoredSource(
            descriptor: ContextSourceDescriptor(
                id: atom.draft.sourceID,
                owner: "fixture",
                kind: .skill,
                canonicalLocator: "fixture.md",
                authority: .approved,
                privacy: .localPrivate,
                permittedSurfaces: [.chat],
                injectionPolicy: .onDemand
            ),
            sourceHash: atom.draft.sourceHash,
            health: .healthy,
            lastError: nil,
            validFromGeneration: 1,
            validToGeneration: nil
        )
    }
}
