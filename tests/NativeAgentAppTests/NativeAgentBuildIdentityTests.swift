import Foundation
import Testing
@testable import NativeAgentApp

@Suite("NativeAgent build identity")
struct NativeAgentBuildIdentityTests {
    @Test("clean stamped bundle exposes an exact revision")
    func cleanBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: root.appendingPathComponent("VERSION_SHA"),
            atomically: true,
            encoding: .utf8
        )

        let identity = NativeAgentBuildIdentity.from(
            infoDictionary: [
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": "0.2.0",
                "NativeAgentSourceRevision": "0123456789abcdef0123456789abcdef01234567",
                "NativeAgentSourceDirty": false,
            ],
            resourcesURL: root
        )

        #expect(identity.version == "0.2.0")
        #expect(identity.sourceRevision == "0123456789abcdef0123456789abcdef01234567")
        #expect(identity.exactSourceRevision == "0123456789abcdef0123456789abcdef01234567")
    }

    @Test("disagreeing bundle stamps fail closed")
    func mismatchedRevisionStampsAreNotExact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n".write(
            to: root.appendingPathComponent("VERSION_SHA"),
            atomically: true,
            encoding: .utf8
        )

        let identity = NativeAgentBuildIdentity.from(
            infoDictionary: [
                "NativeAgentSourceRevision": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "NativeAgentSourceDirty": false,
            ],
            resourcesURL: root
        )

        #expect(identity.sourceDirty == true)
        #expect(identity.exactSourceRevision == nil)
    }

    @Test("dirty bundle never presents HEAD as exact byte identity")
    func dirtyBundle() {
        let identity = NativeAgentBuildIdentity.from(
            infoDictionary: [
                "CFBundleShortVersionString": "0.2.0",
                "NativeAgentSourceRevision": "0123456789abcdef0123456789abcdef01234567",
                "NativeAgentSourceDirty": true,
            ],
            resourcesURL: nil
        )

        #expect(identity.sourceRevision == "0123456789abcdef0123456789abcdef01234567")
        #expect(identity.exactSourceRevision == nil)
    }

    @Test("resource stamp is the fail-closed compatibility source")
    func resourceFallback() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "resource-sha\n".write(to: root.appendingPathComponent("VERSION_SHA"), atomically: true, encoding: .utf8)

        let identity = NativeAgentBuildIdentity.from(infoDictionary: [:], resourcesURL: root)
        #expect(identity.version == "dev")
        #expect(identity.build == "dev")
        #expect(identity.sourceRevision == "resource-sha")
        #expect(identity.exactSourceRevision == nil)
    }

    @Test("legacy full resource SHA without dirty provenance is not exact")
    func unstampedDirtyProvenanceIsNotExact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: root.appendingPathComponent("VERSION_SHA"),
            atomically: true,
            encoding: .utf8
        )

        let identity = NativeAgentBuildIdentity.from(infoDictionary: [:], resourcesURL: root)
        #expect(identity.sourceDirty == true)
        #expect(identity.exactSourceRevision == nil)
    }


    @Test("legacy short SHA is visible but not exact proof")
    func legacyShortSHAIsNotExact() {
        let identity = NativeAgentBuildIdentity.from(
            infoDictionary: [
                "NativeAgentSourceRevision": "b31111a",
                "NativeAgentSourceDirty": false,
            ],
            resourcesURL: nil
        )

        #expect(identity.sourceRevision == "b31111a")
        #expect(identity.exactSourceRevision == nil)
    }
}

/// Sweep R4 C13: the identity above was computed and rendered nowhere. These
/// lock the one-line form the About section now shows, including the honesty
/// property that matters — an unstamped/dirty build says so out loud.
@Suite("Build identity settings line")
struct BuildIdentitySettingsLineTests {
    @Test("clean stamped build renders version + short revision, no modified tag")
    func cleanLine() {
        let identity = NativeAgentBuildIdentity(
            version: "0.3.7",
            build: "0.3.7",
            sourceRevision: "abc1234def5678000000000000000000000000aa",
            sourceDirty: false
        )
        #expect(SlimSettingsView.buildIdentityLine(identity) == "0.3.7 (abc1234)")
    }

    @Test("dirty build is labelled modified")
    func dirtyLine() {
        let identity = NativeAgentBuildIdentity(
            version: "0.3.7",
            build: "0.3.7",
            sourceRevision: "abc1234def5678000000000000000000000000aa",
            sourceDirty: true
        )
        #expect(SlimSettingsView.buildIdentityLine(identity) == "0.3.7 (abc1234, modified)")
    }

    @Test("unstamped dev build still names itself rather than looking like a release")
    func devLine() {
        let identity = NativeAgentBuildIdentity(
            version: "dev", build: "dev", sourceRevision: nil, sourceDirty: true
        )
        #expect(SlimSettingsView.buildIdentityLine(identity) == "dev (modified)")
    }

    @Test("a build number that differs from the version is shown")
    func buildNumberLine() {
        let identity = NativeAgentBuildIdentity(
            version: "0.3.7", build: "1042", sourceRevision: nil, sourceDirty: false
        )
        #expect(SlimSettingsView.buildIdentityLine(identity) == "0.3.7 build 1042")
    }
}
