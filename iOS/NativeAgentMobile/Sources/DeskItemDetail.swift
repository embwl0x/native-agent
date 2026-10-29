import SwiftUI
import NativeAgentShared
// Blueprint: | `DeskItemDetail.swift` | Desk item detail, retained note submission and new-item form |

/// The mobile form validates the same note shape that the Mac action accepts,
/// so an iPhone user learns about a local input issue before an iCloud round
/// trip can return the router's otherwise generic rejection.
enum MobileDeskNotePresentation {
    static let maximumCharacterCount = 2_000
    static let maximumCharacterCountLabel = "2,000"

    static func submissionText(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= maximumCharacterCount else { return nil }
        return text
    }

    static func validationMessage(for draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Enter a note before adding it." }
        if text.count > maximumCharacterCount {
            return "Desk notes can be at most \(maximumCharacterCountLabel) characters."
        }
        return nil
    }
}

struct MobileDeskItemDetail: View {
    let item: MobileDeskItem
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    private let outbox = MobileDeskNoteOutbox.shared
    private let sync = iCloudSyncEngine.shared
    @State private var note = ""
    @State private var isWorking = false

    /// The complete copy the Mac carries for priority items, when there is one.
    /// Its absence is not an error — the compact row is still the truth.
    private var readingCopy: MobileDeskItemReadingCopy? {
        sync.deskReadingCopies[item.handle]
    }

    private var displayedSummary: String? {
        readingCopy?.summary ?? item.summary
    }

    private var displayedNotes: [MobileDeskNote] {
        readingCopy?.notes ?? item.recentNotes
    }

    private var noteCount: Int { note.trimmingCharacters(in: .whitespacesAndNewlines).count }

