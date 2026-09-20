import Testing
import MacControl
import NativeAgentCore
import PersistenceCore
@testable import NativeAgentApp

private actor SelfAppHost: MacFourVerbsHost {
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        MacControlResult(ok: action == "focus_app", action: action,
            output: .object([:]), error: action == "focus_app" ? nil : "self_inspection_unsupported",
            durationMs: 0, viaSwift: true)
    }
}

@Suite struct MacSelfAppRouteTests {
    @Test func successfulNavigationSurvivesUnavailablePageRead() async {
        let reply = await MacFourVerbs(host: SelfAppHost(), namedLocationRoots: []).go("NativeAgent")
        var calls = 0
        let result = await AppChatToolDispatcher.performMacSelfAppRoute(.object([
            "ok": .bool(reply.ok), "text": .string(reply.text), "detail": .object(reply.agentDetail)
        ])) { tool, input in
            calls += 1
            #expect(tool == "app_page_read")
            #expect(input == ["page": .string("current")])
            return .object(["status": .string("failed"), "reason": .string("app_window_unavailable")])
        }
        #expect(calls == 1)
        guard case .object(let payload) = result else { Issue.record("Expected navigation result"); return }
        #expect(payload["ok"] == .bool(true))
        #expect(payload["in_process_observation"] == .object([
            "status": .string("failed"), "reason": .string("app_window_unavailable")]))
    }

    @Test func settingsClickExecutesPageChangeInFirstCall() async {
        let reply = await MacFourVerbs(host: SelfAppHost(), namedLocationRoots: [])
            .act(verb: "click", target: "Settings")
        var calls = 0
        var page: String?
        let result = await AppChatToolDispatcher.performMacSelfAppRoute(.object([
            "ok": .bool(reply.ok), "detail": .object(reply.agentDetail)
        ])) { tool, input in
            calls += 1
            #expect(tool == "interaction_act")
            #expect(input["target"] == .string("composer"))
            #expect(input["verb"] == .string("set_page"))
            if case .string(let value) = input["value"] {
                page = QuietPages.page(named: value)?.id
            }
            return .object(["status": .string(page == "settings" ? "ok" : "failed")])
        }
        #expect(calls == 1)
        #expect(page == "settings")
        #expect(result == .object(["status": .string("ok"), "ok": .bool(true)]))
    }

    @Test func typingPreservesAppHandlerRefusal() async {
        let reply = await MacFourVerbs(host: SelfAppHost(), namedLocationRoots: [])
            .act(verb: "type", target: "composer", text: "hello")
        let result = await AppChatToolDispatcher.performMacSelfAppRoute(.object([
            "ok": .bool(reply.ok), "detail": .object(reply.agentDetail)
        ])) { tool, input in
            #expect(tool == "interaction_act")
            #expect(input["verb"] == .string("set_draft"))
            #expect(input["value"] == .string("hello"))
            return .object(["status": .string("failed"), "reason": .string("read_only")])
        }
        #expect(result == .object(["status": .string("failed"), "reason": .string("read_only"), "ok": .bool(false)]))
    }
}
