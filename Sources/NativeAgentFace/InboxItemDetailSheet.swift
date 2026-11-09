import SwiftUI
import NativeAgentShared
import Foundation
import CryptoKit
import Observation
// Blueprint: | `InboxItemDetailSheet.swift` | Shared capsule-note rows/documents and retained actions; the typed Inbox owner settles every outcome |

extension InboxItemRecord {
    var sourceIcon: String { presentation?.icon ?? "bell.fill" }
    var sourceBadgeLabel: String { presentation?.badge ?? "SOURCE UNKNOWN" }

    var sourceWord: String {
        let label = sourceBadgeLabel
        guard label != "REM" else { return label }
        let words = label.replacingOccurrences(of: "-", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    var detailEyebrow: String {
        let level = severity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !level.isEmpty, level.lowercased() != "info" else { return sourceWord }
        return "\(sourceWord) · \(AdvancedStatusWords.label(level))"
    }
}

struct InboxItemDetailSheet: View {
    let item: InboxItemRecord
    var allItems: [InboxItemRecord] = []
    let onAction: @MainActor (String) async -> InboxRowActionFlight.Outcome
    var onOpenGroup: ((InboxRelatedGroup) -> Void)? = nil
    var closesOnGroupSelection = true
    let onClose: () -> Void

    @State private var session = FacePageSession()

    private var visibleActions: [InboxActionRecord] {
        InboxVisibleActionsPresentation.actions(for: item)
    }

    private var relatedGroups: [InboxRelatedGroup] {
        InboxDigestGroups.groups(item: item, allItems: allItems)
    }

    var body: some View {
        List {
            FaceView(face: page, door: door, session: session)
        }
        .environment(\.faceInList, true)
        .listStyle(.plain)
        .macFaceStyle()
        .frame(minWidth: 320, idealWidth: 560, minHeight: 320, idealHeight: 480)
        .onAppear {
            guard session.operations[item.id] == nil else { return }
            session.submit(.init(section: "face:note", row: item.id), row: item.id, action: "read", value: nil,
                           call: actionCall("read"), door: door)
        }
    }

    private var detailKey: String { "inbox-detail:" + item.id }
    private var filesKey: String { "inbox-files:" + item.id }
    private func revision(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private var documents: [String: String] {
        var documents: [String: String] = [:]
        if let detail = item.detail, !detail.isEmpty { documents[detailKey] = detail }
        if let paths = item.related_paths, !paths.isEmpty { documents[filesKey] = paths.joined(separator: "\n") }
        return documents
    }
    private var groupRevision: String {
        revision(relatedGroups.map { $0.id + ":" + $0.title + ":" + String($0.displayCount) }.joined(separator: "\n"))
    }
    private var groupCall: PartFace.Call { .init("inbox.related", ["id": .string(item.id)]) }
    private func groupSection(start: Int) throws -> PartFace.Section {
        let slice = relatedGroups.dropFirst(start).prefix(256)
        let (next, overflow) = start.addingReportingOverflow(slice.count)
        guard !overflow else {
            throw PartCallError(code: "inbox_cursor_invalid", message: "The related-note position exceeds this window's range.")
        }
        return .init(id: "related", title: "Related notes", rows: slice.map { group in
            .init(id: group.id, title: group.title, value: "\(group.displayCount) \(group.displayCount == 1 ? "note" : "notes")",
                  open: "page:inbox/" + group.id)
        }, more: next < relatedGroups.count ? .init(next: String(next), total: relatedGroups.count,
              revision: groupRevision, read: groupCall) : nil, revision: groupRevision)
    }

    private var page: PartFace {
        var sections: [PartFace.Section] = [
            .init(id: "note", title: item.detailEyebrow, rows: [
                .init(id: item.id, title: item.title, detail: item.summary, at: item.created_at, symbol: item.sourceIcon,
                      actions: visibleActions.map { action in
                    .init(id: action.id, label: action.label,
                          role: ["archive", "dismiss", "reject", "deny"].contains(action.id) ? .destructive
                            : InboxActionWords.isPrimary(action.id) ? .primary : nil,
                          call: actionCall(action.id))
                }),
            ]),
        ]
        for key in [detailKey, filesKey] {
            if let text = documents[key] {
                sections.append(.init(id: key, title: key == filesKey ? "Files" : nil, rows: [], block: .init(key: key,
                    text: text.utf8.count <= PartFace.Block.inlineByteLimit ? text : nil, revision: revision(text))))
            }
        }
        if onOpenGroup != nil, !relatedGroups.isEmpty {
            do { sections.append(try groupSection(start: 0)) }
            catch { sections.append(.init(id: "related-failed", rows: [.init(id: "related-failed", title: error.localizedDescription, tone: .failed)])) }
        }
        sections.append(.init(id: "close", style: .flow, rows: [
            .init(id: "close", title: "Close", actions: [.init(id: "close", label: "Close", open: "page:inbox")]),
        ]))
        return PartFace(sections: sections)
    }

    private func actionCall(_ action: String) -> PartFace.Call {
        .init("inbox.action", ["id": .string(item.id), "action": .string(action)])
    }

    private var door: ClosureFaceDoor {
        ClosureFaceDoor(open: { link in
            if link == "page:inbox" { onClose(); return }
            guard let group = relatedGroups.first(where: { "page:inbox/" + $0.id == link }), let onOpenGroup else { return }
            onOpenGroup(group)
            if closesOnGroupSelection { onClose() }
        }, waitingOn: "the note", read: { request in
            guard let text = documents[request.key], request.revision == revision(text) else {
                throw PartCallError(code: "inbox_detail_changed", message: "The selected note's detail changed. Open it again.")
            }
            return text
        }, pageRead: { request in
            guard request.expectedCall == groupCall else {
                throw PartCallError(code: "inbox_read_changed", message: "The related-notes collection changed. Open the note again.")
            }
            let start: Int
            if request.revision != groupRevision {
                start = request.anchor.flatMap { anchor in relatedGroups.firstIndex { $0.id == anchor } } ?? 0
            } else if let cursor = request.cursor, let offset = Int(cursor), offset >= 0, offset <= relatedGroups.count { start = offset }
            else { throw PartCallError(code: "inbox_cursor_invalid", message: "The related-notes cursor is invalid. Open the note again.") }
            return PartFace(sections: [try groupSection(start: start)])
        }, perform: { submission in
            guard submission.row == item.id,
                  submission.action == "read" || visibleActions.contains(where: { $0.id == submission.action }),
                  submission.expectedCall == actionCall(submission.action) else {
                return .interrupted(WireFailure(code: "inbox_action_changed", message: "The note's action changed. Open it again.",
                                                cause: nil, effects: .none))
            }
            if submission.checking {
                return .interrupted(WireFailure(code: "inbox_action_unconfirmed", message: "Read the Inbox to check this action's result.",
                                                cause: nil, effects: .unknown))
            }
            let outcome = await onAction(submission.action).faceOutcome
            if submission.action != "read", outcome.accepted, outcome.failure == nil, outcome.effects != .unknown { onClose() }
            return outcome
        })
    }

}

enum InboxActionWords {
    static func isPrimary(_ actionID: String) -> Bool {
        actionID == "act" || actionID == "approve" || actionID == "open_approvals" || actionID == "repair"
    }

}

/// One action flight prevents duplicate writes and preserves the terminal outcome.
@MainActor @Observable
final class InboxRowActionFlight {
    enum Outcome: Equatable {
        case dropped
        case succeeded
        case failed(WireFailure)

        var faceOutcome: FaceActOutcome {
            switch self {
            case .succeeded: .init(effects: .known, accepted: true)
            case .failed(let failure): .interrupted(failure)
            case .dropped:
                .interrupted(WireFailure(code: "inbox_action_pending", message: "Another note action is still waiting on its owner.",
                                         cause: nil, effects: .none))
            }
        }
    }

    private(set) var isInFlight = false

    func perform(operation: @escaping @MainActor () async throws -> Void) async -> Outcome {
        guard !isInFlight else { return .dropped }
        isInFlight = true
        defer { isInFlight = false }

        do {
            try await operation()
            return .succeeded
        } catch {
            let detail = String(TurnSecretRedactor.redactText(error.localizedDescription).prefix(1_000))
            ModuleLog.app("%@", "[inbox] action failed: \(detail)")
            var failure: WireFailure
            if let known = error as? WireFailure { failure = known }
            else { failure = WireFailure(code: "inbox_action_unconfirmed", message: detail, cause: nil, effects: .unknown) }
            failure.message = TurnSecretRedactor.redactText(failure.message)
            failure.cause = failure.cause.map(TurnSecretRedactor.redactText)
            return .failed(failure)
        }
    }
}
