import Foundation
import Testing
import PersistenceCore
import ChatOrchestration
import NativeAgentCore
import PersonaEngine
import ProviderRouting
import TrustCenter
@testable import NativeAgentApp

// Wave B — the membrane (H1, L12) and the session authorization (H5, M6).

// MARK: - test doubles

private func makeTempRoot() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WorkshopMembraneTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// An inner dispatcher that would happily run ANY tool — proves the membrane,
/// not the inner client, is what refuses a forbidden tool.
private struct PermissiveInner: ToolDispatchClient {
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        .object(["ran": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] {
        ["read_file", "mac_control", "write_file", "shell", "desk_read"]
    }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        [
            LLMToolSchema(name: "read_file", description: "", parametersJSON: Data("{}".utf8)),
            LLMToolSchema(name: "mac_control", description: "", parametersJSON: Data("{}".utf8)),
            LLMToolSchema(name: "write_file", description: "", parametersJSON: Data("{}".utf8)),
            LLMToolSchema(name: "tool_load", description: "", parametersJSON: Data("{}".utf8)),
        ]
    }
}

/// A Sendable flag the injected turnExecutor can flip from concurrent code.
private actor CalledFlag {
    private(set) var called = false
    func mark() { called = true }
    func value() -> Bool { called }
}

private actor CallCounter {
    private var count = 0
    func mark() { count += 1 }
    func value() -> Int { count }
}

private actor ExecutionState {
    private var active = false
    private var cancellationObserved = false
    func begin() { active = true }
    func cancelled() { cancellationObserved = true }
    func end() { active = false }
    func snapshot() -> (active: Bool, cancelled: Bool) { (active, cancellationObserved) }
}

private actor DispatchRecorder {
    private var tools: [String] = []
    func record(_ tool: String) { tools.append(tool) }
    func snapshot() -> [String] { tools }
}

private struct RecordingPermissiveInner: ToolDispatchClient {
    let recorder: DispatchRecorder
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        await recorder.record(tool)
        return .object(["ran": .string(tool)])
    }
    func listAvailableTools() async throws -> [String] {
        ["read_file", "write_file", "tool_load", "mac_control"]
    }
    func listAvailableToolSchemas() async throws -> [LLMToolSchema] {
        try await PermissiveInner().listAvailableToolSchemas()
    }
}

private struct WorkshopTestRouter: ProviderRoutingProtocol {
    func listProviders() async throws -> [Provider] { [] }
    func getProvider(id: String) async throws -> Provider { throw ProviderRoutingError.providerNotFound }
    func configureProvider(id: String, config: JSONValue) async throws -> Provider { throw ProviderRoutingError.invalidRequest }
    func testProvider(id: String) async throws -> ProviderRouting.ProviderTestResult {
        ProviderRouting.ProviderTestResult(rawResponse: .null)
    }
    func getModelPreferences() async throws -> ModelPreferences { ModelPreferences() }
    func saveModelConfig(_ body: JSONValue) async throws -> ModelPreferences { ModelPreferences() }
    func computeModelPreferences() async throws -> [String: SurfacePreference] {
        [
            "chat": SurfacePreference(surface: "chat", model: "test-model", reasoningEffort: "low"),
            "workshop": SurfacePreference(surface: "workshop", model: "test-model", reasoningEffort: "low"),
        ]
    }
    func pinnedModelStringForSurface(_ surface: String) async -> String? { nil }
    func activeProvidersForSurfaces() async -> [String: String] { [:] }
}

private final class WorkshopScriptedLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var schemas: [[String]] = []

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "done" }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        lock.withLock {
            schemas.append((tools ?? []).map(\.name))
            defer { callCount += 1 }
            return callCount == 0
                ? #"<tool_use id="read-1" name="read_file">{}</tool_use>"#
                : "done"
        }
    }

    func schemaSnapshots() -> [[String]] { lock.withLock { schemas } }
}

