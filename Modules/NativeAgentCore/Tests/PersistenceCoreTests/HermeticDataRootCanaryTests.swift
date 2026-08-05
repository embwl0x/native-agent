import Testing
import Foundation
@testable import PersistenceCore

// MARK: - Hermetic data-root CANARY (2026-08-05 hermetic-tests sweep)
//
// THE BUG THIS GUARDS. Many Core types default their `dataRoot:` init
// parameter to `PersistenceCore.defaultDataRoot()`. Under `swift test` that
// resolves — via the dev CWD walk-up — to THIS repo's `data/`, i.e. the LIVE
// app data root. Every bare construction in a test therefore reads and writes
// the user's real state. The concrete instance that motivated this file:
// `SwiftNativePersonaEngine(root:)` with no `dataRoot:` made
// `savePersonalityDoc` append a real "<DOC>.md updated" row to
// `data/activity/events.jsonl` on every suite run (739 phantom rows
// accumulated). The per-target `Hermetic*Support.swift` helpers are the
// primary fix; `script/test.sh` exporting `NATIVE_AGENT_DATA_ROOT` to a
// throwaway mktemp dir is the second line of defence.
//
// That second line only works if `defaultDataRoot()` honors the env var ahead
// of the CWD walk-up. These tests pin exactly that. If someone reorders the
// resolution branches, the env-var backstop silently stops working and the
// leak class comes back — this suite fails first.
@Suite("hermetic data root canary")
struct HermeticDataRootCanaryTests {

    /// The env var must WIN over every other branch (stamped bundle, CWD
    /// walk-up, AppSupport fallback) — that ordering is what makes
    /// `NATIVE_AGENT_DATA_ROOT` usable as a test-wide hermetic pin.
    @Test func defaultDataRoot_honorsNativeAgentDataRootEnvVar() {
        let pinned = FileManager.default.temporaryDirectory
            .appendingPathComponent("canary-dataroot-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: pinned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pinned) }

        // Standardized because the injected value round-trips through
        // URLComponents (which does not resolve /var -> /private/var).
        let resolved = defaultDataRoot(environment: ["NATIVE_AGENT_DATA_ROOT": pinned.path])
        #expect(resolved.path == pinned.path)
        #expect(resolved.path != FileManager.default.currentDirectoryPath + "/data")
    }

    /// Empty string is treated as UNSET (Python `if env:` parity) — so an
    /// accidentally-blank export does not resolve the data root to "".
    @Test func defaultDataRoot_emptyEnvVarIsTreatedAsUnset() {
        let resolved = defaultDataRoot(environment: ["NATIVE_AGENT_DATA_ROOT": ""])
        #expect(!resolved.path.isEmpty)
    }

    /// LIVE-PROCESS canary. When the harness (`script/test.sh`) has exported
    /// `NATIVE_AGENT_DATA_ROOT`, the ARGUMENT-FREE `defaultDataRoot()` — the
    /// one every bare `dataRoot:` default actually calls — must resolve there
    /// and NOT into the repo checkout. Under a bare `swift test` (no export)
    /// there is nothing to assert, so the test asserts the walk-up invariant
    /// instead: the resolved root is a directory path, never empty.
    @Test func defaultDataRoot_processEnvironmentIsHonoredWhenSet() {
        let env = ProcessInfo.processInfo.environment
        guard let pinned = env["NATIVE_AGENT_DATA_ROOT"], !pinned.isEmpty else {
            #expect(!defaultDataRoot().path.isEmpty)
            return
        }
        #expect(defaultDataRoot().path == pinned)
        // The leak target: whatever else is true, the resolved root must not be
        // the repo's tracked data/ directory.
        #expect(!defaultDataRoot().path.hasSuffix("/NativeAgent/data"))
    }
}
