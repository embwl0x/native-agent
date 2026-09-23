import Foundation
import PersistenceCore
import Testing
@testable import TrustCenter

@Suite("Chrome control authority")
struct ChromeControlPolicyTests {
    @Test("Chrome control defaults off and enables only through checked policy")
    func defaultOffAndCheckedEnable() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeControlPolicyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = SwiftNativeTrustCenter(dataRoot: root)

        #expect(await trust.chromeControlEnabledChecked() == false)
        await #expect(throws: ChromeControlAuthorityError.disabled) {
            try await trust.authorizeChromeControlEffect()
        }

        _ = try await trust.updateTrust(.object([
            "chromeControlPolicy": .object(["enabled": .bool(true)])
        ]))
        try await trust.authorizeChromeControlEffect()
        #expect(await trust.chromeControlEnabledChecked() == true)
    }

    @Test("Full Mac admits Chrome effects only for the checked caller and current grant")
    func fullMacCallerAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeFullMac-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = SwiftNativeTrustCenter(dataRoot: root)
        _ = try await trust.updateTrust(.object([
            "permissionLevel": .string("full_mac_os"),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("allow")]),
            "chromeControlPolicy": .object(["enabled": .bool(false)])
        ]))
        let local = SecurityOriginContext(surface: "chat", source: "test", isRemote: false)
        let remote = SecurityOriginContext(surface: "telegram", source: "test", isRemote: true)
        #expect(await trust.chromeControlEnabledChecked(tool: "browser.chrome_snapshot", origin: local))
        #expect(await trust.chromeControlEnabledChecked(tool: "browser.chrome_snapshot", origin: remote) == false)
        #expect(await trust.chromeControlEnabledChecked() == false)
        _ = try await trust.updateTrust(.object([
            "permissionLevel": .string("balanced"),
            "filePolicy": .object(["outsideWorkspaceDefault": .string("deny")])
        ]))
        #expect(await trust.chromeControlEnabledChecked(tool: "browser.chrome_snapshot", origin: local) == false)
    }

    @Test("Malformed saved authority fails closed")
    func malformedPolicyFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromeControlMalformed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("trust", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(to: directory.appendingPathComponent("policy.json"))
        let trust = SwiftNativeTrustCenter(dataRoot: root)

        #expect(await trust.chromeControlEnabledChecked() == false)
        await #expect(throws: ChromeControlAuthorityError.unavailable) {
            try await trust.authorizeChromeControlEffect()
        }
    }
}
