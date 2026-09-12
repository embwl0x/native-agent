// Fence app.background — trust gates, path resolution, and the planner catalog.
//
// Ledger rows closed here:
//   app.background.gate.isWideOpenTrust
//   app.background.gate.workshopEnabledGate
//   app.background.paths.validateStampedPath
//   app.background.paths.envDataRoot
//   app.background.workshopPlannerCatalog
//
// Class: WRONG VALUE. Every surface here answers a yes/no that nothing
// downstream re-checks — a gate that reads `true` for the wrong literal runs
// unattended work the user never authorized, a gate that reads `false` for the
// right one makes Agent quietly stop working, and a planner catalog that loses
// its `[args: …]` suffix emits tool steps with no arguments ("missing_cmd")
// while every receipt still says "completed".

import Foundation
import Testing
import NativeAgentCore
@testable import PersistenceCore
@testable import NativeAgentApp

private func gateTempRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackgroundGate-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@Test func dataRootResolvesOnceAndExplicitEnvironmentBypassesProcessCache() {
    let cache = ResolvedDataRootCache()
    var resolutions = 0
    let expected = URL(fileURLWithPath: "/tmp/data-root-cache-fixture")
    for _ in 0..<100 {
        #expect(cache.resolve { resolutions += 1; return expected } == expected)
    }
    #expect(resolutions == 1)
    let processRoot = defaultDataRoot()
    #expect(defaultDataRoot(environment: ["NATIVE_AGENT_DATA_ROOT": expected.path]).path == expected.path)
    #expect(defaultDataRoot() == processRoot)
    #expect(NativeAgentPaths.dataRoot == processRoot)
}

private func seedTrustPolicy(_ value: JSONValue, at root: URL) throws {
    let path = BackgroundLoopsAssembly.trustPolicyPath(dataRoot: root)
    try FileManager.default.createDirectory(
        at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.serialize(pretty: false).utf8).write(to: path, options: [.atomic])
}

@Suite("app.background gates and paths", .serialized)
struct BackgroundGateAndPathContractTests {

    // MARK: - isWideOpenTrust

    @Test("wide-open trust requires a checked active Full Mac grant")
    func isWideOpenTrustAcceptsOnlyActiveFullMacAuthority() async throws {
        // Both supported persisted spellings normalize to active Full Mac only
        // with their complete authority shape.
        for (level, outside) in [
            ("full_mac_os", "deny"),
            ("wide_open_receipts", "allow"),
        ] {
            let root = try gateTempRoot("wideopen-\(level)")
            defer { try? FileManager.default.removeItem(at: root) }
            try seedTrustPolicy(.object([
                "permissionLevel": .string(level),
                "fullMacNeverExpires": .bool(true),
                "fullMacExpiresAt": .string("never"),
                "filePolicy": .object(["outsideWorkspaceDefault": .string(outside)]),
            ]), at: root)
            let allowed = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: root)
            #expect(allowed, "\(level) is an active wide-open posture")
        }

