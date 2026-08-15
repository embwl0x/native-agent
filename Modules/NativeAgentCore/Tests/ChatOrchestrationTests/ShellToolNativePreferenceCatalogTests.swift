import Testing
import Foundation
import NativeAgentCore
import PersistenceCore
@testable import ChatOrchestration

/// W5 L1#13 (bash demotion). The model reaches for generic shell even when a
/// native tool answers the same question. The nudge lives in the tool CATALOG
/// description — description-only, no dispatch or gating change.
@Suite("Shell catalog prefers native tools")
struct ShellToolNativePreferenceCatalogTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellNativePref-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Builder tools (shell/bash) are catalogued only under Full Mac.
    private func seedFullMac(_ dataRoot: URL) throws {
        let dir = dataRoot.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let policy: JSONValue = .object([
            "permissionLevel": .string("full_mac_os"),
            "developerMode": .bool(true),
            "fullMacNeverExpires": .bool(true),
            "filePolicy": .object([
                "outsideWorkspaceDefault": .string("allow"),
                "requireBackupBeforeWrite": .bool(false),
                "allowDestructiveActions": .bool(true),
            ]),
            "macControlPolicy": .object([
                "enabled": .bool(true),
                "file_ops_allowed": .bool(true),
                "system_control_allowed": .bool(true),
                "accessibility_allowed": .bool(true),
                "shell_allowed": .bool(true),
                "remote_from_ios_allowed": .bool(true),
                "approval_required_for": .array([]),
            ]),
        ])
        try policy.serializedData(pretty: true)
            .write(to: dir.appendingPathComponent("policy.json"))
    }

    @Test func shellAndBashDescriptionsCarryTheNativeToolGuidance() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()

        let shell = try #require(schemas.first { $0.name == "shell" })
        let bash = try #require(schemas.first { $0.name == "bash" })

        #expect(shell.description.contains(SwiftToolDispatcher.nativeToolPreferenceGuidance))
        #expect(bash.description.contains(SwiftToolDispatcher.nativeToolPreferenceGuidance))

        // The guidance has to name the tools it is redirecting toward, or it
        // is a vague scold the model cannot act on.
        for named in ["session_search", "github_", "read_file", "list_dir"] {
            #expect(SwiftToolDispatcher.nativeToolPreferenceGuidance.contains(named))
        }

        // Description-only: the pre-existing shell contract is untouched.
        #expect(shell.description.contains("/bin/sh -c"))
        #expect(bash.description.contains("/bin/bash -c"))
    }

    @Test func guidanceDoesNotLeakIntoUnrelatedToolDescriptions() async throws {
        let root = try makeRoot()
        try seedFullMac(root)
        let schemas = try await SwiftToolDispatcher(dataRoot: root).listAvailableToolSchemas()

        let carriers = schemas
            .filter { $0.description.contains(SwiftToolDispatcher.nativeToolPreferenceGuidance) }
            .map(\.name)
            .sorted()
        #expect(carriers == ["bash", "shell"], "unexpected carriers: \(carriers)")
    }
}
