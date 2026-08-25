import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.productionExportButtons
@MainActor
@Suite("Capabilities production export buttons", .serialized)
struct CapabilitiesProductionExportButtonsEvalTests {
    @Test("the real export action reports success only after the archive and registry agree")
    func exportAndSupportBundleHavePersistedReceipts() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeHardeningReport(to: root)

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let exportOutcome = await app.createProductionExport()
        let export = try verifiedExport(from: exportOutcome)
        #expect(FileManager.default.fileExists(atPath: export.path))
        #expect(app.productionExports.contains { $0.id == export.id && $0.path == export.path })
        #expect(CapabilityProductionExportButtonsPresentation.notice(for: exportOutcome) == .init(
            detail: "Export created and verified: \(export.path) (\(export.sizeBytes ?? 0) bytes).",
            status: "ok"
        ))

        let supportOutcome = await app.createProductionExport(support: true)
        let support = try verifiedExport(from: supportOutcome)
        #expect(support.kind == "support")
        #expect(FileManager.default.fileExists(atPath: support.path))
        #expect(app.productionExports.contains { $0.id == support.id && $0.path == support.path })
    }

    @Test("an archive creation failure remains an unverified, named button receipt")
    func unavailableWriteBoundaryDoesNotReportAProductionExport() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        guard FileManager.default.createFile(
            atPath: root.appendingPathComponent("production").path,
            contents: Data("not a directory".utf8)
        ) else {
            throw ExportEvalError.couldNotBlockProductionDirectory
        }

        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let outcome = await app.createProductionExport()
        guard case .failed(let support, let detail) = outcome else {
            Issue.record("a blocked production directory must not report a verified archive")
            return
        }
        #expect(!support)
        #expect(!detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let notice = CapabilityProductionExportButtonsPresentation.notice(for: outcome)
        #expect(notice.status == "failed")
        #expect(notice.detail.hasPrefix("Export was not verified:"))
        #expect(app.productionExports.isEmpty)
    }

    private func verifiedExport(from outcome: ProductionExportCreationOutcome) throws -> ProductionExport {
        guard case .verified(let export) = outcome else {
            throw ExportEvalError.expectedVerifiedReceipt
        }
        return export
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-export-buttons-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeHardeningReport(to root: URL) throws {
        let report = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hardening.json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"status":"ready","doctorStatus":"ok","release":{"status":"ready","items":[]}}"#.utf8)
            .write(to: report)
    }

    private enum ExportEvalError: Error {
        case expectedVerifiedReceipt
        case couldNotBlockProductionDirectory
    }
}
