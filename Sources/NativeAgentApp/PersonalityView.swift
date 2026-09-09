import SwiftUI
import AppKit
import NativeAgentShared

// MARK: - PersonalityView (redesigned 2026-07-03, User's direction)
//
// The old tab stacked a preset system (Male/Female/AI/Custom cards, essence/
// voice fields, eight trait sliders, pattern controls, a compiled-packet
// preview) on top of the persona docs editor. Comprehension pass proved the
// top layer was a closed loop: those controls write memory/profile.json,
// and NOTHING in the live chat path reads it — every real turn compiles the
// system prompt from the persona DOCS via PersonaCompiler.compile
// (SOUL → VOICE → USER → GROWTH → MEMORY → AGENTS). The only profile.json
// field with live effect is `name` (AppModel.agentDisplayName).
//
// So the tab now tells the truth:
//   • No persona yet (fresh install) → one starter card: type a name and a
//     few things, Create. Uses the guarded onboarding path, which REFUSES
//     when SOUL.md/USER.md/.onboarded exist — it cannot touch a live persona.
//   • Persona live → the name (the one live profile field) + the documents
//     that ARE the persona.

/// Owns the picker/editor transition as one value state. In particular, a
/// document switch may replace the visible editor text, but it must never
/// discard the departing document's unsaved draft.
struct PersonalityDocumentDraftState: Equatable {
    private(set) var selectedDocumentID = ""
    private(set) var unsavedDrafts: [String: String] = [:]
    private var editRevisions: [String: Int] = [:]
    private(set) var savingRevisions: [String: Int] = [:]

    var hasUnsavedDrafts: Bool { !unsavedDrafts.isEmpty }

    static func usableDocuments(in documents: [PersonalityDoc]) -> [PersonalityDoc] {
        documents.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    mutating func select(_ requestedID: String, documents: [PersonalityDoc]) -> String {
        selectedDocumentID = requestedID
        return reconcile(documents: documents)
    }

    /// Reconcile after a load/reload. A missing selection moves to the first
    /// usable document; an empty or malformed catalog has no selected id and
    /// no editable-looking empty fallback.
    mutating func reconcile(documents: [PersonalityDoc]) -> String {
        let documents = Self.usableDocuments(in: documents)
        guard let selected = documents.first(where: { $0.id == selectedDocumentID })
            ?? documents.first else {
            selectedDocumentID = ""
            return ""
        }
        selectedDocumentID = selected.id
        return unsavedDrafts[selected.id] ?? selected.content
    }

    mutating func recordEdit(_ content: String, documents: [PersonalityDoc]) {
        guard let selected = Self.usableDocuments(in: documents)
            .first(where: { $0.id == selectedDocumentID }) else {
            return
        }
        editRevisions[selected.id, default: 0] += 1
        if content == selected.content && savingRevisions[selected.id] == nil {
            unsavedDrafts.removeValue(forKey: selected.id)
        } else {
            unsavedDrafts[selected.id] = content
        }
    }

    mutating func keepUnsavedDraft(_ content: String, for documentID: String) {
        guard !documentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        unsavedDrafts[documentID] = content
        editRevisions[documentID, default: 0] += 1
    }

    mutating func beginSave(documentID: String, content: String) -> Int? {
        guard savingRevisions[documentID] == nil else { return nil }
        let revision = editRevisions[documentID, default: 0]
        savingRevisions[documentID] = revision
        unsavedDrafts[documentID] = content
        return revision
    }

    mutating func finishSave(documentID: String, revision: Int, succeeded: Bool) {
        savingRevisions.removeValue(forKey: documentID)
        if succeeded && editRevisions[documentID, default: 0] == revision {
            unsavedDrafts.removeValue(forKey: documentID)
        }
    }
}

/// The starter card's durable operation. Keeping this separate from SwiftUI
/// state means the same onboarding, document reload, and SOUL write sequence
/// can be evaluated without treating an off-screen AppKit hierarchy as proof
/// that the user action worked.
@MainActor
enum PersonalityStarterCreateAction {
    enum Outcome: Equatable {
        case created
        case notesUnsaved(documentID: String, draft: String)
        case failed(String)
    }

