import Foundation
import Testing
@testable import NativeAgentApp

// Ledger row `chat.persistence.resolveSessionId`: App Intents have no mounted
// chat selection, so this is their durable caller-side identity owner. It must
// retain one explicit session across separate shortcut executions rather than
// relying on persistence to mint an orphan UUID per call.
@Suite("NativeAgent App Intent chat session")
struct NativeAgentIntentSessionTests {
    @Test func repeatedResolutionRetainsOneCanonicalIntentConversation() throws {
        let suite = "NativeAgentIntentSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var generated = 0
        let first = try NativeAgentIntentSession.resolve(defaults: defaults) {
            generated += 1
            return " intent:shortcut-conversation "
        }
        let second = try NativeAgentIntentSession.resolve(defaults: defaults) {
            generated += 1
            return "intent:must-not-be-used"
        }

        #expect(first == "intent:shortcut-conversation")
        #expect(second == first)
        #expect(generated == 1, "a second App Intent call must reuse its durable identity")
        #expect(defaults.string(forKey: NativeAgentIntentSession.defaultsKey) == first)
    }

    @Test func damagedStoredSessionIsReplacedBeforeItCanReachPersistence() throws {
        let suite = "NativeAgentIntentSessionTests.repair.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("../outside-chat", forKey: NativeAgentIntentSession.defaultsKey)

        let resolved = try NativeAgentIntentSession.resolve(defaults: defaults) {
            "intent:repaired-shortcut-conversation"
        }

        #expect(resolved == "intent:repaired-shortcut-conversation")
        #expect(defaults.string(forKey: NativeAgentIntentSession.defaultsKey) == resolved)
    }
}
