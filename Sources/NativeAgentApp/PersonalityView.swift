import Onboarding
import SwiftUI
import AppKit
import NativeAgentShared
import PersonaEngine
// Blueprint: | `PersonalityView.swift` | `PersonalityView` struct; document editing makes no claim that memory review writes the optional MEMORY.md input |

// Persona documents own personality; guarded onboarding cannot overwrite a live persona.

/// Owns the picker/editor transition as one value state. In particular, a
/// document switch may replace the visible editor text, but it must never
/// discard the departing document's unsaved draft.
struct PersonalityDocumentDraftState: Equatable {
    private(set) var selectedDocumentID = ""
    private(set) var unsavedDrafts: [String: String] = [:]
    private var editRevisions: [String: Int] = [:]
    private(set) var savingRevisions: [String: Int] = [:]

    var hasUnsavedDrafts: Bool { !unsavedDrafts.isEmpty }

    static func usableDocuments(in documents: [PersonaDocSpec]) -> [PersonaDocSpec] {
        documents.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    mutating func select(_ requestedID: String, documents: [PersonaDocSpec]) -> String {
        selectedDocumentID = requestedID
        return reconcile(documents: documents)
    }

    /// Reconcile after a load/reload. A missing selection moves to the first
    /// usable document; an empty or malformed catalog has no selected id and
    /// no editable-looking empty fallback.
    mutating func reconcile(documents: [PersonaDocSpec]) -> String {
        let documents = Self.usableDocuments(in: documents)
        guard let selected = documents.first(where: { $0.id == selectedDocumentID })
            ?? documents.first else {
            selectedDocumentID = ""
            return ""
        }
        selectedDocumentID = selected.id
        return unsavedDrafts[selected.id] ?? selected.content
    }

    mutating func recordEdit(_ content: String, documents: [PersonaDocSpec]) {
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

struct PersonalityView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingProfile = true
    @State private var profileReadCompleted = false
    @State private var profileReadInFlight = false
    @State private var documentSeed = PersonalityDocumentDraftState()
    private var documentDraftState: PersonalityDocumentDraftState {
        get { appModel.editDraft("persona.documents", seed: documentSeed) }
        nonmutating set {
            if newValue.hasUnsavedDrafts {
                appModel.setEditDraft(newValue, for: "persona.documents")
            } else {
                documentSeed = newValue
                appModel.clearEditDraft("persona.documents")
            }
        }
    }
    private var personalityDocDraft: String {
        get { documentDraftState.unsavedDrafts[documentDraftState.selectedDocumentID] ?? selectedPersonalityDoc?.content ?? "" }
        nonmutating set { documentDraftState.recordEdit(newValue, documents: appModel.engine.persona.documents) }
    }

    // Starter card state (shown only while no persona exists).
    private var starterAgentName: Binding<String> { appModel.editBinding("persona/new/agentName", seed: "") }
    private var starterUserName: Binding<String> { appModel.editBinding("persona/new/userName", seed: "") }
    private var starterNotes: Binding<String> { appModel.editBinding("persona/new/notes", seed: "") }
    private var nameDraft: Binding<String> { appModel.editBinding("persona.name", seed: appModel.engine.persona.profile?.name ?? "NativeAgent") }
    @State private var starterBusy = false
    @State private var starterError: String?
    @State private var documentSaveError: String?
    @State private var isReloadingDocuments = false
    @State private var isSavingName = false
    @State private var nameSaveFeedback: PersonalityNameSaveFeedback?

    /// SOUL.md is the identity marker everywhere else in the system
    /// (defaultPersonaRoot, onboarding guards) — same rule here. Presence
    /// of the SOUL *spec* is not enough: listPersonaDocSpecs returns all
    /// five specs on a fresh install too, with empty content and a nil
    /// updatedAt for a SOUL.md that doesn't exist on disk. updatedAt is
    /// stamped only from the real file's mtime, so it matches the
    /// onboarding guard's on-disk test — an existing-but-empty SOUL.md
    /// still counts as initialized (onboarding would refuse anyway; the
    /// starter card must not promise what the guard will deny).
    private var personaInitialized: Bool {
        appModel.engine.persona.documents.contains {
            $0.id.uppercased() == "SOUL"
                && ($0.updatedAt != nil
                    || !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var documentsReloadPresentation: PersonalityDocumentsReloadPresentation {
        PersonalityDocumentsReloadPresentation.resolve(documents: appModel.engine.persona.documents, errorDetail: appModel.engine.persona.documentsError)
    }

    var body: some View {
        pageBody
    }

    private var pageBody: some View {
        Group {
            if isLoadingProfile && !profileReadCompleted && documentDraftState.selectedDocumentID.isEmpty {
                Text("Reading the saved profile.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                        if personaInitialized {
                            identityPanel
                            docsPanel
                            ResetPersonaView {
                                await loadProfile(forceRefresh: true)
                            }
                        } else if case .unavailable(let detail) = documentsReloadPresentation {
                            // A failed document load is unavailable, never evidence that no persona exists.
                            AdvancedSection(title: "Persona unavailable", card: .single) {
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
                }
            }
        }
        .navigationTitle("Personality")
        .quietReadTask {
            await loadProfile(forceRefresh: false)
        }
    }

    // MARK: starter — the only thing a new user sees

    private var starterPanel: some View {
        AdvancedSection(
            title: "Create the agent",
            card: .single,
            note: "Everything here can grow and change later."
        ) {
            Text("Name the agent. Add a few things about who the agent should be, if you want.")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Name", text: starterAgentName)
                .textFieldStyle(.roundedBorder)

            TextField("Your name (optional)", text: starterUserName)
                .textFieldStyle(.roundedBorder)

            AdvancedTextEditor(
                title: "A few things about the agent (optional)",
                text: starterNotes,
                minHeight: 92
            )

            HStack(spacing: 8) {
                Button(starterBusy ? "Creating\u{2026}" : "Create") {
                    Task { await createStarterPersona() }
                }
                .disabled(starterBusy || starterAgentName.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
        let submitted = [starterAgentName.wrappedValue, starterUserName.wrappedValue, starterNotes.wrappedValue]
        let outcome = await SwiftNativeOnboardingClient.createStarterPersona(
            agentName: starterAgentName.wrappedValue,
            userName: starterUserName.wrappedValue,
            notes: starterNotes.wrappedValue,
            complete: { name, user in
                try await appModel.completeOnboarding(agentName: name, personaType: "ai", userName: user)
            },
            reload: { await appModel.loadPersonalityDocs() ? appModel.engine.persona.documents : nil },
            append: { await appModel.savePersonalityDoc(id: $0, content: $1, appending: true) },
            failureMessage: { UserFacingError.message($0, action: "create the personality docs") }
        )
        switch outcome {
        case .created:
            clearStarterDraft(submitted: submitted)
            await loadProfile(forceRefresh: true)
        case .notesUnsaved(let documentID, let draft):
            clearStarterDraft(submitted: submitted)
            // Onboarding is committed, but the setup section append is not.
            // Keep the exact draft in the real editor rather than discarding it.
            documentDraftState.keepUnsavedDraft(draft, for: documentID)
            await loadProfile(forceRefresh: false)
            documentSaveError = "Setup notes were not saved. They are open as an unsaved SOUL.md draft below."
        case .failed(let detail):
            starterError = detail
        }
    }

    private func clearStarterDraft(submitted: [String]) {
        guard [starterAgentName.wrappedValue, starterUserName.wrappedValue, starterNotes.wrappedValue] == submitted else { return }
        for field in ["agentName", "userName", "notes"] { appModel.clearEditDraft("persona/new/\(field)") }
    }

    // MARK: identity — the one live profile field

    private var identityPanel: some View {
        AdvancedSection(
            title: "Name",
            card: .single,
            note: "The name shown across the app and in chat."
        ) {
            TextField("Name", text: nameDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(isLoadingProfile)

            HStack(spacing: 8) {
                Button(isSavingName ? "Saving name…" : "Save name") {
                    Task { await saveName() }
                }
                // A name-only save cannot overwrite an unrelated stale profile
                // draft, but it still needs a successfully loaded profile to
                // prove this is an edit rather than an accidental initialization.
                .disabled(appModel.engine.persona.profile == nil || isSavingName || isLoadingProfile
                    || nameDraft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isSavingName { ProgressView().controlSize(.small) }
                Button(isLoadingProfile ? "Reloading…" : "Reload") {
                    appModel.clearEditDraft("persona.name")
                    Task { await loadProfile(forceRefresh: true) }
                }
                .disabled(isLoadingProfile || isReloadingDocuments)
                if isLoadingProfile {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 8)
                if let nameSaveFeedback {
                    Text(nameSaveFeedback.text)
                        .font(ShellType.caption)
                        .foregroundStyle(nameSaveFeedback.color)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                if let updatedAt = appModel.engine.persona.profile?.updatedAt {
                    Text("Updated \(updatedAt)")
                        .font(ShellType.caption)
                        .foregroundStyle(NativeAgentShell.secondary)
                }
            }
        }
    }

    @MainActor
    private func saveName() async {
        guard !isSavingName else { return }
        isSavingName = true
        defer { isSavingName = false }
        let submitted = nameDraft.wrappedValue
        switch await appModel.savePersonalityName(submitted) {
        case .saved(let profile):
            if nameDraft.wrappedValue == submitted { appModel.clearEditDraft("persona.name") }
            // The field reflects the writer's normalized, persisted profile;
            // it never claims the raw input was saved when the boundary
            // trimmed/capped it differently.
            nameSaveFeedback = .saved(profile.name)
        case .refused(let detail):
            nameSaveFeedback = .refused(detail)
        case .failed(let detail):
            nameSaveFeedback = .failed(detail)
        }
    }

    // MARK: documents — the persona itself

    private var docsPanel: some View {
        AdvancedSection(
            title: "Persona documents",
            card: .single,
            note: "These documents guide my identity, expression, and choices. Choose a purpose to read the document or edit it where allowed."
        ) {
            Picker("Document", selection: documentPickerSelection) {
                ForEach(PersonalityDocumentDraftState.usableDocuments(in: appModel.engine.persona.documents)) { doc in
                    Text(PersonalityDocumentPurpose.label(for: doc.id)).tag(doc.id)
                }
            }
            .pickerStyle(.segmented)
            .hazeTinted(.segments)
            .labelsHidden()
            if let doc = selectedPersonalityDoc {
                PersonalityDocumentPurposeDetail(documentID: doc.id, filename: doc.filename)
            }
            AdvancedTextEditor(
                title: selectedPersonalityDoc.map { PersonalityDocumentPurpose.label(for: $0.id) } ?? "Document",
                text: Binding(get: { personalityDocDraft }, set: { value in
                    personalityDocDraft = value
                }),
                minHeight: 320,
                isReadOnly: selectedPersonalityDocIsMemoryOwnedUser
            )
            .help(selectedPersonalityDocIsMemoryOwnedUser ? PersonalityDocHelpCopy.memoryOwnedDocument : "")

            HStack(spacing: 8) {
                Button(selectedDocumentSaving ? "Saving document…" : "Save document") {
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
                    || selectedDocumentSaving || isLoadingProfile)
                if selectedDocumentSaving { ProgressView().controlSize(.small) }

                Button(isReloadingDocuments ? "Reloading…" : "Reload documents") {
                    Task {
                        await reloadDocuments()
                    }
                }
                .disabled(isReloadingDocuments || isLoadingProfile)

                if let path = selectedPersonalityDoc?.path {
                    Text(path)
                        .font(ShellType.label.monospaced())
                        .foregroundStyle(NativeAgentShell.secondary)
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
        guard !profileReadInFlight, !isReloadingDocuments else { return }
        profileReadInFlight = true
        isLoadingProfile = true
        defer {
            isLoadingProfile = false
            profileReadInFlight = false
            profileReadCompleted = true
        }
        syncPersonalityDocDraft()
        if forceRefresh || appModel.engine.persona.profile == nil {
            await appModel.refreshForSidebarItem(.personality)
        } else {
            // Revalidate cached documents on every appearance; a failed read stays stale.
            await reloadDocuments()
        }
        syncPersonalityDocDraft()
    }

    private var selectedPersonalityDoc: PersonaDocSpec? {
        PersonalityDocumentDraftState.usableDocuments(in: appModel.engine.persona.documents)
            .first { $0.id == documentDraftState.selectedDocumentID }
    }

    private var documentPickerSelection: Binding<String> {
        Binding(
            get: { documentDraftState.selectedDocumentID },
            set: { selectedID in
                _ = documentDraftState.select(
                    selectedID,
                    documents: appModel.engine.persona.documents
                )
            }
        )
    }

    private var selectedPersonalityDocIsMemoryOwnedUser: Bool {
        selectedPersonalityDoc?.id.uppercased() == "USER"
    }

    private var selectedDocumentSaving: Bool {
        documentDraftState.savingRevisions[documentDraftState.selectedDocumentID] != nil
    }

    private func syncPersonalityDocDraft() {
        _ = documentDraftState.reconcile(documents: appModel.engine.persona.documents)
    }

    @MainActor
    private func reloadDocuments() async {
        guard !isReloadingDocuments else { return }
        isReloadingDocuments = true
        defer { isReloadingDocuments = false }
        _ = await appModel.reloadPersonalityDocuments()
        syncPersonalityDocDraft()
    }
}

/// The mounted Personality view must not use its document count as proof that
/// the latest read succeeded. A failed refresh over prior rows is stale;
/// failure with no prior rows is unavailable rather than a starter persona.
enum PersonalityDocumentsReloadPresentation: Equatable {
    case current
    case retainedStale(documentCount: Int, detail: String)
    case unavailable(String)

    static func resolve(documents: [PersonaDocSpec], errorDetail: String?) -> Self {
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

// MARK: - Plain-English personality document help copy
//
// Explain why a document is read-only and where to change it.
enum PersonalityDocHelpCopy {
    static let memoryOwnedDocument =
        "This document is written for you from your long-term memory profile, so it cannot be edited here. To change what it says, edit your memories on the Memories page."
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
        case "SOUL": "My identity, values, and sense of purpose. Editable here."
        case "VOICE": "How I speak and express ideas. Editable here."
        case "USER": "What I know about you. Generated from your long-term memory profile and read-only here; make changes on the Memories page."
        case "GROWTH": "Lessons and changes in my outlook, including approved personal growth. Editable here."
        case "MEMORY": "Durable memories distilled during memory review. Not listed in this editor."
        case "AGENTS": "Guidelines for how I approach work and make decisions. Editable here."
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
                .foregroundStyle(NativeAgentShell.text.opacity(0.85))
        }
    }
}