    static let notesUnsavedMessage =
        "Setup notes were not saved. They are open as an unsaved SOUL.md draft below."

    static func create(
        appModel: AppModel,
        agentName: String,
        userName: String,
        notes: String
    ) async -> Outcome {
        do {
            let response = try await appModel.completeOnboarding(
                agentName: agentName.trimmingCharacters(in: .whitespacesAndNewlines),
                personaType: "ai",
                userName: userName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard response.ok else {
                return .failed(response.detail ?? response.error ?? "Could not create the persona.")
            }
            guard await appModel.loadPersonalityDocs() else {
                return .failed(
                    "The persona was created, but its documents could not be reloaded to save your setup notes. Retry from the Personality page before editing anything else."
                )
            }

            let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedNotes.isEmpty,
                  let soul = appModel.personalityDocs.first(where: { $0.id.uppercased() == "SOUL" })
            else {
                return .created
            }

            let draft = soul.content + "\n\n## From setup\n" + trimmedNotes + "\n"
            PersonalityStarterPanelEvaluation.beforePersistingNotes?()
            guard await appModel.savePersonalityDoc(id: soul.id, content: draft) else {
                return .notesUnsaved(documentID: soul.id, draft: draft)
            }
            return .created
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

struct PersonalityView: View {
    #if DEBUG
    private var snapshotOnly = false

    @MainActor
    static func renderCopyReview(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("personality-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})
        app.personalityDocs = ["SOUL", "VOICE", "USER", "GROWTH", "AGENTS"].map {
            PersonalityDoc(id: $0, title: $0, filename: "\($0).md",
                           content: $0 == "USER" ? "Prefers clear explanations and practical examples." : "Be thoughtful, curious, and clear. Follow through on commitments.")
        }
        for selected in ["SOUL", "USER"] {
            var state = PersonalityDocumentDraftState()
            let content = state.select(selected, documents: app.personalityDocs)
            var view = PersonalityView()
            view.snapshotOnly = true
            view._documentDraftState = State(initialValue: state)
            view._personalityDocDraft = State(initialValue: content)
            for scheme in [ColorScheme.light, .dark] {
                try BotsShelfSnapshots.write(ShellFrame(classic: false) {
                    ShellSidebarRail(selection: .constant(.personality), botsPreviewOverride: false)
                } detail: {
                    ShellPageFrame(title: "Personality", showsBack: false, wide: true) {
                        view.environment(app)
                    }
                },
                    name: "personality-\(selected.lowercased())-\(scheme == .dark ? "dark" : "light")",
                    size: CGSize(width: 1280, height: 900), scheme: scheme, directory: directory, scale: 1)
            }
        }
    }
    #endif
    @Environment(AppModel.self) private var appModel
    @State private var draft = PersonalityProfile.defaultProfile
    @State private var isLoadingProfile = true
    @State private var documentDraftState = PersonalityDocumentDraftState()
    @State private var personalityDocDraft = ""

    // Starter card state (shown only while no persona exists).
    @State private var starterAgentName = ""
    @State private var starterUserName = ""
    @State private var starterNotes = ""
    @State private var starterBusy = false
    @State private var starterError: String?
    @State private var documentsLoadLatch = PersonalityDocumentsLoadLatch()
    @State private var documentSaveError: String?
    @State private var isReloadingDocuments = false
    @State private var isSavingName = false
    @State private var nameSaveFeedback: PersonalityNameSaveFeedback?
    @AppStorage(NativeAgentShellPreference.classicShellKey) private var classicShell = false

    /// SOUL.md is the identity marker everywhere else in the system
    /// (PersonaRootResolver, onboarding guards) — same rule here. Presence
    /// of the SOUL *spec* is not enough: listPersonaDocSpecs returns all
    /// five specs on a fresh install too, with empty content and a nil
    /// updatedAt for a SOUL.md that doesn't exist on disk. updatedAt is
    /// stamped only from the real file's mtime, so it matches the
    /// onboarding guard's on-disk test — an existing-but-empty SOUL.md
    /// still counts as initialized (onboarding would refuse anyway; the
    /// starter card must not promise what the guard will deny).
    private var personaInitialized: Bool {
        appModel.personalityDocs.contains {
            $0.id.uppercased() == "SOUL"
                && ($0.updatedAt != nil
                    || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var documentsReloadPresentation: PersonalityDocumentsReloadPresentation {
        documentsLoadLatch.presentation
    }

    var body: some View {
        #if DEBUG
        if snapshotOnly {
            docsPanel
        } else {
            pageBody
        }
        #else
        pageBody
        #endif
    }

    private var pageBody: some View {
        Group {
            if isLoadingProfile {
                Text("Reading the saved profile.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if personaInitialized {
                            identityPanel
                            docsPanel
                            ResetPersonaView {
                                await loadProfile(forceRefresh: true)
                            }
                        } else if case .unavailable(let detail) = documentsReloadPresentation {
                            // A failed docs load leaves personalityDocs empty,
                            // which must NOT masquerade as "no persona yet" —
                            // a live persona would see a false Create card
                            // (gpt-5.5 review LOW, 2026-07-03). Fail loud.
                            PersonalityKitSection(label: "Persona unavailable") {
                                Text(detail)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.trouble)
                                    .fixedSize(horizontal: false, vertical: true)
                                Button("Retry") {
                                    Task { await loadProfile(forceRefresh: true) }
                                }
                            }
                        } else {
                            starterPanel
                        }
                    }
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The new shell's `ShellPageFrame` already insets the
                    // column; the classic shell hands a page the bare pane,
                    // so the page keeps its own margin there.
                    .padding(.horizontal, classicShell ? 20 : 0)
                    .padding(.top, classicShell ? 20 : 0)
                }
            }
        }
        .navigationTitle("Personality")
        .task {
            await loadProfile(forceRefresh: false)
        }
    }

    // MARK: starter — the only thing a new user sees

    private var starterPanel: some View {
        PersonalityKitSection(
            label: "Create the agent",
            note: "Everything here can grow and change later."
        ) {
            Text("Name the agent. Add a few things about who the agent should be, if you want.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: $starterAgentName)
                .textFieldStyle(.roundedBorder)

            TextField("Your name (optional)", text: $starterUserName)
                .textFieldStyle(.roundedBorder)

            AdvancedTextEditor(
                title: "A few things about the agent (optional)",
                text: $starterNotes,
                minHeight: 92
            )

            HStack(spacing: 8) {
                Button(starterBusy ? "Creating\u{2026}" : "Create") {
                    Task { await createStarterPersona() }
                }
                .disabled(starterBusy || starterAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let starterError {
                    Text(starterError)
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.trouble)
                }
            }
        }
    }

    @MainActor
    private func createStarterPersona() async {
        starterBusy = true
        starterError = nil
        defer { starterBusy = false }
        let outcome = await PersonalityStarterCreateAction.create(
            appModel: appModel,
            agentName: starterAgentName,
            userName: starterUserName,
            notes: starterNotes
        )
        switch outcome {
        case .created:
            await loadProfile(forceRefresh: true)
        case .notesUnsaved(let documentID, let draft):
            // Onboarding is committed, but the second SOUL write is not.
            // Keep the exact draft in the real editor rather than discarding it.
            documentDraftState.keepUnsavedDraft(draft, for: documentID)
            await loadProfile(forceRefresh: false)
            documentSaveError = PersonalityStarterCreateAction.notesUnsavedMessage
        case .failed(let detail):
            starterError = detail
        }
    }

    // MARK: identity — the one live profile field

    private var identityPanel: some View {
        PersonalityKitSection(
            label: "Name",
            note: "The name shown across the app and in chat."
        ) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Button("Save name") {
                    Task { await saveName() }
                }
                // A name-only save cannot overwrite an unrelated stale profile
                // draft, but it still needs a successfully loaded profile to
                // prove this is an edit rather than an accidental initialization.
                .disabled(appModel.personality == nil || isSavingName
                    || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reload") {
                    Task { await loadProfile(forceRefresh: true) }
                }
                Spacer(minLength: 8)
                if let nameSaveFeedback {
                    Text(nameSaveFeedback.text)
                        .font(ShellType.caption)
                        .foregroundStyle(nameSaveFeedback.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let updatedAt = draft.updatedAt {
                    Text("Updated \(updatedAt)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.tertiary)
                }
            }
        }
    }

    @MainActor
    private func saveName() async {
        guard !isSavingName else { return }
        isSavingName = true
        defer { isSavingName = false }
        switch await appModel.savePersonalityName(draft.name) {
        case .saved(let profile):
            // The field reflects the writer's normalized, persisted profile;
            // it never claims the raw input was saved when the boundary
            // trimmed/capped it differently.
            draft = profile
            nameSaveFeedback = .saved(profile.name)
        case .refused(let detail):
            nameSaveFeedback = .refused(detail)
        case .failed(let detail):
            nameSaveFeedback = .failed(detail)
        }
    }

    // MARK: documents — the persona itself

    private var docsPanel: some View {
        PersonalityKitSection(
            label: "Persona documents",
            note: "These documents guide the agent's identity, expression, and choices. Choose a purpose to read the document or edit it where allowed."
        ) {
            Picker("Document", selection: documentPickerSelection) {
                ForEach(PersonalityDocumentDraftState.usableDocuments(in: appModel.personalityDocs)) { doc in
                    Text(PersonalityDocumentPurpose.label(for: doc.id)).tag(doc.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if let doc = selectedPersonalityDoc {
                PersonalityDocumentPurposeDetail(documentID: doc.id, filename: doc.filename)
            }
            Text("Durable memories — MEMORY.md, when present, contains memories distilled during memory review. It is not listed in this editor.")
                .font(ShellType.caption)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            AdvancedTextEditor(
                title: selectedPersonalityDoc.map { PersonalityDocumentPurpose.label(for: $0.id) } ?? "Document",
                text: Binding(get: { personalityDocDraft }, set: { value in
                    personalityDocDraft = value
                    documentDraftState.recordEdit(value, documents: appModel.personalityDocs)
                }),
                minHeight: 320,
                isReadOnly: selectedPersonalityDocIsMemoryOwnedUser
            )
            .help(selectedPersonalityDocIsMemoryOwnedUser ? PersonalityDocHelpCopy.memoryOwnedDocument : "")

            HStack(spacing: 8) {
                Button("Save document") {
                    let docId = documentDraftState.selectedDocumentID
                    let content = personalityDocDraft
                    guard let revision = documentDraftState.beginSave(documentID: docId, content: content) else { return }
                    Task {
                        let succeeded = await appModel.savePersonalityDoc(id: docId, content: content)
                        documentDraftState.finishSave(documentID: docId, revision: revision, succeeded: succeeded)
                        if succeeded {
                            documentSaveError = nil
                            syncPersonalityDocDraft()
                        } else {
                            documentSaveError = appModel.statusText
                        }
                    }
                }
                .disabled(documentDraftState.selectedDocumentID.isEmpty || selectedPersonalityDocIsMemoryOwnedUser
                    || documentDraftState.savingRevisions[documentDraftState.selectedDocumentID] != nil)

                Button(isReloadingDocuments ? "Reloading…" : "Reload documents") {
                    Task {
                        await reloadDocuments()
                    }
                }
                .disabled(isReloadingDocuments)

                if let path = selectedPersonalityDoc?.path {
                    Text(path)
                        .font(ShellType.label.monospaced())
                        .foregroundStyle(NativeAgentShell.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            if documentDraftState.hasUnsavedDrafts {
                Text("Unsaved edits are kept while you switch documents.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
            if let banner = documentsReloadPresentation.banner {
                Text(banner)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let documentSaveError {
                Text(documentSaveError)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.trouble)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: load

    @MainActor
    private func loadProfile(forceRefresh: Bool) async {
        isLoadingProfile = true
        if forceRefresh || appModel.personality == nil {
            await appModel.refreshForSidebarItem(.personality)
        }
        // Revalidate on every appearance. A cached successful read must not
        // impersonate the current on-disk persona after a later read fails.
        // `reloadDocuments` retains the last good editor buffer but labels it
        // stale, which is safer than replacing it with an empty starter card.
        await reloadDocuments()
        draft = appModel.personality ?? .defaultProfile
        syncPersonalityDocDraft()
        isLoadingProfile = false
    }

    private var selectedPersonalityDoc: PersonalityDoc? {
        PersonalityDocumentDraftState.usableDocuments(in: appModel.personalityDocs)
            .first { $0.id == documentDraftState.selectedDocumentID }
    }

    private var documentPickerSelection: Binding<String> {
        Binding(
            get: { documentDraftState.selectedDocumentID },
            set: { selectedID in
                personalityDocDraft = documentDraftState.select(
                    selectedID,
                    documents: appModel.personalityDocs
                )
            }
        )
    }

    private var selectedPersonalityDocIsMemoryOwnedUser: Bool {
        selectedPersonalityDoc?.id.uppercased() == "USER"
    }

    private func syncPersonalityDocDraft() {
        personalityDocDraft = documentDraftState.reconcile(documents: appModel.personalityDocs)
    }

    @MainActor
    private func reloadDocuments() async {
        guard !isReloadingDocuments else { return }
        isReloadingDocuments = true
        defer { isReloadingDocuments = false }
        let outcome = await appModel.reloadPersonalityDocuments()
        documentsLoadLatch.record(outcome)
        switch outcome {
        case .loaded:
            syncPersonalityDocDraft()
        case .failed:
            // Keep appModel.personalityDocs untouched: they are retained
            // evidence, not a freshly read empty persona.
            break
        }
    }
}

/// Owns the document-reader outcome used by `loadProfile`. A save failure is
/// intentionally not admitted here: only the canonical reader can say the
/// mounted document set is current, stale, or unavailable. That keeps a write
/// error from being misreported as a reader outage and lets the next successful
/// reader result clear the latch deterministically.
struct PersonalityDocumentsLoadLatch: Equatable {
    private enum State: Equatable {
        case unattempted
        case current
        case failed(detail: String, retainedDocumentCount: Int)
    }

    private var state: State = .unattempted

    var presentation: PersonalityDocumentsReloadPresentation {
        switch state {
        case .unattempted, .current:
            return .current
        case .failed(let detail, let retainedDocumentCount):
            return PersonalityDocumentsReloadPresentation.resolve(
                retainedDocumentCount: retainedDocumentCount,
                errorDetail: detail
            )
        }
    }

    mutating func record(_ outcome: PersonalityDocumentsReloadOutcome) {
        switch outcome {
        case .loaded:
            state = .current
        case .failed(let detail, let retainedDocumentCount):
            state = .failed(detail: detail, retainedDocumentCount: retainedDocumentCount)
        }
    }
}

/// The mounted Personality view must not use its document count as proof that
/// the latest read succeeded. A failed refresh over prior rows is stale;
/// failure with no prior rows is unavailable rather than a starter persona.
enum PersonalityDocumentsReloadPresentation: Equatable {
    case current
    case retainedStale(documentCount: Int, detail: String)
    case unavailable(String)

    static func resolve(documents: [PersonalityDoc], errorDetail: String?) -> Self {
        resolve(retainedDocumentCount: documents.count, errorDetail: errorDetail)
    }

    static func resolve(retainedDocumentCount: Int, errorDetail: String?) -> Self {
        guard let errorDetail else { return .current }
        let detail = errorDetail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty
            ? "The persona document reader returned no diagnostic details."
            : detail
        return retainedDocumentCount == 0
            ? .unavailable("The persona documents couldn't be read: \(message)")
            : .retainedStale(documentCount: retainedDocumentCount, detail: message)
    }

    var banner: String? {
        switch self {
        case .current:
            return nil
        case .retainedStale(let count, let detail):
            return "Couldn't reload persona documents; showing \(count) previously loaded document\(count == 1 ? "" : "s"). \(detail)"
        case .unavailable:
            return nil
        }
    }
}

private struct PersonalityNameSaveFeedback {
    enum Kind {
        case saved
        case refused
        case failed
    }

    let kind: Kind
    let text: String

    static func saved(_ persistedName: String) -> Self {
        .init(kind: .saved, text: "Saved as \(persistedName)")
    }

    static func refused(_ detail: String) -> Self {
        .init(kind: .refused, text: detail)
    }

    static func failed(_ detail: String) -> Self {
        .init(kind: .failed, text: "Could not save name: \(detail)")
    }

    var color: Color {
        switch kind {
        case .saved: return NativeAgentShell.calm
        case .refused, .failed: return NativeAgentShell.trouble
        }
    }
}

/// An eyebrow, one card of controls, and the quiet line under it — the shape
/// every group on an Advanced page takes.
private struct PersonalityKitSection<Content: View>: View {
    let label: String
    var note: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .fill(NativeAgentShell.quietFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                    .strokeBorder(NativeAgentShell.hairline, lineWidth: 1)
            )

            if let note {
                Text(note)
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// Evaluation-only fault boundary for the starter panel's second, durable
/// write. It is nil in ordinary app operation, so it cannot alter production
/// behavior unless an executable evaluation explicitly installs it.
@MainActor
enum PersonalityStarterPanelEvaluation {
    static var beforePersistingNotes: (() -> Void)?
}

// MARK: - Plain-English personality document help copy
//
// UI-6 (2026-08-01, public era): the tooltip named both the file and the
// memory backend. A user needs one thing from it — why this document is
// read-only and where to change it instead.
enum PersonalityDocHelpCopy {
    static let memoryOwnedDocument =
        "This document is written for you from your long-term memory profile, so it cannot be edited here. To change what it says, edit your memories on the Memory page."
}

/// Friendly names describe the existing documents; document IDs still own selection and saving.
enum PersonalityDocumentPurpose {
    static func label(for id: String) -> String {
        switch id.uppercased() {
        case "SOUL": "Identity"
        case "VOICE": "Expression"
        case "USER": "About you"
        case "GROWTH": "Personal growth"
        case "MEMORY": "Durable memories"
        case "AGENTS": "Working guidelines"
        default: id
        }
    }

    static func explanation(for id: String) -> String {
        switch id.uppercased() {
        case "SOUL": "The agent's identity, values, and sense of purpose. Editable here."
        case "VOICE": "How the agent speaks and expresses ideas. Editable here."
        case "USER": "What the agent knows about you. Generated from your long-term memory profile and read-only here; make changes on the Memory page."
        case "GROWTH": "Lessons and changes in the agent's outlook, including approved personal growth. Editable here."
        case "MEMORY": "Durable memories distilled during memory review. Not listed in this editor."
        case "AGENTS": "Guidelines for how the agent approaches work and makes decisions. Editable here."
        default: "Read the document below."
        }
    }
}

struct PersonalityDocumentPurposeDetail: View {
    let documentID: String
    let filename: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(PersonalityDocumentPurpose.explanation(for: documentID))
                .font(ShellType.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(filename)
                .font(ShellType.caption.monospaced())
                .foregroundStyle(NativeAgentShell.secondary)
        }
    }
}
