import Foundation
import Testing
@testable import NativeAgentApp

// evals-total-coverage — fence `app.bridges`, row `codex.binOverride`
// (SwiftCodexDeviceLoginManager.swift:282 NATIVE_AGENT_CODEX_BIN, :260
// augmentedPath, :307 codexIsResolvable).
//
// Silent-failure class: WRONG VALUE / silent zero. A Finder-launched .app
// inherits a minimal PATH with no /opt/homebrew/bin, so resolving against the
// raw process PATH reports "codex is not installed" on a machine where it is —
// onboarding's ChatGPT precheck and the chat provider-readiness guard both hang
// off this, and both degrade quietly. The mirror failure is an override that is
// accepted without an executability check: the login flow then spawns a
// directory or a plain text file and the device-login lane dies with an opaque
// posix error.
//
// Every case here runs the REAL resolver against a synthetic environment and a
// hermetic temp PATH — no process env is mutated, no live PATH is consulted.
@Suite("Codex executable resolution")
struct CodexExecutableResolutionTests {

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @discardableResult
    private func makeStub(named name: String, in dir: URL, executable: Bool) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    @Test("an executable NATIVE_AGENT_CODEX_BIN wins over a codex already on PATH")
    func overrideTakesPrecedenceOverPath() throws {
        let overrideDir = try makeDir()
        let pathDir = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: overrideDir)
            try? FileManager.default.removeItem(at: pathDir)
        }
        let override = try makeStub(named: "codex-dev", in: overrideDir, executable: true)
        try makeStub(named: "codex", in: pathDir, executable: true)

        let resolved = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "NATIVE_AGENT_CODEX_BIN": override.path,
            "PATH": pathDir.path,
        ])
        #expect(resolved.standardizedFileURL.path == override.standardizedFileURL.path)
    }

    @Test("a non-executable or missing override is ignored, not spawned")
    func nonExecutableOverrideFallsBackToPath() throws {
        let overrideDir = try makeDir()
        let pathDir = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: overrideDir)
            try? FileManager.default.removeItem(at: pathDir)
        }
        let dud = try makeStub(named: "codex-dev", in: overrideDir, executable: false)
        let onPath = try makeStub(named: "codex", in: pathDir, executable: true)

        // Not executable → skipped.
        let a = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "NATIVE_AGENT_CODEX_BIN": dud.path,
            "PATH": pathDir.path,
        ])
        #expect(a.standardizedFileURL.path == onPath.standardizedFileURL.path)

        // Points at nothing → skipped.
        let b = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "NATIVE_AGENT_CODEX_BIN": overrideDir.appendingPathComponent("does-not-exist").path,
            "PATH": pathDir.path,
        ])
        #expect(b.standardizedFileURL.path == onPath.standardizedFileURL.path)

        // CHARACTERIZATION (production gap, reported not fixed): `FileManager
        // .isExecutableFile` is TRUE for a searchable directory, so an override
        // pointing at a directory is accepted and handed to `Process` — which
        // then fails with an opaque posix error instead of the resolver's own
        // "install codex or set NATIVE_AGENT_CODEX_BIN" message. Pinned here so
        // the day someone adds an `isRegularFile` check, this test tells them
        // the contract changed rather than silently agreeing.
        let c = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "NATIVE_AGENT_CODEX_BIN": overrideDir.path,
            "PATH": pathDir.path,
        ])
        #expect(c.standardizedFileURL.path == overrideDir.standardizedFileURL.path,
                "override-is-a-directory behaviour changed — update the reported production seam")

        // Empty string → treated as absent.
        let d = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "NATIVE_AGENT_CODEX_BIN": "",
            "PATH": pathDir.path,
        ])
        #expect(d.standardizedFileURL.path == onPath.standardizedFileURL.path)
    }

    @Test("PATH is scanned in order and a non-executable codex does not shadow a real one")
    func pathScanPrefersTheFirstExecutable() throws {
        let first = try makeDir()
        let second = try makeDir()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        try makeStub(named: "codex", in: first, executable: false)
        let real = try makeStub(named: "codex", in: second, executable: true)

        let resolved = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: [
            "PATH": "\(first.path):\(second.path)",
        ])
        #expect(resolved.standardizedFileURL.path == real.standardizedFileURL.path)
    }

    @Test("resolution fails loudly and names the override when nothing is found")
    func missingCodexThrowsWithGuidance() throws {
        let empty = try makeDir()
        defer { try? FileManager.default.removeItem(at: empty) }

        var thrown: Error?
        do {
            _ = try SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: ["PATH": empty.path])
        } catch {
            thrown = error
        }
        let error = try #require(thrown, "an unresolvable codex must THROW, never return a bogus URL")
        let message = (error as NSError).localizedDescription
        #expect(message.contains("NATIVE_AGENT_CODEX_BIN"),
                "the failure must name the override that fixes it: \(message)")
    }

    @Test("augmentedPath adds every bundled bin dir once, in order, and is idempotent")
    func augmentedPathIsStableAndComplete() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expectedAdditions = [
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]

        let fromEmpty = SwiftCodexDeviceLoginManager.augmentedPath(nil).split(separator: ":").map(String.init)
        #expect(fromEmpty == expectedAdditions, "the augmented PATH inventory drifted: \(fromEmpty)")

        // /opt/homebrew/bin is the one that a Finder-launched .app is missing;
        // its absence is the whole reason this helper exists.
        #expect(fromEmpty.contains("/opt/homebrew/bin"))

        // Existing entries keep their position and are never duplicated.
        let augmented = SwiftCodexDeviceLoginManager.augmentedPath("/custom/first:/usr/bin")
        let parts = augmented.split(separator: ":").map(String.init)
        #expect(parts.first == "/custom/first", "caller PATH precedence was lost")
        #expect(parts[1] == "/usr/bin")
        #expect(Set(parts).count == parts.count, "augmentedPath duplicated an entry: \(parts)")
        for addition in expectedAdditions {
            #expect(parts.contains(addition), "augmentedPath dropped \(addition)")
        }

        // Idempotent: the login env is built by re-augmenting an already
        // augmented PATH on every retry.
        #expect(SwiftCodexDeviceLoginManager.augmentedPath(augmented) == augmented)
    }

    @Test("codexIsResolvable answers with the SAME augmented PATH the login flow spawns with")
    func resolvabilityMatchesTheLoginPath() {
        // The detection helper and the spawn path must agree, or onboarding
        // reports "not installed" for a codex the login flow can happily run
        // (and vice versa — a green precheck followed by a spawn failure).
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = SwiftCodexDeviceLoginManager.augmentedPath(environment["PATH"])
        let directly = (try? SwiftCodexDeviceLoginManager.resolveCodexExecutable(environment: environment)) != nil
        #expect(SwiftCodexDeviceLoginManager.codexIsResolvable() == directly)

        // And the login environment actually carries that PATH plus CODEX_HOME.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        let loginEnv = SwiftCodexDeviceLoginManager.loginEnvironment(codexHome: home)
        #expect(loginEnv["CODEX_HOME"] == home.path)
        #expect(loginEnv["PATH"] == SwiftCodexDeviceLoginManager.augmentedPath(ProcessInfo.processInfo.environment["PATH"]))
    }
}
