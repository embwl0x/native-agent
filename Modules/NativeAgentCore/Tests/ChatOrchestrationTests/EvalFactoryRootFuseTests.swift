import Foundation
import PersistenceCore
import Testing
@testable import ChatOrchestration
@testable import ProviderRouting

private final class CodexEnvironmentCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [String: String]?

    func record(_ environment: [String: String]?) {
        lock.withLock { captured = environment }
    }

    func value() -> [String: String]? {
        lock.withLock { captured }
    }
}

// Coverage-ledger fence `core.chat.persistence`:
//   * chat.factories.credentialFuse   (silent leak of real credentials + money)
//   * chat.factories.turnTraceBusRoot (silent zero across the whole fence)
//
// Both surfaces are ONE equality compare against the default data root, and
// both fail the same way: the failure is SUCCESS. A path-normalization drift
// that flips the compare gives a disposable root real provider adapters (real
// billing, real side effects, tests that pass faster), or hands a production
// client a scratch bus so data/turn_traces silently stops growing.
//
// The invariant these tests pin is the SAFE direction: only a byte-identical
// default root gets the canonical body / the shared bus. Anything else — a
// trailing-slash variant, a symlink, a re-derived path string — must land on
// the fail-closed side. If someone later makes either compare "smarter"
// (resolvingSymlinksInPath, path-string equality), these go red and force the
// leak question to be asked out loud instead of discovered in a bill.
@Suite("eval: chat factory root fuses")
struct EvalFactoryRootFuseTests {

    /// Name of the LLM client the factory installed. The fail-closed client is
    /// `private` to the factory file, so the type NAME is the observable.
    private func installedLLMTypeName(
        dataRoot: URL,
        providersRoot: URL? = nil
    ) async -> String {
        let client = makeChatOrchestrationClient(
            tools: MockToolDispatchClient(),
            dataRoot: dataRoot,
            providersRoot: providersRoot
        )
        return await String(describing: type(of: client.llm))
    }

    private static let failClosedClientName = "AlternateRootUnavailableChatLLMClient"

