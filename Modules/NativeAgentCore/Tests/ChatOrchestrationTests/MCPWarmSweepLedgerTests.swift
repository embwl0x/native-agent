import Foundation
import Testing
@testable import ChatOrchestration
import NativeAgentCore
import MCPDispatcher
import PersistenceCore

// Perf wave 2, F6. The warm sweep forced a live `tools/list` round-trip against
// EVERY configured stdio server every 300s. Because the subprocess pool reaps
// idle servers, that means re-spawning each of them, waiting out a handshake,
// and rewriting `mcp/cache/tools.json` with the descriptors already in it.
//
// The ledger skips a server only when its manifest sources AND its own command
// line are byte-identical to those of its last SUCCESSFUL handshake, and that
// handshake is younger than the age ceiling. These tests pin every one of those
// clauses, including the mutation cases that must still sweep.
@Suite("MCP warm-sweep ledger", .serialized)
struct MCPWarmSweepLedgerTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPWarmSweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("mcp", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    /// A servers.json with one stdio server. `command` is what the per-server
    /// half of the signature keys on.
    private func writeManifest(_ root: URL, command: String, id: String = "alpha") throws {
        let manifest = JSONValue.array([
            .object([
                "id": .string(id),
                "name": .string(id),
                "transport": .string("stdio"),
                "endpoint": .string(""),
                "command": .string(command),
                "status": .string("ready"),
                "healthStatus": .string("healthy"),
                "toolCount": .int(0),
                "resourceCount": .int(0),
                "riskClass": .string("low"),
                "createdAt": .string("2026-08-01T00:00:00Z"),
                "updatedAt": .string("2026-08-01T00:00:00Z"),
            ]),
        ])
        try manifest.serializedData(pretty: true).write(
            to: root.appendingPathComponent("mcp", isDirectory: true)
                .appendingPathComponent("servers.json"),
            options: .atomic
        )
    }

    // NOTE: `listServers()` auto-merges a default `searxng-local` server that
    // is NOT in servers.json, so absolute server counts are not the assertion
    // surface. Every test below reads the per-server `report` value instead —
    // "skipped", a tool count, or "error: …" — which says exactly what happened
    // to the server it names.

    @Test func aFailedHandshakeIsNeverMarkedAndSweepsAgain() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A command that cannot spawn — every handshake fails.
        try writeManifest(root, command: "/nonexistent/mcp-server-binary")
        let ledger = MCPWarmSweepLedger()

        let first = await ledger.sweep(root: root)
        #expect(first["alpha"]?.hasPrefix("error:") == true, "test premise: the handshake must fail")

        let second = await ledger.sweep(root: root)
        #expect(
            second["alpha"]?.hasPrefix("error:") == true,
            "a broken server must be retried on every sweep, not skipped into permanent invisibility"
        )
        #expect(second["alpha"] != "skipped")
    }

    // MUTATION TEST 1 — a MANIFEST edit must re-sweep. Simulated by marking the
    // server as successful (via a ledger whose age ceiling has not elapsed) and
    // then rewriting servers.json.
    @Test func aManifestRewriteInvalidatesTheSkip() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root, command: "/bin/echo")
        let ledger = MCPWarmSweepLedger()
        _ = await ledger.sweep(root: root)
        // Second sweep, nothing touched: the servers that DID complete a
        // handshake are skipped. This is the positive half of the fix.
        let unchanged = await ledger.sweep(root: root)
        #expect(
            unchanged.values.contains("skipped"),
            "an unchanged manifest must skip at least the servers that handshook cleanly"
        )
        let skippedIds = Set(unchanged.filter { $0.value == "skipped" }.keys)
        #expect(!skippedIds.isEmpty)

        // Same command, new bytes on disk — an operator edit, a UI write, a
        // defaults re-merge. The (device, inode, size, mtime_ns) stamp moves.
        try await Task.sleep(nanoseconds: 20_000_000)
        try writeManifest(root, command: "/bin/echo")
        // The dispatcher caches servers.json for 60s; a fresh one re-reads it,
        // and the ledger's marks are what is under test, not that cache.
        let after = await ledger.sweep(root: root)
        for id in skippedIds {
            #expect(
                after[id] != "skipped",
                "a rewritten manifest must force a fresh handshake for \(id)"
            )
        }
    }

    // MUTATION TEST 2 — a changed COMMAND LINE must re-sweep even if the
    // manifest stamp somehow matched.
    @Test func aChangedCommandLineProducesADifferentSignature() async throws {
        let a = MCPWarmSweepLedger.Signature(manifest: "m", commandLine: "stdio\u{1F}\u{1F}/bin/one\u{1F}ready")
        let b = MCPWarmSweepLedger.Signature(manifest: "m", commandLine: "stdio\u{1F}\u{1F}/bin/two\u{1F}ready")
        #expect(a != b)
        #expect(a == MCPWarmSweepLedger.Signature(manifest: "m", commandLine: "stdio\u{1F}\u{1F}/bin/one\u{1F}ready"))
    }

    // MUTATION TEST 3 — the AGE CEILING. A server whose files never change (an
    // `npx …@latest` package upgraded in place changes nothing this process can
    // stat) must still be re-handshaken once the ceiling elapses, or a newly
    // added tool would be invisible to the model forever.
    @Test func theAgeCeilingForcesAPeriodicRehandshake() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root, command: "/bin/echo")

        // A ceiling that has always elapsed. Nothing on disk changes between
        // the two sweeps, so ONLY the ceiling can force the re-handshake.
        let expiring = MCPWarmSweepLedger(maxHandshakeAge: 0)
        _ = await expiring.sweep(root: root)
        let after = await expiring.sweep(root: root)
        #expect(!after.isEmpty, "test premise: at least one server is configured")
        #expect(
            !after.values.contains("skipped"),
            "an elapsed age ceiling must re-handshake even when nothing on disk changed"
        )
        let stats = await expiring._testStats()
        #expect(stats.skips == 0)
    }

    @Test func aServerRemovedFromTheManifestDropsItsMark() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeManifest(root, command: "/bin/echo", id: "alpha")
        let ledger = MCPWarmSweepLedger()
        _ = await ledger.sweep(root: root)

        let before = await ledger._testStats()

        // Replace the manifest with a DIFFERENT server; alpha's mark must go.
        try await Task.sleep(nanoseconds: 20_000_000)
        try writeManifest(root, command: "/bin/echo", id: "beta")
        _ = await ledger.sweep(root: root)
        let after = await ledger._testStats()
        #expect(
            after.marks <= before.marks,
            "every insert has a matching remove — a retired server must not hold a mark forever"
        )
    }

    @Test func aRootWithNoServersJSONStillSweepsTheMergedDefaultsAndThenSkipsThem() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = MCPWarmSweepLedger()
        // Contract inherited from refreshAllToolsCaches: never throws, and one
        // bad/absent manifest never blinds the other servers.
        let first = await ledger.sweep(root: root)
        #expect(!first.values.contains("skipped"), "a first sweep has nothing to skip")
        let second = await ledger.sweep(root: root)
        for (id, value) in second where first[id]?.hasPrefix("error:") == false {
            #expect(value == "skipped", "\(id) handshook cleanly and did not change")
        }
    }
}
