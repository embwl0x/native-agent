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
