import Foundation
import NativeAgentShared
import Observation
import SwiftUI
// Blueprint: | `AppModel.swift` | Renderer selections, shared edit drafts, each page's ask bar record and the pipe client's finished face values |

@MainActor @Observable
final class AppModel {
    let client: PipeFaceClient
    var face: FaceFeed { client.face }
    let systemToasts = SystemToastCenter()
    var statusText = "Connecting…"
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
    var tableFocus: (id: UUID, elements: [String]?, version: String)?
    var pendingMemoryFaceTarget: FaceDestination?
    var pendingPaletteDestination: PaletteSavedDestination?
    var pendingActivitySectionRaw: String?
    var diagnosticsRunID: String?
    var chatRestoreIssue: String?
    private let editDrafts = FaceEditDrafts()
    /// Each page's ask bar, beside its draft: the words in flight, the last accepted send, or why the last one was refused.
    var askBar: [String: AskBarRecord] = [:]
    let pageSessions = FacePageSessions()
    let inspectorStore = TurnInspectorStore()

    init(client: PipeFaceClient) {
        self.client = client
        pageSessions.defaultNotice = { [weak self] words in self?.systemToasts.push(success: words) }
        client.onReceiptFailure = { [weak self] failure in
            self?.setFailureStatus(failure, action: "confirm this window's update")
            self?.faceLinkIssue = failure.localizedDescription
        }
    }

    var agentDisplayName: String { settingsPersonaDisplayName }
    var agentAddressName: String { agentDisplayName }

    func setFailureStatus(_ error: any Error, action: String) {
        statusText = FaceActionFeedback.message(error, action: action)
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
    func setEditDraft<Value>(_ value: Value, for subject: String, baseline: Value? = nil) {
        editDrafts.set(value, for: subject, baseline: baseline)
    }
    func acceptEditDraft<Value: Equatable>(_ subject: String, submitted: Value, saved: Value) {
        editDrafts.accept(subject, submitted: submitted, saved: saved)
    }
    func acceptEditDraft<Value: Codable & Equatable>(_ subject: String, submitted: Value, rebasingOn saved: Value) throws {
        try editDrafts.accept(subject, submitted: submitted, rebasingOn: saved)
    }
    func editBinding<Value>(_ subject: String, seed: @autoclosure @escaping () -> Value) -> Binding<Value> {
        Binding(get: { self.editDraft(subject, seed: seed()) }, set: { self.setEditDraft($0, for: subject) })
    }
    func clearEditDraft(_ subject: String) { editDrafts.clear(subject) }
}
