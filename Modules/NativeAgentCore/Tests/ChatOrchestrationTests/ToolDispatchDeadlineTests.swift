import Testing
import Foundation
@testable import ChatOrchestration
import NativeAgentCore
import PersistenceCore

// Trust loop #3 (2026-06-15): surface-scoped per-tool-dispatch deadline.
// Proves hung tools auto-fail to a clean slot error on unattended and
// interactive surfaces, explicit long timeouts retain their requested window,
// and the env override / disable behaves.

// MARK: - Fakes

/// A dispatch client whose single tool blocks for `delayNs` (cooperatively, via
/// Task.sleep) before returning. Models a hung tool: when the deadline fires
/// and cancelAll() lands, the sleep throws CancellationError and the child
/// exits, so the group can return the timeout result.
private final class HangingDispatch: ToolDispatchClient, @unchecked Sendable {
    let delayNs: UInt64
    let result: JSONValue
    init(delayNs: UInt64, result: JSONValue = .string("ok")) {
        self.delayNs = delayNs
        self.result = result
    }
    func dispatch(tool: String, input: [String: JSONValue], surface: String) async throws -> JSONValue {
        if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }
        return result
    }
    func listAvailableTools() async throws -> [String] { ["hang"] }
}

private func prepared(_ name: String) -> SwiftNativeTurnEngine.PreparedToolCall {
    SwiftNativeTurnEngine.PreparedToolCall(
        pairedId: "id-\(name)", internalName: name, dispatchInput: [:]
    )
}

/// Pull the `error` string out of a slot result, if it is an error object.
private func slotErrorString(_ value: JSONValue) -> String? {
    guard case .object(let obj) = value, case .string(let s)? = obj["error"] else { return nil }
    return s
}

// MARK: - Surface taxonomy (pure, no env)

@Suite("ToolDispatchDeadline: surface taxonomy")
struct ToolDispatchDeadlineTaxonomySuite {
    @Test
    func unattendedSurfacesClassified() {
        for s in ["autonomy", "mission", "missions", "background",
                  "swarm", "swarms", "worker", "workers", "training",
                  "AUTONOMY", "  Mission  ", "Background"] {
            #expect(ToolDispatchDeadline.isUnattended(surface: s),
                    "expected \(s) unattended")
        }
    }

    @Test
    func interactiveSurfacesClassified() {
        for s in ["chat", "telegram", "ios", "icloud", "iphone", "ipad",
                  "mobile", "watch", "remote", "", "  ", "Chat"] {
            #expect(!ToolDispatchDeadline.isUnattended(surface: s),
                    "expected \(s) interactive")
        }
    }

    @Test
    func interactiveSurfacesHaveGenerousFiniteBackstop() {
        let expected = UInt64(ToolDispatchDeadline.defaultInteractiveSeconds * 1_000_000_000)
        for s in ["chat", "telegram", "ios", "mobile", "icloud", ""] {
            #expect(ToolDispatchDeadline.timeoutNanos(forSurface: s) == expected,
                    "expected \(s) to have the interactive recovery deadline")
        }
    }
}

// MARK: - Env-driven config + race behavior (serialized: mutates process env)

@Suite("ToolDispatchDeadline: config + race", .serialized)
struct ToolDispatchDeadlineRaceSuite {
    private let envVar = ToolDispatchDeadline.envVar