/// Ignores the advertised schema list and attempts the exact lazy-load escape
/// an adversarial provider response could synthesize. The turn must reject it
/// and keep every later provider schema snapshot ceilinged to the profile.
private final class WorkshopForcedLoadLLM: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var schemas: [[String]] = []

    func complete(prompt: String, system: String?, model: String?) async throws -> String { "done" }

    func completeMessages(
        messages: [LLMMessage],
        system: String?,
        model: String?,
        surface: String,
        tools: [LLMToolSchema]?
    ) async throws -> String {
        lock.withLock {
            schemas.append((tools ?? []).map(\.name))
            defer { callCount += 1 }
            return callCount == 0
                ? #"<tool_use id="load-1" name="tool_load">{"category":"builder"}</tool_use>"#
                : "done"
        }
    }

    func schemaSnapshots() -> [[String]] { lock.withLock { schemas } }
}

private func makeProfile(root: URL, handle: String = "desk_test") -> WorkshopToolProfile {
    WorkshopToolProfile(
        inner: PermissiveInner(),
        artifactWriter: WorkshopArtifactWriter(dataRoot: root, handle: handle)
    )
}

// MARK: - H1 / L12: the membrane refuses non-allowlisted tools

@Test func h1_membraneRejectsMacControlShellWriteFile() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = makeProfile(root: root)
    for forbidden in ["mac_control", "shell", "bash", "write_file", "commit_memory", "persona_append", "workshop_submit", "invoke_claude", "tool_catalog", "list_tools", "tool_load"] {
        await #expect(throws: WorkshopMembraneError.self) {
            _ = try await profile.dispatch(tool: forbidden, input: [:], surface: "workshop")
        }
    }
}

@Test func h1_membraneAllowsReadAndDeskTools() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = makeProfile(root: root)
    // A read tool delegates to inner (the permissive stub echoes it).
    let result = try await profile.dispatch(tool: "read_file", input: [:], surface: "workshop")
    if case .object(let obj) = result, case .string(let ran)? = obj["ran"] {
        #expect(ran == "read_file")
    } else {
        Issue.record("read_file should delegate to inner")
    }
}

@Test func h1_membraneSchemasAreCeilingedAndIncludeArtifactWriter() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = makeProfile(root: root)
    let names = Set(try await profile.listAvailableToolSchemas().map(\.name))
    #expect(names.contains("read_file"))
    #expect(names.contains(WorkshopToolProfile.artifactToolName))
    #expect(!names.contains("mac_control"), "the model must never even SEE a forbidden tool")
    #expect(!names.contains("write_file"))
    #expect(!names.contains("tool_catalog"), "generic discovery must not reveal/re-expand the inner catalog")
    #expect(!names.contains("tool_load"), "same-turn lazy loading must remain outside the membrane")
}

@Test func h1_ephemeralTurnUsesProfileForSchemasAndDispatch() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = DispatchRecorder()
    let profile = WorkshopToolProfile(
        inner: RecordingPermissiveInner(recorder: recorder),
        artifactWriter: WorkshopArtifactWriter(dataRoot: root, handle: "desk_ephemeral")
    )
    let router = WorkshopTestRouter()
    let llm = WorkshopScriptedLLM()
    let trust = SwiftNativeTrustCenter(dataRoot: root)
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root, dataRoot: root),
        memory: nil,
        router: router,
        trust: trust,
        llm: llm,
        tools: profile,
        memoryPromoter: nil
    )
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: profile,
        llm: llm,
        dataRoot: root,
        trust: trust,
        promoter: nil
    )

    let response = try await client.runEphemeralToolTurn(
        message: "Read one bounded source.",
        autonomyResolver: WorkshopAutonomyResolver(base: trust),
        surface: "workshop"
    )
    #expect(response.output == "done")
    #expect(await recorder.snapshot() == ["read_file"],
            "runEphemeralToolTurn must dispatch through the passed Workshop profile")
    let exposed = Set(llm.schemaSnapshots().flatMap { $0 })
    #expect(exposed.contains("read_file"))
    #expect(exposed.contains(WorkshopToolProfile.artifactToolName))
    #expect(!exposed.contains("write_file"))
    #expect(!exposed.contains("tool_load"))
    #expect(!exposed.contains("mac_control"))
}

