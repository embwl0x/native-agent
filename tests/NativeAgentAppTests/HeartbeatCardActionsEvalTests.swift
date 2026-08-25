import BackgroundLoops
import Foundation
import PersistenceCore
import Testing
@testable import NativeAgentApp

// Coverage ledger: app.background / app.background.heartbeat.cardActions
//
// Drive the actual heartbeat card writer with each condition-specific control,
// then read the persisted card. The same closed vocabulary is consumed by the
// native inbox executor and the visible-action projection.

private func heartbeatCardActionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("HeartbeatCardActionsEval-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func heartbeatCardActionIDs(_ row: JSONValue) -> [String] {
    guard case .object(let object) = row,
          case .array(let actions)? = object["actions"]
    else { return [] }
    return actions.compactMap { action in
        guard case .object(let item) = action,
              case .string(let id)? = item["id"] else { return nil }
        return id
    }
}

@Suite("app.background · heartbeat card actions", .serialized)
struct HeartbeatCardActionsEvalTests {
    @Test("every heartbeat-authored card action persists with a native executor handler")
    func emittedHeartbeatControlsAndHandledInboxControlsCannotDrift() async throws {
        let root = try heartbeatCardActionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let persistence = SwiftNativePersistenceCore()
        let inbox = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        var emitted: Set<String> = []

        for action in [HeartbeatCardAction.repair, .openApprovals] {
            try await BackgroundLoopsAssembly.upsertHeartbeatNoticeCard(
                dataRoot: root,
                notice: HeartbeatNotice(
                    conditionId: "action-\(action.rawValue)",
                    body: "Hermetic heartbeat action fixture.",
                    actions: [action.noticeAction]
                )
            )
            let rows = try await persistence.readJSONL(inbox)
            let expectedCardID = "heartbeat-action-\(action.rawValue)"
            let row = try #require(rows.first { row in
                guard case .object(let object) = row,
                      case .string(let id)? = object["id"]
                else { return false }
                return id == expectedCardID
            })
            let ids = heartbeatCardActionIDs(row)
            #expect(ids == [action.rawValue, HeartbeatCardAction.archive.rawValue, HeartbeatCardAction.dismiss.rawValue])
            emitted.formUnion(ids)
        }

        #expect(emitted == HeartbeatCardAction.ids)
        #expect(emitted.isSubset(of: NativeClient.explicitlyHandledInboxActionIDs))
        #expect(NativeClient.explicitlyHandledInboxActionIDs.intersection(HeartbeatCardAction.ids) == emitted)
    }

    @Test("an unregistered heartbeat action fails before it can become a dead card button")
    func unknownHeartbeatActionIsRejectedBeforePersistence() async throws {
        let root = try heartbeatCardActionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notice = HeartbeatNotice(
            conditionId: "unknown-action",
            body: "This must not persist.",
            actions: [HeartbeatNoticeAction(id: "escalate_now", label: "Escalate")]
        )

        do {
            try await BackgroundLoopsAssembly.upsertHeartbeatNoticeCard(dataRoot: root, notice: notice)
            Issue.record("an unknown heartbeat action must fail before card persistence")
        } catch let error as HeartbeatCardActionError {
            #expect(error == .unknownActionIDs(["escalate_now"]))
        } catch {
            Issue.record("unexpected heartbeat action validation error: \(error)")
        }

        let inbox = root
            .appendingPathComponent("notifications", isDirectory: true)
            .appendingPathComponent("inbox.jsonl")
        #expect(!FileManager.default.fileExists(atPath: inbox.path))
    }
}
