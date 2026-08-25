import ApprovalInbox
import Foundation
import NativeAgentShared
import PersistenceCore
import Testing
@testable import NativeAgentApp

// EVAL FENCE: app.desk / desk.approvals.payloadPreview
@Suite("Desk approval payload preview")
struct DeskApprovalPayloadPreviewEvalTests {
    @Test("a persisted canonical payload preview remains observable and reviewable at the Desk reader")
    func canonicalPreviewSurvivesStoreAndClientBoundary() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let record = try await inbox.create(.object([
            "title": .string("Send the release note"),
            "action": .string("connector.external_send"),
            "risk": .string("confirm"),
            "reason": .string("An external message needs a decision"),
            "payload": .object([
                "recipient": .string("team@example.test"),
                "body": .string("Release is ready"),
            ]),
            "payloadPreview": .string("To: team@example.test\nRelease is ready"),
        ]))

        let row = try #require(
            try await NativeClient(baseURL: "", dataRootOverride: root)
                .getApprovals()
                .first(where: { $0.id == record.id })
        )

        #expect(ApprovalPayloadPreviewPresentation.state(for: row)
            == .available("To: team@example.test\nRelease is ready"))
        #expect(ApprovalPayloadPreviewPresentation.canResolve(row))
    }

    @Test("a partial stored row cannot silently present an empty payload as reviewable")
    func missingPreviewDisablesApprovalAndExplainsWhy() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = SwiftNativeApprovalInbox(root: root)
        let record = try await inbox.create(.object([
            "title": .string("Apply a Desk change"),
            "action": .string("desk_note"),
            "risk": .string("confirm"),
            "reason": .string("Evaluate a partial approval row"),
            "payload": .object(["handle": .string("desk_42")]),
        ]))

        let persistence = SwiftNativePersistenceCore()
        let path = await inbox.approvalsPath
        let raw = await persistence.readJSON(path, defaultValue: .array([]))
        guard case .array(let rows) = raw,
              case .object(var stored)? = rows.first else {
            throw PayloadPreviewEvalError.couldNotReadStoredApproval
        }
        stored["payloadPreview"] = .string(" \n\t ")
        try await persistence.writeJSON(.array([.object(stored)]), to: path)

        let row = try #require(
            try await NativeClient(baseURL: "", dataRootOverride: root)
                .getApprovals()
                .first(where: { $0.id == record.id })
        )

        #expect(ApprovalPayloadPreviewPresentation.state(for: row) == .unavailable)
        #expect(!ApprovalPayloadPreviewPresentation.canResolve(row))
        #expect(ApprovalPayloadPreviewPresentation.unavailableText
            .contains("must be restored"))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("desk-approval-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum PayloadPreviewEvalError: Error {
    case couldNotReadStoredApproval
}
