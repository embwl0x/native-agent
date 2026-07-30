import Foundation
import Testing
@testable import PersistenceCore

@Suite("NativeAgentSecretRedactor")
struct NativeAgentSecretRedactorTests {
    @Test("canonical patterns redact with stable digest-bearing labels")
    func canonicalPatterns() {
        let samples: [(String, String)] = [
            ("-----BEGIN PRIVATE KEY-----secret-----END PRIVATE KEY-----", "PRIVATE_KEY"),
            ("ghp_" + String(repeating: "A", count: 24), "GITHUB_TOKEN"),
            ("sk-" + String(repeating: "b", count: 24), "OPENAI_KEY"),
            // Pattern order is part of the inherited contract: OPENAI_KEY
            // consumes this sk-ant-shaped sample before ANTHROPIC_KEY runs.
            ("sk-ant-" + String(repeating: "c", count: 24), "OPENAI_KEY"),
            ("sk_live_" + String(repeating: "D", count: 20), "STRIPE_KEY"),
            ("xoxb-" + String(repeating: "e", count: 24), "SLACK_TOKEN"),
            ("AIza" + String(repeating: "F", count: 25), "GOOGLE_API_KEY"),
            ("Bearer " + String(repeating: "g", count: 24), "BEARER_TOKEN"),
        ]

        for (secret, kind) in samples {
            let redacted = NativeAgentSecretRedactor.redactText("before \(secret) after")
            #expect(!redacted.contains(secret))
            #expect(redacted.contains("[REDACTED_\(kind):"))
            #expect(redacted.hasPrefix("before "))
            #expect(redacted.hasSuffix(" after"))
        }
    }

    @Test("nested JSON values redact without changing non-string leaves")
    func nestedValues() {
        let secret = "sk-" + String(repeating: "x", count: 32)
        let input: JSONValue = .object([
            "array": .array([.string(secret), .int(7)]),
            "flag": .bool(true),
        ])

        guard case .object(let object) = NativeAgentSecretRedactor.redactValue(input),
              case .array(let array)? = object["array"] else {
            Issue.record("redacted value lost its object/array shape")
            return
        }
        if case .string(let redacted)? = array.first {
            #expect(redacted.contains("[REDACTED_OPENAI_KEY:"))
        } else {
            Issue.record("redacted secret is not a string")
        }
        #expect(array.dropFirst().first == .int(7))
        #expect(object["flag"] == .bool(true))
    }
}