    @Test
    func unattendedDefaultWhenEnvUnset() {
        unsetenv(envVar)
        let expected = UInt64(ToolDispatchDeadline.defaultUnattendedSeconds * 1_000_000_000)
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "autonomy") == expected)
        // Default sits above invoke_claude's <=3600s self-bound so it never
        // clips a legit long tool.
        #expect(ToolDispatchDeadline.defaultUnattendedSeconds > 3600)
    }

    @Test
    func envOverrideAppliesToEverySurface() {
        setenv(envVar, "0.5", 1)
        defer { unsetenv(envVar) }
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "mission") == 500_000_000)
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "chat") == 500_000_000)
    }

    @Test
    func envZeroOrNegativeDisablesEvenUnattended() {
        setenv(envVar, "0", 1)
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "autonomy") == 0)
        setenv(envVar, "-5", 1)
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "autonomy") == 0)
        setenv(envVar, "nonsense", 1)
        // Unparseable -> falls back to default (non-zero), not a crash.
        #expect(ToolDispatchDeadline.timeoutNanos(forSurface: "autonomy") > 0)
        unsetenv(envVar)
    }

    @Test
    func explicitToolTimeoutKeepsRequestedWindowPlusCleanupMargin() {
        unsetenv(envVar)
        let nanos = ToolDispatchDeadline.timeoutNanos(
            toolName: "invoke_codex",
            input: ["timeout_seconds": .int(3600)],
            surface: "chat"
        )
        #expect(nanos == UInt64(3630 * 1_000_000_000))
    }

    @Test(.timeLimit(.minutes(1)))
    func hungToolOnUnattendedSurfaceTimesOutToSlotError() async {
        setenv(envVar, "0.4", 1)  // 400ms backstop
        defer { unsetenv(envVar) }
        // Tool blocks for 30s — far past the deadline.
        let tools = HangingDispatch(delayNs: 30 * 1_000_000_000)
        let clock = ContinuousClock()
        let start = clock.now
        let (result, isError) = await SwiftNativeTurnEngine.runSingleDispatch(
            prepared: prepared("hang"), modelId: "m",
            surface: "autonomy", tools: tools, progress: nil
        )
        let elapsed = clock.now - start
        #expect(isError, "a hung dispatch must surface as a slot error")
        let err = slotErrorString(result)
        #expect(err?.contains("dispatch deadline") == true, "got: \(err ?? "nil")")
        #expect(err?.contains("hang") == true)
        // Fired on the ~400ms deadline, NOT after the 30s hang.
        #expect(elapsed < .seconds(5), "deadline should fire fast; took \(elapsed)")
    }

    @Test(.timeLimit(.minutes(1)))
    func fastToolUnderDeadlineReturnsNormally() async {
        setenv(envVar, "5", 1)  // generous 5s backstop
        defer { unsetenv(envVar) }
        let tools = HangingDispatch(delayNs: 10_000_000, result: .string("done"))  // 10ms
        let (result, isError) = await SwiftNativeTurnEngine.runSingleDispatch(
            prepared: prepared("hang"), modelId: "m",
            surface: "mission", tools: tools, progress: nil
        )
        #expect(!isError)
        #expect(result == .string("done"))
    }

    @Test(.timeLimit(.minutes(1)))
    func fastInteractiveToolReturnsNormallyUnderDeadline() async {
        setenv(envVar, "0.1", 1)
        defer { unsetenv(envVar) }
        let tools = HangingDispatch(delayNs: 5_000_000, result: .string("chatok"))  // 5ms
        let (result, isError) = await SwiftNativeTurnEngine.runSingleDispatch(
            prepared: prepared("hang"), modelId: "m",
            surface: "chat", tools: tools, progress: nil
        )
        #expect(!isError)
        #expect(result == .string("chatok"))
    }

    @Test(.timeLimit(.minutes(1)))
    func nonthrowingRemoteErrorSetsProviderToolResultErrorBit() async {
        setenv(envVar, "0", 1)
        defer { unsetenv(envVar) }
        let remoteError: JSONValue = .object([
            "status": .string("ok"),
            "result": .object([
                "content": .array([]),
                "isError": .bool(true),
            ]),
        ])
        let tools = HangingDispatch(delayNs: 0, result: remoteError)
        let (result, isError) = await SwiftNativeTurnEngine.runSingleDispatch(
            prepared: prepared("mcp__remote__send"), modelId: "m",
            surface: "chat", tools: tools, progress: nil
        )
        #expect(result == remoteError)
        #expect(isError)
    }

    @Test(.timeLimit(.minutes(1)))
    func hungInteractiveToolTimesOutToRecoverableSlotError() async {
        setenv(envVar, "0.4", 1)
        defer { unsetenv(envVar) }
        let tools = HangingDispatch(delayNs: 30 * 1_000_000_000)
        let (result, isError) = await SwiftNativeTurnEngine.runSingleDispatch(
            prepared: prepared("hang"), modelId: "m",
            surface: "chat", tools: tools, progress: nil
        )
        #expect(isError)
        #expect(slotErrorString(result)?.contains("dispatch deadline") == true)
    }
}