@Test func h1_forcedToolLoadCannotExpandEphemeralWorkshopSchemas() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let recorder = DispatchRecorder()
    let profile = WorkshopToolProfile(
        inner: RecordingPermissiveInner(recorder: recorder),
        artifactWriter: WorkshopArtifactWriter(dataRoot: root, handle: "desk_forced_load")
    )
    let router = WorkshopTestRouter()
    let llm = WorkshopForcedLoadLLM()
    let trust = SwiftNativeTrustCenter(dataRoot: root)
    let engine = SwiftNativeTurnEngine(
        persona: hermeticPersona(root: root, dataRoot: root),
        memory: nil,
        router: router,
        trust: trust,
        llm: llm,
        tools: profile,
        memoryPromoter: nil
    )
    let client = SwiftNativeChatOrchestrationClient(
        engine: engine,
        tools: profile,
        llm: llm,
        dataRoot: root,
        trust: trust,
        promoter: nil
    )

    _ = try await client.runEphemeralToolTurn(
        message: "Attempt a forbidden lazy load.",
        autonomyResolver: WorkshopAutonomyResolver(base: trust),
        surface: "workshop"
    )
    #expect(await recorder.snapshot().isEmpty,
            "a forged tool_load call must never reach the permissive inner dispatcher")
    let snapshots = llm.schemaSnapshots()
    #expect(snapshots.count == 2)
    for names in snapshots {
        let exposed = Set(names)
        #expect(!exposed.contains("tool_load"))
        #expect(!exposed.contains("write_file"))
        #expect(!exposed.contains("mac_control"))
        #expect(exposed.isSubset(of: WorkshopToolProfile.allowed.union([
            WorkshopToolProfile.artifactToolName,
        ])))
    }
}

@Test func l12_artifactWriterRejectsSymlinkParentsAndDoesNotFollowFinalSymlink() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let handleRoot = root.appendingPathComponent("workshop/desk_symlink", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: handleRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: handleRoot.appendingPathComponent("escape"),
        withDestinationURL: outside
    )
    let writer = WorkshopArtifactWriter(dataRoot: root, handle: "desk_symlink")
    #expect(throws: (any Error).self) {
        _ = try writer.write(relativePath: "escape/pwned.md", content: "escaped")
    }
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("pwned.md").path))

    let outsideFile = outside.appendingPathComponent("sentinel.md")
    try Data("outside".utf8).write(to: outsideFile)
    let finalLink = handleRoot.appendingPathComponent("findings.md")
    try FileManager.default.createSymbolicLink(at: finalLink, withDestinationURL: outsideFile)
    _ = try writer.write(relativePath: "findings.md", content: "inside")
    #expect(try String(contentsOf: outsideFile, encoding: .utf8) == "outside")
    #expect(try String(contentsOf: finalLink, encoding: .utf8) == "inside")
    #expect(try finalLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
}

@Test func l12_artifactToolRejectsUnknownPathLikeArguments() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = makeProfile(root: root)
    await #expect(throws: WorkshopMembraneError.self) {
        _ = try await profile.dispatch(
            tool: WorkshopToolProfile.artifactToolName,
            input: [
                "path": .string("findings.md"),
                "content": .string("safe"),
                "destination": .string("/tmp/escape.md"),
            ],
            surface: "workshop"
        )
    }
}

// MARK: - L12: artifact path containment

@Test func l12_artifactWriterContainsPaths() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let writer = WorkshopArtifactWriter(dataRoot: root, handle: "desk_abc")

    // Legit relative path is accepted and lands under the handle root.
    let ok = try writer.containedURL(relativePath: "notes/day1.md")
    #expect(ok.relativePath == "notes/day1.md")
    #expect(ok.url.path.contains("/workshop/desk_abc/notes/day1.md"))

    // Every escape shape is rejected.
    for bad in ["../escape.md", "notes/../../escape.md", "/etc/passwd", "a\\b.md", "..", ".", "", "note\u{0}.md", "sub//x.md"] {
        #expect(throws: WorkshopMembraneError.self) {
            _ = try writer.containedURL(relativePath: bad)
        }
    }
}

