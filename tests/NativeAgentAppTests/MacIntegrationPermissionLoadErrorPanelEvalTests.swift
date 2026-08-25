import Foundation
import MacIntegration
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.mac / ui.macIntegration.permissionLoadErrorPanel
@Suite("Mac Integration permission-load error panel")
struct MacIntegrationPermissionLoadErrorPanelEvalTests {
    @Test("a malformed authority store remains visibly unavailable and deny-all")
    func malformedStoreMapsToVisibleUnavailablePanel() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root
            .appendingPathComponent("security", isDirectory: true)
            .appendingPathComponent("mac_integration_permissions.json")
        try Data("not-json".utf8).write(to: path, options: .atomic)

        let store = MacIntegrationPermissionStore(dataRoot: root)
        let detail: String
        do {
            _ = try await store.currentChecked()
            Issue.record("A malformed permission store must not load as defaults.")
            return
        } catch {
            detail = error.localizedDescription
        }

        #expect(
            MacIntegrationPermissionLoadPresentation.resolve(
                isLoading: false,
                loadError: detail
            ) == .unavailable(detail: "The saved Mac Integration permissions are malformed.", retrying: false)
        )
        #expect(
            MacIntegrationPermissionLoadPresentation.resolve(
                isLoading: true,
                loadError: detail
            ) == .unavailable(detail: "The saved Mac Integration permissions are malformed.", retrying: true),
            "retrying must retain the adverse panel rather than briefly presenting an empty/healthy state"
        )
        #expect(!(await store.allows(MacIntegrationID.calendar, mode: .read)))
        #expect(try Data(contentsOf: path) == Data("not-json".utf8),
                "reading malformed authority must not overwrite its existing bytes")
    }

    @Test("initial loading, loaded controls, and blank failures are distinct")
    func loadStatesDoNotBorrowEachOthersPresentation() {
        #expect(MacIntegrationPermissionLoadPresentation.resolve(isLoading: true, loadError: nil) == .loading)
        #expect(MacIntegrationPermissionLoadPresentation.resolve(isLoading: false, loadError: nil) == .controlsAvailable)
        #expect(
            MacIntegrationPermissionLoadPresentation.resolve(isLoading: false, loadError: " \n ")
                == .unavailable(
                    detail: "The saved Mac Integration permissions could not be loaded.",
                    retrying: false
                )
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-integration-permission-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("security", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }
}
