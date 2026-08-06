import Foundation
import Testing
@testable import ApprovalInbox
import NativeAgentCore

// Best-agent sweep R4, finding B2. `remoteResolvable` decides whether a
// REMOTE surface (iCloud / Telegram / chat) may mint an approval decision, and
// it used to fail OPEN twice over: `pyBool` coerced any non-empty string to
// true (so the string "false" WIDENED authority), and a missing flag defaulted
// to true (so every caller that forgot the key got remote resolution for
// free). These traps pin the fail-CLOSED semantics.
@Suite("Approval remoteResolvable fails closed")
struct ApprovalAuthorityFailClosedTests {

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-authority-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func malformedStringFlagIsNotRemoteResolvable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        // The old pyBool path read this non-empty string as TRUE.
        let created = try await inbox.create(.object([
            "title": .string("Send an email"),
            "action": .string("connector.email.send"),
            "remoteResolvable": .string("false"),
            "payload": .object([:]),
        ]))
        #expect(!created.remoteResolvable)
        #expect(created.localOnly)
    }

    @Test func malformedTruthyStringFlagIsAlsoNotRemoteResolvable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        // Strict means strict: even a string that "looks" true is undeclared.
        let created = try await inbox.create(.object([
            "title": .string("Send an email"),
            "action": .string("connector.email.send"),
            "remoteResolvable": .string("true"),
            "payload": .object([:]),
        ]))
        #expect(!created.remoteResolvable)
        #expect(created.localOnly)
    }

    @Test func numericFlagIsNotRemoteResolvable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let created = try await inbox.create(.object([
            "title": .string("Send an email"),
            "action": .string("connector.email.send"),
            "remoteResolvable": .int(1),
            "payload": .object([:]),
        ]))
        #expect(!created.remoteResolvable)
        #expect(created.localOnly)
    }

    @Test func missingFlagOnUndeclaredActionIsNotRemoteResolvable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let created = try await inbox.create(.object([
            "title": .string("Weekly memory hygiene is due"),
            "action": .string("memory.consolidation.swap"),
            "payload": .object([:]),
        ]))
        #expect(!created.remoteResolvable)
        #expect(created.localOnly)
    }

    @Test func explicitBoolTrueIsRemoteResolvable() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let created = try await inbox.create(.object([
            "title": .string("Approve tool call"),
            "action": .string("connector.email.send"),
            "remoteResolvable": .bool(true),
            "payload": .object([:]),
        ]))
        #expect(created.remoteResolvable)
        #expect(!created.localOnly)
    }

    @Test func declaredRemoteSafeActionStaysRemoteResolvableWithoutFlag() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        // The explicit remote-safe declaration is the ONLY way a missing flag
        // still yields remote resolution.
        for action in SwiftNativeApprovalInbox.remoteSafeActions {
            let created = try await inbox.create(.object([
                "title": .string("Workflow is waiting"),
                "action": .string(action),
                "payload": .object([:]),
            ]))
            #expect(created.remoteResolvable, "\(action) should stay remote-safe")
            #expect(!created.localOnly)
        }
    }

    @Test func hardLocalActionStaysLocalEvenWithExplicitTrue() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        // The hard-local override is unchanged by this fix and still wins over
        // an explicit caller-supplied true.
        for action in ["autonomy.promote", "self_evolution.apply", "memory.delete"] {
            let created = try await inbox.create(.object([
                "title": .string("Loosen autonomy"),
                "action": .string(action),
                "remoteResolvable": .bool(true),
                "localOnly": .bool(false),
                "payload": .object([:]),
            ]))
            #expect(!created.remoteResolvable, "\(action) must never be remote-resolvable")
            #expect(created.localOnly, "\(action) must stay local-only")
        }
    }

    @Test func strictBoolAcceptsOnlyLiteralBooleans() {
        #expect(SwiftNativeApprovalInbox.strictBool(.bool(true)) == true)
        #expect(SwiftNativeApprovalInbox.strictBool(.bool(false)) == false)
        #expect(SwiftNativeApprovalInbox.strictBool(.string("true")) == nil)
        #expect(SwiftNativeApprovalInbox.strictBool(.string("")) == nil)
        #expect(SwiftNativeApprovalInbox.strictBool(.int(1)) == nil)
        #expect(SwiftNativeApprovalInbox.strictBool(.double(0)) == nil)
        #expect(SwiftNativeApprovalInbox.strictBool(.null) == nil)
        #expect(SwiftNativeApprovalInbox.strictBool(nil) == nil)
    }
}
