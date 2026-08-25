import Foundation
import Testing
@testable import NativeAgentCore

// Ledger rows: core.chatSessionID.normalizedPathComponent,
//              core.chatSessionID.isSafePathComponent
//
// Silent-failure class: WRONG VALUE / SECURITY. This pair is the path-traversal
// guard in front of every per-session store writer (LLMCallTelemetry,
// OutcomeFeedbackStore, ChatSessionRetention, ChatSessionAutocompactor,
// ChatSessionIndexReconciler, OutcomeTissueV2). Loosened, `../` escapes the
// session directory with no visible symptom; tightened, every telemetry and
// outcome row for a legitimate id is silently dropped. Both directions are
// asserted below, and the predicate is pinned to agree with the normalizer so
// the two halves of the guard cannot drift apart.

private let traversalShapedIDs: [String] = [
    "..",
    ".",
    "../",
    "../../etc/passwd",
    "..\\..\\windows",
    "a/../b",
    "a/b",
    "/absolute/path",
    "/",
    "\\",
    "chat\\session",
    ".hidden",
    ".",
    "",
    "   ",
    "\n\t ",
    "session\u{0}id",
    "session\u{7}bell",
    "line\nbreak",
    "carriage\rreturn",
    "tab\tsep",
    String(repeating: "a", count: 161),
    "a..b",
    "telegram:..",
]

private let legitimateIDs: [String] = [
    "telegram:1234567890",
    "telegram:-1001234567890",
    "drive-1a2b3c4d",
    "9f8e7d6c-5b4a-4321-9876-0123456789ab",
    "chat-2026-08-23T10-25-00Z",
    "main",
    "session.with.dots",           // interior dots are fine; only a LEADING dot is not
    "session_with_underscores",
    "session with spaces",
    "unicode-café-session",
    String(repeating: "a", count: 160),
]

@Test("every traversal-shaped session id normalizes to nil")
func chatSessionIDRejectsTraversalShapes() {
    for raw in traversalShapedIDs {
        #expect(
            NativeAgentChatSessionID.normalizedPathComponent(raw) == nil,
            "traversal-shaped id was accepted: \(raw.debugDescription)"
        )
    }
}

@Test("legitimate session ids round-trip unchanged")
func chatSessionIDAcceptsRealShapes() {
    for raw in legitimateIDs {
        #expect(
            NativeAgentChatSessionID.normalizedPathComponent(raw) == raw,
            "legitimate id was dropped: \(raw.debugDescription)"
        )
    }
}

@Test("nil in, nil out — the normalizer never invents a component")
func chatSessionIDNilPassthrough() {
    #expect(NativeAgentChatSessionID.normalizedPathComponent(nil) == nil)
}

@Test("surrounding whitespace is trimmed, not rejected, and the trimmed value is what is returned")
func chatSessionIDTrimsBeforeValidating() {
    #expect(NativeAgentChatSessionID.normalizedPathComponent("  telegram:42  ") == "telegram:42")
    #expect(NativeAgentChatSessionID.normalizedPathComponent("\n main \t") == "main")
    // Trimming must not rescue an unsafe core.
    #expect(NativeAgentChatSessionID.normalizedPathComponent("  ../evil  ") == nil)
}

@Test("the predicate half agrees with the normalizer on every case")
func chatSessionIDPredicateAgreesWithNormalizer() {
    for raw in traversalShapedIDs + legitimateIDs {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = NativeAgentChatSessionID.normalizedPathComponent(trimmed)
        let predicate = NativeAgentChatSessionID.isSafePathComponent(trimmed)
        #expect(
            predicate == (normalized == trimmed),
            "predicate/normalizer disagree on \(trimmed.debugDescription): predicate=\(predicate) normalized=\(String(describing: normalized))"
        )
    }
}

@Test("the 160-character length bound is exact on both sides")
func chatSessionIDLengthBoundIsExact() {
    #expect(NativeAgentChatSessionID.isSafePathComponent(String(repeating: "a", count: 160)))
    #expect(!NativeAgentChatSessionID.isSafePathComponent(String(repeating: "a", count: 161)))
}

@Test("a normalized id is a single path component — appending it cannot escape its parent")
func chatSessionIDNormalizedValueStaysInsideItsDirectory() throws {
    let parent = URL(fileURLWithPath: "/tmp/na-eval-root/chat_sessions", isDirectory: true)
        .standardizedFileURL
    for raw in legitimateIDs {
        let id = try #require(NativeAgentChatSessionID.normalizedPathComponent(raw))
        let child = parent.appendingPathComponent(id).standardizedFileURL
        #expect(
            child.deletingLastPathComponent().path == parent.path,
            "id \(id.debugDescription) resolved outside its parent: \(child.path)"
        )
    }
}
