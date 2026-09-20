import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

private actor FailureReplayHost: MacFourVerbsHost {
    let error: String
    var calls: [String] = []
    init(_ error: String) { self.error = error }
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        calls.append(action)
        return MacControlResult(ok: action == "focus_app", action: action,
            output: .object([:]), error: action == "focus_app" ? nil : error,
            durationMs: 0, viaSwift: true)
    }
}

@Suite struct MacControlFailureReplayTests {
    @Test(arguments: ["trust", "model", "think", "context"], ["", " card"])
    func composerCardsUseExactOpenCardRoute(card: String, suffix: String) async {
        let host = FailureReplayHost("self_inspection_unsupported")
        let reply = await MacFourVerbs(host: host).act(verb: "click", target: card + suffix)
        #expect(reply.detail["execute_in_process"] == .bool(true))
        #expect(reply.detail["next_action"] == .object([
            "tool": .string("interaction_act"),
            "input": .object(["target": .string("composer"), "verb": .string("open_card"), "value": .string(card)])]))
        #expect(await host.calls == ["look"])
    }

    @Test func selfWindowGoPreservesSuccessfulFocus() async {
        let host = FailureReplayHost("self_inspection_unsupported")
        let reply = await MacFourVerbs(host: host, namedLocationRoots: []).go("NativeAgent")
        #expect(reply.ok)
        #expect(reply.text.contains("Switched to NativeAgent."))
        #expect(await host.calls == ["look", "focus_app", "look"])
        #expect(reply.detail["next_action"] == .object([
            "tool": .string("app_page_read"), "input": .object(["page": .string("current")])]))
    }

    @Test func selfWindowActReturnsExactComposerInput() async {
        let host = FailureReplayHost("self_inspection_unsupported")
        let reply = await MacFourVerbs(host: host).act(verb: "type", target: "composer", text: "hello")
        #expect(reply.detail["next_action"] == .object([
            "tool": .string("interaction_act"),
            "input": .object(["target": .string("composer"), "verb": .string("set_draft"), "value": .string("hello")])]))
        #expect(await host.calls == ["look"])
    }

    @Test func selfWindowSettingsClickOffersExactPageChange() async {
        let host = FailureReplayHost("self_inspection_unsupported")
        let verbs = MacFourVerbs(host: host)
        let act = await verbs.act(verb: "click", target: "Settings")
        #expect(act.detail["execute_in_process"] == .bool(true))
        #expect(act.detail["next_action"] == .object([
            "tool": .string("interaction_act"),
            "input": .object(["target": .string("composer"), "verb": .string("set_page"), "value": .string("settings")])]))
        #expect(await host.calls == ["look"])
    }

}