@Test func l12_artifactWriteThroughMembraneWritesUnderRootOnly() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let profile = makeProfile(root: root, handle: "desk_xyz")
    let res = try await profile.dispatch(
        tool: WorkshopToolProfile.artifactToolName,
        input: ["path": .string("findings.md"), "content": .string("hello")],
        surface: "workshop")
    if case .object(let obj) = res, case .string(let status)? = obj["status"] {
        #expect(status == "ok")
    } else {
        Issue.record("artifact write should return status ok")
    }
    let written = root.appendingPathComponent("workshop/desk_xyz/findings.md")
    #expect(FileManager.default.fileExists(atPath: written.path))
    #expect(try String(contentsOf: written, encoding: .utf8) == "hello")

    // An escaping write through the membrane is refused (nothing lands outside).
    await #expect(throws: WorkshopMembraneError.self) {
        _ = try await profile.dispatch(
            tool: WorkshopToolProfile.artifactToolName,
            input: ["path": .string("../../escape.md"), "content": .string("x")],
            surface: "workshop")
    }
}

// MARK: - H5: triggerSource forgery

@Test func h5_sessionRefusesAbsentReservation() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let flag = CalledFlag()
    let session = WorkshopSession(
        dataRoot: root, store: store,
        turnExecutor: { _, _ in await flag.mark(); return ("m", "o") })

    // A request naming a handle/reservation that does not exist in the store.
    let forged = WorkshopSessionRequest(
        handle: "desk_ghost", reservationId: "wres_forged", title: "x", promptSeed: "x")
    let receipt = await session.run(forged)
    #expect(receipt.status == .refused)
    #expect(await flag.value() == false, "a forged/absent reservation must refuse BEFORE the LLM (H5)")
}

@Test func h5_sessionRefusesMismatchedTriggerSource() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let flag = CalledFlag()
    let session = WorkshopSession(
        dataRoot: root, store: store,
        turnExecutor: { _, _ in await flag.mark(); return ("m", "o") })

    // An empty reservation id can never match the store → refuse.
    let bad = WorkshopSessionRequest(handle: "desk_x", reservationId: "", title: "x", promptSeed: "x")
    #expect(await session.run(bad).status == .refused)
    #expect(await flag.value() == false)
}

@Test func h5_sessionRunsOnRealReservation() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    // A real pursuit + real reservation is the ONLY thing that authorizes a run.
    let pursuit = Pursuit(
        why: "curiosity", evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-07-01", "2026-07-03"])]),
        doneLooksLike: "answered", abandonCondition: "3 sessions")
    let item = try await store.openPursuit(project: "p", title: "t", pursuit: pursuit)
    let day = DeskClock.dayStamp(Date())
    let res = try await store.reserveWorkSession(item.handle, day: day, slot: "s1")

    let session = WorkshopSession(
        dataRoot: root, store: store,
        turnExecutor: { req, _ in
            #expect(req.triggerSource == "workshop:\(item.handle):\(res)")
            return ("test-model", "did one step")
        })
    let receipt = await session.run(WorkshopSessionRequest(
        handle: item.handle, reservationId: res, title: "t", promptSeed: "work"))
    #expect(receipt.status == .completed)
    #expect(receipt.model == "test-model")
}

@Test func h5_completedReservationCannotReauthorizeSession() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let pursuit = Pursuit(
        why: "curiosity", evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-07-01", "2026-07-03"])]),
        doneLooksLike: "answered", abandonCondition: "3 sessions")
    let item = try await store.openPursuit(project: "p", title: "t", pursuit: pursuit)
    let res = try await store.reserveWorkSession(item.handle, day: DeskClock.dayStamp(Date()), slot: "stale")
    _ = try await store.completeWorkSession(item.handle, reservationId: res, receipt: "already done")
    let flag = CalledFlag()
    let session = WorkshopSession(
        dataRoot: root, store: store,
        turnExecutor: { _, _ in await flag.mark(); return ("m", "o") })

    let receipt = await session.run(WorkshopSessionRequest(
        handle: item.handle, reservationId: res, title: "t", promptSeed: "work"))
    #expect(receipt.status == .refused)
    #expect(await flag.value() == false, "a completed reservation must never reauthorize provider work")
}

