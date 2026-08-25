import ActivityWatch
import ChatOrchestration
import Foundation
import NativeAgentCore
import PersistenceCore
import Testing
@testable import NativeAgentApp

@MainActor
@Test("Activity Capture retains critical authority failure evidence instead of letting a later benign event erase it")
func activityCaptureIssuesKeepCriticalFailureVisible() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentWave9-activity-issues-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let policyPath = ActivityPolicyStore(dataRoot: root).fileURL
    try FileManager.default.createDirectory(at: policyPath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("{broken".utf8).write(to: policyPath)

    let controller = ActivityWatchController(
        dataRoot: root,
        watcherPolicySource: { _ in ActivityPolicyFileSource(dataRoot: root) }
    )
    let issue = try #require(controller.primaryIssue)
    #expect(issue.severity == .critical)
    #expect(controller.lastError == issue.message)
    #expect(controller.issues.count == 1)
}

@MainActor
@Test("Activity Capture renders severity order and retains serious evidence across later notices")
func activityCaptureIssuesAreSeverityOrderedAndRetainCriticalEvidence() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentWave9-activity-severity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let controller = ActivityWatchController(dataRoot: root)
    controller.recordIssue("serious authority failure", severity: .critical)
    controller.recordIssue("configuration needs review", severity: .warning)
    controller.recordIssue("routine cleanup completed", severity: .notice)

    #expect(controller.presentationIssues.map(\.severity) == [.critical, .warning, .notice])
    #expect(controller.primaryIssue?.message == "serious authority failure")
    #expect(controller.lastError == "serious authority failure")

    // Crossing the retained-history cap with benign notices must evict notices,
    // not overwrite the serious issue that the Trust Center renders first.
    for index in 0..<12 {
        controller.recordIssue("benign follow-up \(index)", severity: .notice)
    }
    #expect(controller.issues.count == 12)
    #expect(controller.presentationIssues.first?.message == "serious authority failure")
    #expect(controller.presentationIssues.first?.severity == .critical)
}

@MainActor
@Test("Trust Center activity consent disables its mounted access control and reaches chat dispatch")
func activityConsentTraversesControlAndChatDispatcher() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentWave9-activity-dispatch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let controller = ActivityWatchController(
        dataRoot: root,
        watcherPolicySource: { ActivityPolicyFileSource(dataRoot: $0) }
    )
    controller.setModelAccessEnabled(true)
    #expect(!controller.policy.captureEnabled)
    #expect(!ActivityCapturePresentation.isAgentAccessControlEnabled(policy: controller.policy))

    let sessionID = "activity-capture-dispatch-eval"
    try await ActiveToolsStore(dataRoot: root).addLoaded(
        sessionId: sessionID,
        names: ["activity_query"]
    )
    let dispatcher = SwiftToolDispatcher(dataRoot: root)
    #expect(!(try await dispatcher.listAvailableTools()).contains("activity_query"))
    let input: [String: JSONValue] = [
        "range": .string("today"),
        "session_id": .string(sessionID),
    ]
    do {
        let outcome = try await dispatcher.dispatch(
            tool: "activity_query", input: input, surface: "chat"
        )
        guard case let .object(receipt) = outcome else {
            Issue.record("Disabled activity access must refuse with an outcome, never return activity data.")
            return
        }
        let status: JSONValue? = receipt["status"]
        let failed = status == JSONValue.string("failed")
        let refused = status == JSONValue.string("refused")
        #expect(failed || refused)
        if case let .string(reason)? = receipt["reason"] {
            #expect(reason.contains("Activity capture is turned OFF"))
        } else {
            Issue.record("Disabled activity access refusal must name its reason.")
        }
        #expect(receipt["spans"] == nil)
    } catch let AutonomyGateError.toolDenied(reason) {
        #expect(reason.contains("Activity capture is turned OFF"))
    } catch {
        Issue.record("Expected the disabled Activity Capture refusal, got: \(error)")
    }
}