    private func tempRoot(_ tag: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-fuse-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every shape a "not the default root" URL arrives in — including the two
    /// that LOOK like the default root to a human — must get the throwing
    /// client, never an adapter holding real credentials.
    @Test func everyNonDefaultRootShapeGetsTheFailClosedClient() async throws {
        let scratch = try tempRoot("closed")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let defaultRoot = PersistenceCore.defaultDataRoot()
        let symlinkToDefault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-fuse-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkToDefault, withDestinationURL: defaultRoot)
        defer { try? FileManager.default.removeItem(at: symlinkToDefault) }

        let shapes: [(String, URL)] = [
            ("a plain disposable root", scratch),
            ("the same root without its directory flag", URL(fileURLWithPath: scratch.path)),
            ("the same root reached through a dot segment",
             scratch.appendingPathComponent(".", isDirectory: true)),
            // The dangerous one: a path that RESOLVES to the live root but is
            // not spelled like it. The compare must not follow the link.
            ("a symlink pointing at the live default root", symlinkToDefault),
        ]

        for (label, root) in shapes {
            let name = await installedLLMTypeName(dataRoot: root)
            #expect(
                name == Self.failClosedClientName,
                "\(label) must fail closed, got \(name)"
            )
        }
    }

    /// The fuse must not be stuck closed either: naming a credential root is
    /// the sanctioned way to get REAL adapters onto a disposable body (the
    /// personality-range bench's Layer 2 seam). If this regressed to always
    /// fail-closed, the bench would silently stop making real calls.
    @Test func anExplicitCredentialRootOpensTheFuse() async throws {
        let body = try tempRoot("body")
        let credentials = try tempRoot("creds")
        defer {
            try? FileManager.default.removeItem(at: body)
            try? FileManager.default.removeItem(at: credentials)
        }

        let name = await installedLLMTypeName(dataRoot: body, providersRoot: credentials)
        #expect(
            name != Self.failClosedClientName,
            "an explicitly named credential root must install the real adapters"
        )
    }

    /// Ledger row `chat.factory.credentialRootEnvOverride`.
    ///
    /// This executes the production factory and observes the environment it
    /// hands to its Codex adapter. It does not infer the values from a copied
    /// dictionary or spawn a real CLI process. A secondary body must never let
    /// its child refresh the ambient operator credentials.
    @Test func credentialRootBindsCodexChildEnvironmentAndNilKeepsItUnbound() async throws {
        let body = try tempRoot("codex-env-body")
        let credentials = try tempRoot("codex-env-credentials")
        defer {
            try? FileManager.default.removeItem(at: body)
            try? FileManager.default.removeItem(at: credentials)
        }

        let rootedCapture = CodexEnvironmentCapture()
        _ = makeChatOrchestrationClient(
            tools: MockToolDispatchClient(),
            dataRoot: body,
            providersRoot: credentials,
            codexAdapterFactory: { environment in
                rootedCapture.record(environment)
                return CodexAdapter()
            }
        )
        let rooted = try #require(rootedCapture.value())
        #expect(rooted["CODEX_HOME"] == credentials
            .appendingPathComponent("codex_home", isDirectory: true).path)
        #expect(rooted["NATIVE_AGENT_DATA_ROOT"] == credentials.path)
        #expect(rooted["CODEX_HOME"] != ProcessInfo.processInfo.environment["CODEX_HOME"])
        #expect(rooted["NATIVE_AGENT_DATA_ROOT"] != ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA_ROOT"])

        let ambientCapture = CodexEnvironmentCapture()
        _ = makeChatOrchestrationClient(
            tools: MockToolDispatchClient(),
            dataRoot: PersistenceCore.defaultDataRoot(),
            codexAdapterFactory: { environment in
                ambientCapture.record(environment)
                return CodexAdapter()
            }
        )
        #expect(ambientCapture.value() == nil,
                "without an explicit credential root, the factory must not impose a credential override")
    }

    /// The trace bus rides the same kind of compare. Identity — not equality of
    /// contents — is the property: a production client must be on the SAME
    /// object every in-process subscriber (Turn Inspector, live turn views) is
    /// listening to. A private bus with an identical persist path still makes
    /// every subscriber see nothing.
    @Test func onlyTheDefaultRootGetsTheSharedBus() throws {
        let defaultRoot = PersistenceCore.defaultDataRoot()
        #expect(makeChatTurnTraceBus(dataRoot: defaultRoot) === TurnTraceBus.shared)

        let scratch = try tempRoot("bus")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let symlinkToDefault = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("eval-bus-link-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlinkToDefault, withDestinationURL: defaultRoot)
        defer { try? FileManager.default.removeItem(at: symlinkToDefault) }

        for root in [
            scratch,
            URL(fileURLWithPath: scratch.path),
            // Spelled differently, resolves to the live root: it loses the
            // shared bus (subscribers go dark) while its persist lane still
            // writes THROUGH the link into the live feed. Named here so the
            // asymmetry is on the record, not discovered later.
            symlinkToDefault,
        ] {
            #expect(
                makeChatTurnTraceBus(dataRoot: root) !== TurnTraceBus.shared,
                "root \(root.path) must not borrow the shared bus"
            )
        }
    }

    /// Ledger row `speed.rem_pins.read` (core.substrate.organism).
    ///
    /// The production factory, rather than a hand-built engine, must hand its
    /// exact data root to the persisted REM-pin reader.  A factory regression
    /// that leaves `remPinsDataRoot` nil or points it at the process default
    /// makes this alternate-root pin disappear while chat otherwise assembles
    /// normally.
    @Test func productionFactoryReadsRemPinsFromItsInjectedDataRoot() async throws {
        let root = try tempRoot("rem-pins-root")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("persona", isDirectory: true)
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try "FACTORY-ROOT-PERSONA".write(
            to: persona.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8
        )
        try """
        {"GROWTH.md":[{"id":"factory-root-pin","text":"FACTORY-ROOT-REM-PIN","createdAt":"2026-08-24T12:00:00Z"}]}
        """.write(
            to: root.appendingPathComponent("rem_pins.json"), atomically: true, encoding: .utf8
        )

        let client = makeChatOrchestrationClient(
            tools: MockToolDispatchClient(), dataRoot: root
        )
        let engine = await client.engine
        let context = try await engine.buildTurnContext(
            surface: "chat", userMessage: "hello", personaOverride: nil,
            imageBlocks: [], includeClockContext: false
        )
        #expect(context.systemPrompt?.contains("FACTORY-ROOT-REM-PIN") == true)
    }
}
