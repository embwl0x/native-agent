import Foundation
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.settings / ui.Capabilities.productionHardeningPanel

@Suite("Capabilities production hardening panel")
struct CapabilitiesProductionHardeningPanelEvalTests {
    @Test("the report reader and export presentation preserve healthy, malformed, and missing states")
    func hardeningReportAndExportStayOnTheConfiguredDataRoot() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let reportURL = root
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("hardening.json")
        try FileManager.default.createDirectory(
            at: reportURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(healthyReportJSON.utf8).write(to: reportURL)

        let client = NativeClient(baseURL: "", dataRootOverride: root)
        let healthy = try await client.getProductionHardening()
        #expect(healthy.status == "ready")
        #expect(healthy.doctorStatus == "ok")
        #expect(healthy.release?.items.first?.status == "passed")

        let export = try await client.createProductionExport()
        #expect(export.path.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: export.path))
        #expect(CapabilityProductionExportButtonsPresentation.notice(for: .verified(export)) == .init(
            detail: "Export created and verified: \(export.path) (\(export.sizeBytes ?? 0) bytes).",
            status: "ok"
        ))
        let supportBundle = try await client.createSupportBundle()
        #expect(supportBundle.path.hasPrefix(root.path))
        #expect(FileManager.default.fileExists(atPath: supportBundle.path))
        #expect(CapabilityProductionExportButtonsPresentation.notice(for: .verified(supportBundle)) == .init(
            detail: "Support created and verified: \(supportBundle.path) (\(supportBundle.sizeBytes ?? 0) bytes).",
            status: "ok"
        ))
        let reloadedExports = try await NativeClient(baseURL: "", dataRootOverride: root)
            .getProductionExports()
        #expect(reloadedExports.contains { $0.id == export.id && $0.path == export.path })
        #expect(reloadedExports.contains { $0.id == supportBundle.id && $0.path == supportBundle.path })

        try Data("{not valid json".utf8).write(to: reportURL)
        let malformed = try await client.getProductionHardening()
        #expect(malformed.status == "unavailable")
        #expect(malformed.detail?.isEmpty == false)
        #expect(malformed.release == nil)

        try FileManager.default.removeItem(at: reportURL)
        let missing = try await client.getProductionHardening()
        #expect(missing.status == "unknown")
        #expect(missing.detail?.isEmpty == false)
        #expect(missing.release == nil)
        #expect(missing.detail != malformed.detail)
    }

    private var healthyReportJSON: String {
        #"""
        {
          "status": "ready",
          "doctorStatus": "ok",
          "createdAt": "2026-08-24T12:00:00Z",
          "release": {
            "status": "ready",
            "createdAt": "2026-08-24T12:00:00Z",
            "items": [
              {
                "id": "store-integrity",
                "title": "Store integrity",
                "status": "passed",
                "detail": "Checked canonical runtime stores."
              }
            ]
          }
        }
        """#
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capabilities-hardening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

}
