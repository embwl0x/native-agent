import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `AppModel.swift` | Renderer selections, shared edit drafts and the pipe client's finished face values |

@MainActor @Observable
final class AppModel {
    let client: PipeFaceClient
    var face: FaceFeed { client.face }
    let systemToasts = SystemToastCenter()
    var statusText = "Connecting…"
    var statusCause: String?
    var faceLinkIssue: String?
    var faceRefreshIssue: String?
    var manualRefreshRequest: UUID?
    var windowActions: [FaceWindowAction] = []
    var windowActionIssues: [FaceWindowAction.Issue] = []
    var activeChatSessionId = ""
    @ObservationIgnored var chatSelectionGeneration = UUID()
    @ObservationIgnored var chatComposerDrafts: [String: ChatComposerDraft] = [:]
    var chatPendingAttachments: [String: [FaceAttachment]] = [:]
    var pendingChatMessageID: String?
    var pendingChatBrainSelection: ProviderTurnChoice?
    var pendingMemoryFaceTarget: FaceDestination?
    var pendingPaletteDestination: PaletteSavedDestination?
    var pendingDeskHandle: String?
    var pendingActivitySectionRaw: String?
    var diagnosticsRunID: String?
    var trustCenterActionOutcome: TrustCenterActionOutcome?
    var dreamError: String?
    var chatRestoreIssue: String?
    private let editDrafts = FaceEditDrafts()
    let pageSessions = FacePageSessions()
    typealias PanelRefreshStatus = NativeAgentShared.PanelRefreshStatus

    init(client: PipeFaceClient) {
        self.client = client
        client.face.onPageApplied = { page, snapshot, elapsed in
            FacePageDiagnostics.arrival(page: page, snapshot: snapshot, elapsed: elapsed)
        }
        client.onReceiptFailure = { [weak self] failure in
            self?.setFailureStatus(failure, action: "confirm this window's update")
            self?.faceLinkIssue = failure.localizedDescription
        }
    }

    var agentDisplayName: String { settingsPersonaDisplayName }
    var agentAddressName: String { agentDisplayName }
    var chatModel: String {
        get { currentChatBrainSelection?.model ?? "" }
        set { stageChatBrainSelection(model: newValue) }
    }
    var chatReasoningEffort: String {
        get { currentChatBrainSelection?.reasoningEffort ?? "" }
        set { stageChatBrainSelection(reasoningEffort: newValue) }
    }
    var chatFastMode: Bool {
        get { currentChatBrainSelection?.fast == true }
        set { stageChatBrainSelection(fast: newValue) }
    }
    var chatProvider: String { currentChatBrainSelection?.provider ?? "" }
    var isSavingChatBrain: Bool { providerSavingChatBrain }

    func setFailureStatus(_ error: any Error, action: String) {
        setFailureStatus(FaceActionFeedback.message(error, action: action), cause: error)
    }
    func setFailureStatus(_ line: String, cause error: any Error) {
        statusText = line
        statusCause = error.localizedDescription
    }

    func maybeSendFirstRunGreeting() async -> String? {
        do {
            let value = try FaceWindowReply.value(await client.act(.onboarding(.greet)))
            guard case .object(let fields) = value else { throw FaceActionFeedback.unexpected("the greeting disposition") }
            switch fields["routeFailure"] {
            case .string(let issue): return issue
            case .null?: return nil
            default: throw FaceActionFeedback.unexpected("the greeting route outcome")
            }
        } catch { return error.localizedDescription }
    }

    func editDraft<Value>(_ subject: String, seed: @autoclosure () -> Value) -> Value {
        editDrafts.value(subject, seed: seed())
    }
    func editDraftBaseline<Value>(_ subject: String, seed: Value) -> Value {
        editDrafts.baseline(subject, seed: seed)
    }
    func setEditDraft<Value>(_ value: Value, for subject: String, baseline: Value? = nil) {
        editDrafts.set(value, for: subject, baseline: baseline)
    }
    func acceptEditDraft<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        editDrafts.accept(subject, submitted: submitted, saved: saved)
    }
    func acceptEditDraft<Value: Codable & Equatable>(_ subject: String, submitted: Value, rebasingOn saved: Value) throws {
        try editDrafts.accept(subject, submitted: submitted, rebasingOn: saved)
    }
    func mergingEditDraft<Value: Codable>(
        _ subject: String, edited: Value, into current: Value, baseline originalBaseline: Value? = nil
    ) throws -> Value {
        try editDrafts.merging(subject, edited: edited, into: current, baseline: originalBaseline)
    }
    func editBinding<Value>(_ subject: String, seed: @autoclosure @escaping () -> Value) -> Binding<Value> {
        Binding(get: { self.editDraft(subject, seed: seed()) }, set: { self.setEditDraft($0, for: subject) })
    }
    func clearEditDraft(_ subject: String) { editDrafts.clear(subject) }
}
