import Foundation
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Privacy
// Blueprint: | `EngineFaceActs+Capture.swift` | Finite native capture reads and checked Diagnostics run presentations |

extension EngineFaceActs {
    public func prepareWorkPaneCapture(_ pane: WorkPaneSnapshot) async throws {
        try await EngineFaceWorkProjection.prepareWorkPane(pane, engine: engine)
    }

    public func preparePageCapture(page: String, tab: String?) async throws {
        _ = try await engine.layout.availability.get()
        await EngineFaceProjection.layout(engine)
        switch (page, tab) {
        case ("memories", "knowledge"):
            _ = try await engine.trust.load()
            await engine.memory.loadGraph()
            try await EngineFaceProjection.prepareCapture(.knowledgeGraph, engine: engine)
            try await EngineFaceMindProjection.prepareCapture(.memoryDiagnostics, engine: engine)
            await engine.pages.refresh(page: "knowledge")
        case ("personality", "documents"):
            _ = try await engine.persona.loadProfile()
            _ = try await engine.persona.loadDocuments()
            _ = await postOnboarding(try await engine.onboarding.readOnboarding())
        case ("personality", "dreams"):
            await engine.pages.refresh(page: "dreams")
        case ("diagnostics", "Cognition"):
            await engine.pages.refresh(page: "cognition")
            try await EngineFaceMindProjection.prepareCapture(.cognition, engine: engine)
            try await EngineFaceMindProjection.prepareCapture(.contextFlowHealth, engine: engine)
            await EngineFaceWorkProjection.prepareDiagnostics(engine: engine)
        case ("memories", "upkeep"):
            await engine.pages.refresh(page: "memory-upkeep")
        case ("diagnostics", "Inspector"):
            let face = try await engine.trace.readLive(after: nil)
            await engine.face.post(face, at: .inspector(after: nil))
        case ("simple", _):
            try await EngineFaceProjection.prepareCapture(.contacts, engine: engine)
            try await EngineFaceProjection.prepareCapture(.helpers, engine: engine)
        case ("simple_settings_menu", _):
            // Simple's settings picture shows Control's Settings tab beside the sidebar.
            try await EngineFaceProjection.prepareCapture(.contacts, engine: engine)
            try await EngineFaceProjection.prepareCapture(.helpers, engine: engine)
            await engine.pages.refresh(page: "settings")
        default: break
        }
        await engine.pages.flush()
    }

    func readRun(_ id: String) async throws -> FaceActReply {
        let record = try await Self.readRunRecord(id, root: engine.dataRoot)
        await engine.face.post(RunFace(id: id, record: record, rows: [], status: record.status, state: .ready), at: .run(id))
        return try Self.result(record)
    }

    @concurrent static func readRunRecord(_ id: String, root: URL) async throws -> RunRecord {
        guard let found = try await RuntimeReadouts.readRunLedger(dataRoot: root).first(where: { $0.id == id }) else {
            throw failure("run_not_found", "That run is absent from the checked ledger.")
        }
        return try NativeAppSecretRedactor.redactValue(JSONValue.fromEncodable(found)).decodedExactly(as: RunRecord.self)
    }
}