    var body: some View {
        NavigationStack {
            AlivePage(title: item.title, line: item.requiresOwnerInput && item.closedAt == nil ? "Waiting on you" : (item.closedAt != nil ? DeskStatusWords.word(for: item.status) : item.activity(at: Date()).label), style: .pushed) {

                if let summary = displayedSummary, !summary.isEmpty {
                    AliveCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary)
                                .font(.body)
                                .lineSpacing(3)
                                .foregroundStyle(AlivePalette.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if let copy = readingCopy {
                                Text("Reading copy from \(AliveWords.readable(copy.capturedAt))")
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let notice = MobileDeskBoundaryCopy.clippedNotice(summary) {
                                Text(notice)
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .aliveRow()
                    }
                }

                AliveCard {
                    if let reason = item.blockedReason, !reason.isEmpty {
                        AliveValueRow(label: "Stuck on", value: reason)
                        AliveDivider()
                    }
                    if let waiting = item.waitingOn, !waiting.isEmpty {
                        AliveValueRow(label: "Waiting on", value: waiting)
                        AliveDivider()
                    }
                    AliveValueRow(label: "Project", value: item.project)
                    AliveDivider()
                    AliveValueRow(label: "Kind", value: DeskKindWords.word(for: item.kind))
                    AliveDivider()
                    HStack(spacing: 12) {
                        Text("Status")
                            .font(.body)
                            .foregroundStyle(AlivePalette.text)
                        Spacer(minLength: 8)
                        if isWorking { ProgressView().controlSize(.small) }
                        Picker("Status", selection: Binding(
                            get: { item.status },
                            set: { status in Task { await changeStatus(status) } }
                        )) {
                            let statuses = DeskStatus.allCases.filter { $0 != .blocked }.map(\.rawValue)
                            ForEach((item.status == "blocked" ? [item.status] : []) + statuses, id: \.self) {
                                Text(DeskStatusWords.word(for: $0)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(AlivePalette.text)
                        .disabled(isWorking)
                    }
                    .aliveRow()
                }

                if !outbox.pendingNotes(for: item.handle).isEmpty {
                    AliveSection("Not on the Mac yet") {
                        ForEach(Array(outbox.pendingNotes(for: item.handle).enumerated()), id: \.element.id) { index, pending in
                            if index > 0 { AliveDivider() }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pending.text)
                                    .foregroundStyle(AlivePalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(pending.statusLine)
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                                if let error = pending.lastError {
                                    Text(error)
                                        .font(.footnote)
                                        .foregroundStyle(AlivePalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .aliveRow()
                        }
                    }
                }

                if !displayedNotes.isEmpty {
                    AliveSection(readingCopy == nil ? "Recent notes" : "Notes") {
                        ForEach(Array(displayedNotes.enumerated()), id: \.offset) { index, note in
                            if index > 0 { AliveDivider() }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(note.text)
                                    .foregroundStyle(AlivePalette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let notice = MobileDeskBoundaryCopy.clippedNotice(note.text) {
                                    Text(notice)
                                        .font(.footnote)
                                        .foregroundStyle(AlivePalette.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text(AliveWords.readable(note.timestamp))
                                    .font(.footnote)
                                    .foregroundStyle(AlivePalette.secondary)
                            }
                            .aliveRow()
                        }
                    }
                }

                AliveSection("Add a note") {
                    TextField("What changed?", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                        .foregroundStyle(AlivePalette.text)
                        .onChange(of: note) { _, value in
                            outbox.setDraft(value, for: item.handle)
                        }
                        .aliveRow()
                    AliveDivider()
                    HStack {
                        Text("\(noteCount)/\(MobileDeskNotePresentation.maximumCharacterCountLabel)")
                            .font(.footnote)
                            .monospacedDigit()
                            .foregroundStyle(noteCount > MobileDeskNotePresentation.maximumCharacterCount
                                             ? AnyShapeStyle(NativeAgentMobileTheme.Colors.trouble)
                                             : AnyShapeStyle(AlivePalette.secondary))
                        Spacer()
                        Button("Add Note") { addNote() }
                            .font(.subheadline.weight(.semibold))
                            .alivePrimaryButton()
                            .disabled(isWorking || MobileDeskNotePresentation.submissionText(for: note) == nil)
                    }
                    .aliveRow()
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { note = outbox.draft(for: item.handle) }
            .onDisappear { outbox.flushDrafts() }
        }
    }

    private func changeStatus(_ status: String) async {
        guard status != item.status else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await iCloudSyncEngine.shared.setDeskItemStatus(handle: item.handle, status: status)
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }

    /// Save notes before Mac confirmation under one retained signed identity.
    private func addNote() {
        guard let clean = MobileDeskNotePresentation.submissionText(for: note) else {
            errorMessage = MobileDeskNotePresentation.validationMessage(for: note)
            return
        }
        outbox.submit(handle: item.handle, text: clean)
        note = ""
        dismiss()
    }
}

struct NewMobileDeskItemSheet: View {
    @Binding var errorMessage: String?
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var project = "General"
    @State private var summary = ""
    @State private var kind: DeskKind = .plan
    @State private var isSaving = false
    @State private var submission: InboxAction?

    var body: some View {
        NavigationStack {
            AlivePage(title: "New item", line: "It goes on the board on your Mac.", style: .pushed) {
                AliveCard {
                    TextField("Title", text: $title)
                        .font(.headline)
                        .aliveRow()
                    AliveDivider()
                    HStack(spacing: 12) {
                        Text("Project").foregroundStyle(AlivePalette.text)
                        TextField("Project", text: $project)
                            .multilineTextAlignment(.trailing)
                    }
                    .aliveRow()
                    AliveDivider()
                    HStack {
                        Text("Kind").foregroundStyle(AlivePalette.text)
                        Spacer()
                        Picker("Kind", selection: $kind) {
                            ForEach([DeskKind.plan, .project, .watch, .gh, .standing], id: \.self) {
                                Text(DeskKindWords.word(for: $0.rawValue)).tag($0)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .tint(AlivePalette.text)
                    }
                    .aliveRow()
                    AliveDivider()
                    TextField("Summary (optional)", text: $summary, axis: .vertical)
                        .lineLimit(2...6)
                        .aliveRow()
                }
                .foregroundStyle(AlivePalette.text)
                .disabled(submission != nil)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if isSaving {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                        } else {
                            Text("Add")
                        }
                    }
                        .disabled(isSaving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || project.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(isSaving ? "Adding Desk item" : "Add Desk item")
                }
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        // Each sheet creates a request; uncertain saves retain it for retry.
        let intentionalNewRequest = submission == nil
        if submission == nil {
            var payload = [
                "kind": kind.rawValue,
                "project": project.trimmingCharacters(in: .whitespacesAndNewlines),
                "title": title.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
            let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSummary.isEmpty { payload["summary"] = cleanSummary }
            submission = .make(action: "createDeskItem", payload: payload)
        }
        do {
            _ = try await iCloudSyncEngine.shared.createDeskItem(
                kind: kind.rawValue,
                project: project.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
                submission: submission, intentionalNewRequest: intentionalNewRequest,
                onReplacement: { submission = $0 }
            )
            await iCloudSyncEngine.shared.refreshDeskSnapshot()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