@Test func h5_reservationClaimIsOneShotAcrossSessionInstances() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let pursuit = Pursuit(
        why: "curiosity", evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-07-01", "2026-07-03"])]),
        doneLooksLike: "answered", abandonCondition: "3 sessions")
    let item = try await store.openPursuit(project: "p", title: "t", pursuit: pursuit)
    let res = try await store.reserveWorkSession(item.handle, day: DeskClock.dayStamp(Date()), slot: "once")
    let calls = CallCounter()
    let executor: @Sendable (WorkshopSessionRequest, any ToolDispatchClient) async throws -> (model: String, output: String) = { _, _ in
        await calls.mark()
        return ("m", "o")
    }
    let request = WorkshopSessionRequest(handle: item.handle, reservationId: res, title: "t", promptSeed: "work")
    #expect(await WorkshopSession(dataRoot: root, store: store, turnExecutor: executor).run(request).status == .completed)
    #expect(await WorkshopSession(dataRoot: root, store: store, turnExecutor: executor).run(request).status == .refused)
    #expect(await calls.value() == 1, "a visible reservation id authorizes at most one execution attempt")
}

@Test func h5_reservationClaimRejectsSymlinkedWorkshopParent() throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let outside = makeTempRoot(); defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("workshop"),
        withDestinationURL: outside
    )

    let claimed = WorkshopReservationClaimStore(dataRoot: root).claim(
        handle: "desk_safe",
        reservationId: "wres_safe_2026-07-11_b1"
    )
    #expect(!claimed, "the authorization ledger must not follow a symlinked Workshop parent")
    #expect(!FileManager.default.fileExists(
        atPath: outside.appendingPathComponent(
            "reservation_claims/wres_safe_2026-07-11_b1.claim"
        ).path
    ), "a refused claim must not create an authorization marker outside dataRoot")
}

// MARK: - M6: bounded session — never an infinite wedge

@Test func m6_hangingTurnResolvesToFiniteBlockedReceipt() async throws {
    let root = makeTempRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = SwiftNativeDeskStore(dataRoot: root)
    let pursuit = Pursuit(
        why: "curiosity", evidence: PromotionDossier(citations: [.feltSalience(dates: ["2026-07-01", "2026-07-03"])]),
        doneLooksLike: "answered", abandonCondition: "3 sessions")
    let item = try await store.openPursuit(project: "p", title: "t", pursuit: pursuit)
    let day = DeskClock.dayStamp(Date())
    let res = try await store.reserveWorkSession(item.handle, day: day, slot: "s1")

    // A turn that never returns — the exact wedge Workshop+Executor.swift:154
    // leaves open by default. The session's finite deadline must win.
    let state = ExecutionState()
    let session = WorkshopSession(
        dataRoot: root, store: store, deadlineSeconds: 0.2,
        turnExecutor: { _, _ in
            await state.begin()
            do {
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                await state.end()
                return ("never", "never")
            } catch {
                await state.cancelled()
                await state.end()
                throw error
            }
        })
    let startedAt = Date()
    let receipt = await session.run(WorkshopSessionRequest(
        handle: item.handle, reservationId: res, title: "t", promptSeed: "work"))
    #expect(receipt.status == .blocked, "a wedged turn resolves to a finite needs-User state, not an infinite wait")
    // 10s, not 1s: the claim is "the 0.2s deadline won, not the 60s wedge" —
    // well below the wedge still proves that, while tight bounds lose to
    // scheduler noise under full-suite parallelism (2.87s overshoot observed
    // elsewhere in this suite on a loaded machine).
    #expect(Date().timeIntervalSince(startedAt) < 10.0, "the configured subsecond deadline must win over the wedged turn")
    let execution = await state.snapshot()
    #expect(execution.cancelled, "the losing provider/tool task must receive cancellation")
    #expect(!execution.active, "no provider/tool task may remain alive after the blocked receipt")
}
