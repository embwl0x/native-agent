import Testing
import PersistenceCore
@testable import NativeAgentApp

@Test func chromeAcquireOmitsBlankRenderingModeForAutomaticRouteSelection() throws {
    for optional: JSONValue? in [nil, .null, .string(""), .string(" \t\n ")] {
        var input: [String: JSONValue] = ["initial_url": .string("https://x.com/example/status/123")]
        input["rendering_mode"] = optional
        let (effect, payload) = try AppChatToolDispatcher.chromeControlRequest(
            actionId: "browser.chrome_acquire", input: input)
        #expect(effect == .acquire)
        #expect(payload["mode"] == .string("create"))
        #expect(payload["initialUrl"] == input["initial_url"])
        #expect(payload["renderingMode"] == nil)
    }
}

@Test func chromeAcquirePreservesExplicitRenderingModeForExtensionValidation() throws {
    for mode in ["background_tab", "visible_work_window", "unsupported", " visible_work_window "] {
        let (_, payload) = try AppChatToolDispatcher.chromeControlRequest(
            actionId: "browser.chrome_acquire", input: ["rendering_mode": .string(mode)])
        #expect(payload["renderingMode"] == .string(mode))
    }
}