        // Refused — including near-misses that a sloppy contains/case-insensitive
        // compare would wave through, and non-string shapes.
        let refusals: [(String, JSONValue)] = [
            ("workspace", .object(["permissionLevel": .string("workspace")])),
            ("supervised", .object(["permissionLevel": .string("supervised")])),
            ("uppercase", .object(["permissionLevel": .string("FULL_MAC_OS")])),
            ("padded", .object(["permissionLevel": .string(" full_mac_os ")])),
            ("prefix", .object(["permissionLevel": .string("full_mac_os_readonly")])),
            ("bool", .object(["permissionLevel": .bool(true)])),
            ("null", .object(["permissionLevel": .null])),
            ("absent", .object(["enableAutonomy": .bool(true)])),
        ]
        for (label, policy) in refusals {
            let root = try gateTempRoot("wideopen-deny-\(label)")
            defer { try? FileManager.default.removeItem(at: root) }
            try seedTrustPolicy(policy, at: root)
            let allowed = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: root)
            #expect(!allowed, "\(label) must NOT read as wide-open trust")
        }
    }

    @Test("wide-open trust fails closed on a missing or damaged policy file")
    func isWideOpenTrustFailsClosed() async throws {
        let missing = try gateTempRoot("wideopen-missing")
        defer { try? FileManager.default.removeItem(at: missing) }
        let noFile = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: missing)
        #expect(!noFile, "no policy on disk must never read as wide-open")

        let damaged = try gateTempRoot("wideopen-damaged")
        defer { try? FileManager.default.removeItem(at: damaged) }
        let path = BackgroundLoopsAssembly.trustPolicyPath(dataRoot: damaged)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: path)
        let corrupt = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: damaged)
        #expect(!corrupt, "an unreadable policy must never read as wide-open")
    }

    @Test("the background gate delegates to checked SecurityCenter authority")
    func wideOpenGateUsesCanonicalCheckedAuthority() throws {
        // This gate must never return to raw permission-label matching: that
        // ignores expiry, corruption, explicit blocks, and origin admission.
        let gate = try AppSourceScraping.appSource("BackgroundLoopsAssembly+WorkshopExecution.swift")
        #expect(gate.contains(".fullMacYoloAuthority("))
        #expect(gate.contains("return assessment.admitted"))
        #expect(!gate.contains("policy[\"permissionLevel\"]"))
    }

    // MARK: - workshopEnabledGate

    @Test("workshop autonomy gate opens only for a literal boolean true")
    func workshopEnabledGateRequiresExplicitBooleanTrue() async throws {
        let openRoot = try gateTempRoot("workshop-on")
        defer { try? FileManager.default.removeItem(at: openRoot) }
        try seedTrustPolicy(.object(["enableAutonomy": .bool(true)]), at: openRoot)
        let opened = await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: openRoot)
        #expect(opened)

        // Truthy-looking non-bools must NOT open an expensive autonomous lane.
        let refusals: [(String, JSONValue)] = [
            ("false", .object(["enableAutonomy": .bool(false)])),
            ("string-true", .object(["enableAutonomy": .string("true")])),
            ("int-1", .object(["enableAutonomy": .int(1)])),
            ("null", .object(["enableAutonomy": .null])),
            ("absent", .object(["permissionLevel": .string("full_mac_os")])),
        ]
        for (label, policy) in refusals {
            let root = try gateTempRoot("workshop-off-\(label)")
            defer { try? FileManager.default.removeItem(at: root) }
            try seedTrustPolicy(policy, at: root)
            let opened = await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: root)
            #expect(!opened, "\(label) must not enable workshop autonomy")
        }

        // Fail-closed on damage.
        let damaged = try gateTempRoot("workshop-damaged")
        defer { try? FileManager.default.removeItem(at: damaged) }
        let path = BackgroundLoopsAssembly.trustPolicyPath(dataRoot: damaged)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: path)
        let corrupt = await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: damaged)
        #expect(!corrupt)
    }

    @Test("the two autonomy gates read different keys and cannot be collapsed")
    func autonomyGatesAreIndependent() async throws {
        // Wide-open posture alone must not enable workshop autonomy, and
        // enableAutonomy alone must not imply wide-open (unattended tool steps).
        let a = try gateTempRoot("gates-a")
        defer { try? FileManager.default.removeItem(at: a) }
        try seedTrustPolicy(.object(["permissionLevel": .string("full_mac_os")]), at: a)
        let aWide = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: a)
        let aWorkshop = await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: a)
        #expect(aWide && !aWorkshop)

        let b = try gateTempRoot("gates-b")
        defer { try? FileManager.default.removeItem(at: b) }
        try seedTrustPolicy(.object([
            "enableAutonomy": .bool(true),
            "permissionLevel": .string("workspace"),
        ]), at: b)
        let bWide = await BackgroundLoopsAssembly.isWideOpenTrust(dataRoot: b)
        let bWorkshop = await BackgroundLoopsAssembly.workshopEnabledGate(dataRoot: b)
        #expect(!bWide && bWorkshop)
    }

    // MARK: - validateStampedPath

    @Test("a REPO_PATH stamp is trusted only when every marker exists on the canonical path")
    func validateStampedPathRequiresAllMarkers() throws {
        let markers = ["persona/SOUL.template.md", "script/init_persona.sh", "Package.swift"]

        func makeRepo(missing: String?) throws -> URL {
            let root = try gateTempRoot("stamp")
            for marker in markers where marker != missing {
                let url = root.appendingPathComponent(marker)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            return root
        }

        // Full marker set → trusted. Note the temp dir is itself under the
        // /var → /private/var symlink, so this ALSO pins the Phase-13
        // false-positive fix: a legitimate symlinked system path is accepted.
        let good = try makeRepo(missing: nil)
        defer { try? FileManager.default.removeItem(at: good) }
        #expect(good.path.hasPrefix("/var/") || good.path.hasPrefix("/private/var/"),
                "this test relies on the temp dir being a symlinked system path")
        #expect(NativeAgentPaths.validateStampedPath(good) == good)

        // Any single missing marker → refused. Drop one at a time so the test
        // bites on a marker being removed from the list, not just on "empty dir".
        for missing in markers {
            let partial = try makeRepo(missing: missing)
            defer { try? FileManager.default.removeItem(at: partial) }
            #expect(NativeAgentPaths.validateStampedPath(partial) == nil,
                    "a stamp missing \(missing) must not be trusted")
        }

        // A path that does not exist at all.
        let absent = good.appendingPathComponent("does-not-exist", isDirectory: true)
        #expect(NativeAgentPaths.validateStampedPath(absent) == nil)
    }

    @Test("a symlink to a valid repo is accepted through its canonical target")
    func validateStampedPathFollowsSymlinks() throws {
        let real = try gateTempRoot("stamp-real")
        defer { try? FileManager.default.removeItem(at: real) }
        for marker in ["persona/SOUL.template.md", "script/init_persona.sh", "Package.swift"] {
            let url = real.appendingPathComponent(marker)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let linkParent = try gateTempRoot("stamp-link")
        defer { try? FileManager.default.removeItem(at: linkParent) }
        let link = linkParent.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        // Accepted, and returned VERBATIM (the caller's stamp string), not
        // silently rewritten to the resolved path.
        #expect(NativeAgentPaths.validateStampedPath(link) == link)
    }

    // MARK: - NATIVE_AGENT_DATA_ROOT

    @Test("an EMPTY NATIVE_AGENT_DATA_ROOT means unset, not the empty path")
    func emptyDataRootEnvIsTreatedAsUnset() throws {
        // NEVER mutate the process env for this key: `script/test.sh` exports it
        // as the suite's hermetic root, and a parallel test resolving the
        // default root inside the mutation window would write to the LIVE
        // repo `data/`. The resolver takes an injected environment — use it.
        let explicit = try gateTempRoot("dataroot")
        defer { try? FileManager.default.removeItem(at: explicit) }

        let set = PersistenceCore.defaultDataRoot(environment: ["NATIVE_AGENT_DATA_ROOT": explicit.path])
        #expect(set.standardizedFileURL.path == explicit.standardizedFileURL.path)

        let empty = PersistenceCore.defaultDataRoot(environment: ["NATIVE_AGENT_DATA_ROOT": ""])
        let unset = PersistenceCore.defaultDataRoot(environment: [:])
        #expect(!empty.path.isEmpty, "empty env must not resolve to the empty path")
        #expect(empty.standardizedFileURL.path != explicit.standardizedFileURL.path)
        #expect(empty.standardizedFileURL.path == unset.standardizedFileURL.path,
                "empty env and unset env must resolve identically (Python parity)")

        // The APP-side resolver must carry the same empty-means-unset rule, or a
        // public launch would skip both the data-root pin and the blank-slate
        // quarantine while Core still resolved its own way. Both guards read the
        // env through the same `?? ""` + isEmpty shape.
        let paths = try AppSourceScraping.appSource("NativeAgentPaths.swift")
        let emptyIsUnset = AppSourceScraping.occurrences(
            of: "(ProcessInfo.processInfo.environment[\"NATIVE_AGENT_DATA_ROOT\"] ?? \"\").isEmpty",
            in: paths
        )
        #expect(emptyIsUnset >= 2,
                "both the dataRoot pin and the blank-slate quarantine must treat empty as unset")
    }

    // MARK: - workshop planner catalog

    @Test("planner tool descriptions carry the arg list with required args starred")
    func plannerToolDescriptionCarriesStarredArgs() throws {
        func schema(_ dict: [String: Any]) throws -> LLMToolSchema {
            LLMToolSchema(
                name: "shell",
                description: "Run a shell command",
                parametersJSON: try JSONSerialization.data(withJSONObject: dict)
            )
        }

        // The exact 2026-06-15 regression: without the suffix the planner emitted
        // a shell step with no `cmd` and the execution failed as "missing_cmd".
        let withRequired = try schema([
            "type": "object",
            "properties": ["cmd": ["type": "string"], "timeout": ["type": "number"]],
            "required": ["cmd"],
        ])
        #expect(workshopPlannerToolDescription(withRequired)
                == "Run a shell command [args: cmd*, timeout]")

        // Sorted, so the string is stable across JSON key ordering.
        let manyArgs = try schema([
            "type": "object",
            "properties": ["zeta": ["type": "string"], "alpha": ["type": "string"], "mid": ["type": "string"]],
            "required": ["zeta", "alpha"],
        ])
        #expect(workshopPlannerToolDescription(manyArgs)
                == "Run a shell command [args: alpha*, mid, zeta*]")

        // No properties at all → bare description, never a bogus "[args: ]".
        let noProps = try schema(["type": "object", "properties": [:]])
        #expect(workshopPlannerToolDescription(noProps) == "Run a shell command")
        let notAnObject = LLMToolSchema(
            name: "x", description: "Run a shell command", parametersJSON: Data("null".utf8))
        #expect(workshopPlannerToolDescription(notAnObject) == "Run a shell command")
    }

    @Test("the planner catalog is configured synchronously at launch, before any detached task")
    func plannerCatalogIsConfiguredBeforeDetachedWork() throws {
        // Silent zero: without this injection availableConnectorActions() is []
        // and every unattended execution can only emit chat.synthesize steps —
        // she DESCRIBES the work and the receipt still says "completed".
        let launch = try AppSourceScraping.appSource("AppDelegate+Launch.swift")
        let needle = "WorkshopPlannerCatalog.configure(makeWorkshopPlannerConnectorActionsProvider())"
        let lines = launch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let at = lines.firstIndex(where: { $0.contains(needle) }) else {
            Issue.record("the launch path no longer configures the workshop planner catalog")
            return
        }
        let call = lines[at].trimmingCharacters(in: .whitespaces)
        #expect(!call.hasPrefix("//"), "the catalog injection must not be commented out")
        // Statement level, not wrapped in a detached task: 8-space body indent
        // inside applicationDidFinishLaunching. A `Task.detached { … }` wrapper
        // would indent it further and re-open the launch race this fixed.
        let indent = lines[at].prefix { $0 == " " }.count
        #expect(indent == 8, "the catalog injection is nested \(indent) deep — it is no longer a plain launch statement")
        // The rationale (why it must precede any detached loop/trigger task)
        // stays attached to the call site.
        let preamble = lines[max(0, at - 8)..<at].joined(separator: "\n")
        #expect(preamble.contains("SYNCHRONOUSLY"),
                "the synchronous-ordering rationale must stay attached to the call site")
        #expect(AppSourceScraping.occurrences(of: needle, in: launch) == 1)
    }
}
