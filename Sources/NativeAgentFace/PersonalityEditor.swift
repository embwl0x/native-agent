import Foundation
import SwiftUI
import NativeAgentShared
// Blueprint: | `PersonalityEditor.swift` | Shared starter and identity forms, field settlement and document conflicts; memory owns USER |

struct PersonalityEditor: View {
    @Environment(AppModel.self) private var appModel
    @State private var isLoadingProfile = true
    @State private var profileReadCompleted = false
    @State private var profileReadInFlight = false
    @State private var selectedDocumentID = ""
    @State private var documentSaveError: String?
    @State private var isReloadingDocuments = false
    @State private var conflictDocumentID: String?
    @State private var conflictVersion: PersonaDocSpec?

    private var session: FacePageSession { appModel.pageSessions.page("persona.forms") }
    private var personaInitialized: Bool? {
        appModel.face.slot(.onboarding).select("identityPresent", as: OnboardingFace.self) {
            guard case .ready? = $0?.state else { return nil }
            switch $0.flatMap({ OnboardingDisposition(rawValue: $0.disposition) }) {
            case .alreadyOnboarded, .repairProfile, .profileUnreadable: return true
            case .fresh: return false
            default: return nil
            }
        }
    }
    private var selectedDocument: PersonaDocSpec? {
        appModel.personaDocuments.first { $0.id == selectedDocumentID } ?? appModel.personaDocuments.first
    }
    private var documentsReloadPresentation: PersonalityDocumentsReloadPresentation {
        .resolve(documents: appModel.personaDocuments, errorDetail: appModel.personaDocumentsIssue)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AliveMetrics.sectionSpacing) {
                if !profileReadCompleted && isLoadingProfile {
                    Text("Reading the saved profile.").foregroundStyle(NativeAgentShell.secondary)
                } else if personaInitialized == true {
                    identityPanel
                    docsPanel
                } else if case .unavailable(let detail) = documentsReloadPresentation {
                    Text(detail).foregroundStyle(NativeAgentShell.trouble)
                    Button("Read again") { Task { await loadProfile(forceRefresh: true) } }
                } else if personaInitialized == false {
                    starterPanel
                } else {
                    Text("Waiting for the identity owner.").foregroundStyle(NativeAgentShell.secondary)
                }
            }
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Personality")
        .quietReadTask { await loadProfile(forceRefresh: false) }
    }

    private var starterBlock: PartFace.Block {
        .init(kind: "form", key: "persona.starter", fields: [
            .init(id: "agentName", label: "Agent name", value: .string(""), required: true),
            .init(id: "userName", label: "Your name", value: .string(""), required: true),
            .init(id: "notes", label: "A few things about the agent (optional)", kind: "lines",
                value: .string(""))
        ], submit: [.init(id: "create", label: "Create", role: .primary, call: .init("persona.starter.create"))])
    }
    private var starterPanel: some View {
        FaceView(face: PartFace(title: "Create the agent", line: "Everything here can grow and change later.", sections: [
            .init(id: "persona.starter", rows: [], block: starterBlock)
        ]), door: ClosureFaceDoor(open: { _ in }, waitingOn: "the identity owner", perform: createStarter), session: session)
    }
    private func createStarter(_ input: FaceActSubmission) async -> FaceActOutcome {
        var committed: [FaceCommittedField] = []
        do {
            guard case .string(let agent)? = input.values?["agentName"], case .string(let user)? = input.values?["userName"],
                  case .string(let notes)? = input.values?["notes"] else { throw formFailure("Enter the names and setup notes.") }
            if let issue = NativeAgentIdentity.nameValidationMessage(agent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                throw WireFailure(code: "name_invalid", message: issue, cause: nil, effects: .none, fields: ["agentName": issue])
            }
            if input.checking { return await readStarter(agent: agent, user: user, notes: notes) }
            let reply = try await appModel.protectedFormAct(.createStarterPersona(.init(agentName: agent, personaType: "ai", userName: user)))
            guard case .result(.object(let fields)) = reply, case .bool(let ok)? = fields["ok"] else {
                throw WireFailure(code: "starter_unconfirmed", message: "The identity owner did not confirm creation.", cause: nil, effects: .unknown)
            }
            guard ok else {
                throw WireFailure(code: "starter_failed", message: "The identity was not confirmed.",
                    cause: fields["detail"]?.stringValue ?? fields["error"]?.stringValue, effects: .unknown)
            }
            guard case .string(let savedAgent)? = fields["agentName"], case .string(let savedUser)? = fields["userName"] else {
                throw WireFailure(code: "starter_unconfirmed", message: "The saved names were not returned.", cause: nil, effects: .known)
            }
            committed = [.init(id: "agentName", value: .string(savedAgent)), .init(id: "userName", value: .string(savedUser))]
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let reading = try await appModel.readPersonaFormState(documents: true)
                guard let soul = reading.documents.first(where: { $0.id.uppercased() == "SOUL" }) else {
                    throw WireFailure(code: "soul_unavailable", message: "The names were saved, but SOUL is not available for the setup notes.",
                        cause: nil, effects: .known)
                }
                let content = soul.content + "\n\n## From setup\n" + trimmed + "\n"
                do { _ = try await appModel.savePersonaFormDocument(id: soul.id, content: content, expectedContent: soul.content) }
                catch {
                    keepUnsavedDocument(content, in: soul)
                    throw error
                }
            }
            committed.append(.init(id: "notes", value: .string(notes)))
            await loadProfile(forceRefresh: true)
            return .init(words: "Identity created.", effects: .known, accepted: true, committed: committed)
        } catch {
            var failure = (error as? WireFailure) ?? WireFailure(code: "starter_unconfirmed", message: "Setup did not fully finish.",
                cause: error.localizedDescription, effects: .unknown)
            if !committed.isEmpty {
                failure.message = "The names were saved. Setup notes remain unconfirmed; read SOUL before saving them."
                failure.committed = committed + (failure.committed ?? [])
                documentSaveError = failure.localizedDescription
            }
            return .interrupted(failure)
        }
    }
    private func readStarter(agent: String, user: String, notes: String) async -> FaceActOutcome {
        do {
            let profile = try await appModel.readPersonaFormState(documents: false).profile
            guard profile?.name == agent.trimmingCharacters(in: .whitespacesAndNewlines),
                  profile?.userName == user.trimmingCharacters(in: .whitespacesAndNewlines) else {
                return .init(words: "The saved identity does not confirm this submission.", effects: .unknown)
            }
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let docs = try await appModel.readPersonaFormState(documents: true)
                guard docs.documents.contains(where: { $0.id.uppercased() == "SOUL" && $0.content.contains("\n\n## From setup\n" + trimmed + "\n") }) else {
                    return .init(words: "The names match. The setup notes are not confirmed; read SOUL before saving them.", effects: .unknown)
                }
            }
            return .init(words: "The saved identity confirms this submission.", effects: .known, accepted: true,
                committed: [.init(id: "agentName", value: .string(agent)), .init(id: "userName", value: .string(user)),
                    .init(id: "notes", value: .string(notes))])
        } catch { return .interrupted(error) }
    }

    private var identityPanel: some View {
        FaceView(face: PartFace(sections: [
            .init(id: "persona.name", title: "Name", footer: "The name shown across the app and in chat.", rows: [],
                block: .init(kind: "form", key: "persona.name",
                    fields: [.init(id: "name", label: "Name", value: .string(appModel.personaProfile?.name ?? ""), required: true)],
                    submit: [.init(id: "save", label: "Save name", call: .init("persona.name.save"),
                        unavailable: appModel.personaProfile == nil ? "Read the saved profile before saving its name." : nil)]))
        ]), door: identityDoor, session: session)
    }

    private var docsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Document", selection: Binding(get: { selectedDocument?.id ?? "" }, set: { selectedDocumentID = $0 })) {
                ForEach(appModel.personaDocuments) { document in
                    Text(PersonalityDocumentPurpose.label(for: document.id)).tag(document.id)
                }
            }
            .pickerStyle(.segmented)
            .hazeTinted(.segments)
            if let document = selectedDocument {
                Text(PersonalityDocumentPurpose.explanation(for: document.id)).font(ShellType.body)
                    .fixedSize(horizontal: false, vertical: true)
                if ["USER", "MEMORY"].contains(document.id.uppercased()) {
                    FaceDocumentContent(text: document.content)
                    Text(PersonalityDocHelpCopy.memoryOwnedDocument).font(ShellType.caption)
                }
                FaceView(face: documentFace(document), door: identityDoor, session: session)
                if conflictDocumentID == document.id, let conflictVersion, conflictVersion.id == document.id {
                    Text("Saved version read for this conflict — compare with your draft above").font(ShellType.label)
                    FaceDocumentContent(text: conflictVersion.content)
                }
            } else {
                Text("No persona document is available to edit. Read the documents again.").foregroundStyle(NativeAgentShell.trouble)
                Button("Read documents") { Task { await reloadDocuments() } }
            }
            if let banner = documentsReloadPresentation.banner { Text(banner).foregroundStyle(NativeAgentShell.trouble) }
            if let documentSaveError { Text(documentSaveError).foregroundStyle(NativeAgentShell.trouble) }
            unsavedSetupNotes
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func documentBlock(_ document: PersonaDocSpec) -> PartFace.Block {
        let key = "persona.document." + document.id
        let seed = PartFace.Block(kind: "form", key: key,
            fields: [.init(id: "content", label: PersonalityDocumentPurpose.label(for: document.id),
                kind: "lines", value: .string(document.content))], submit: [])
        let baseline = session.formBaseline(seed, section: "face:" + key)
        return PartFace.Block(kind: "form", key: key, revision: document.updatedAt, fields: seed.fields,
            submit: [.init(id: "save", label: "Save document",
                call: .init("persona.document.save", ["id": .string(document.id),
                    "expectedContent": baseline["content"] ?? .string(document.content)]))])
    }

    private func documentFace(_ document: PersonaDocSpec) -> PartFace {
        let key = "persona.document." + document.id
        var sections: [PartFace.Section] = []
        if !["USER", "MEMORY"].contains(document.id.uppercased()) {
            sections.append(.init(id: key, rows: [], block: documentBlock(document)))
        }
        var actions: [PartFace.Action] = [.init(id: "reload", label: "Read documents again", call: .init("persona.documents.reload"))]
        if conflictDocumentID == document.id {
            actions.append(.init(id: "use-saved", label: "Use saved version", role: .destructive,
                call: .init("persona.document.use-saved", ["id": .string(document.id)])))
        }
        sections.append(.init(id: key + ".commands", footer: document.path, rows: [
            .init(id: key + ".commands", title: "Document", actions: actions)
        ]))
        return PartFace(sections: sections)
    }

    private var identityDoor: ClosureFaceDoor {
        ClosureFaceDoor(open: { _ in }, waitingOn: "the identity owner") { submission in
            do {
                if submission.checking { return await readFormOutcome(submission) }
                switch submission.expectedCall.action {
                case "persona.name.save":
                    guard case .string(let name)? = submission.values?["name"] else { throw formFailure("The name field is missing.") }
                    if let detail = NativeAgentIdentity.nameValidationMessage(name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        throw WireFailure(code: "persona_name_invalid", message: detail, cause: nil, effects: .none, fields: ["name": detail])
                    }
                    let profile = try await appModel.savePersonaFormName(name)
                    return .init(words: "Saved as " + profile.name, effects: .known, accepted: true,
                        committed: [.init(id: "name", value: .string(profile.name))])
                case "persona.document.save":
                    guard case .string(let id)? = submission.expectedCall.args["id"],
                          case .string(let baseline)? = submission.expectedCall.args["expectedContent"],
                          case .string(let content)? = submission.values?["content"] else {
                        throw formFailure("The document, its baseline or its edited contents are missing.")
                    }
                    do {
                        let saved = try await appModel.savePersonaFormDocument(id: id, content: content, expectedContent: baseline)
                        conflictDocumentID = nil
                        return .init(words: saved.filename + " saved", effects: .known, accepted: true,
                            committed: [.init(id: "content", value: .string(saved.content))])
                    } catch {
                        if let failure = error as? WireFailure, failure.code == "persona_document_conflict" {
                            conflictDocumentID = id
                            do {
                                let state = try await appModel.readPersonaFormState(documents: true)
                                conflictVersion = state.documents.first { $0.id == id }
                            } catch {
                                documentSaveError = "The draft is kept. The saved version could not be read: " + error.localizedDescription
                            }
                        }
                        throw error
                    }
                case "persona.documents.reload":
                    _ = try await appModel.readPersonaFormState(documents: true)
                    return .init(words: "Persona documents read.", effects: .none, accepted: true)
                case "persona.document.use-saved":
                    guard case .string(let id)? = submission.expectedCall.args["id"],
                          let document = conflictVersion, document.id == id else {
                        throw formFailure("Read the saved document before replacing the draft.")
                    }
                    let block = documentBlock(document)
                    session.clearForm(block, section: "face:persona.document." + id)
                    session.setFormValue(.string(document.content), field: "content", block: block, section: "face:persona.document." + id)
                    conflictDocumentID = nil
                    return .init(words: "The editor shows the saved version.", effects: .none, accepted: true)
                default: throw formFailure("This identity form has no owner for that command.")
                }
            } catch {
                return .interrupted(error)
            }
        }
    }

    private func readFormOutcome(_ submission: FaceActSubmission) async -> FaceActOutcome {
        do {
            let state = try await appModel.readPersonaFormState(documents: submission.expectedCall.action != "persona.name.save")
            if submission.expectedCall.action == "persona.documents.reload" {
                return .init(words: "Persona documents read.", effects: .none, accepted: true)
            }
            if submission.expectedCall.action == "persona.name.save", let profile = state.profile,
               case .string(let submitted)? = submission.values?["name"],
               profile.name == submitted.trimmingCharacters(in: .whitespacesAndNewlines) {
                return .init(words: "The saved name matches.", effects: .known, accepted: true,
                    committed: [.init(id: "name", value: .string(profile.name))])
            }
            if submission.expectedCall.action == "persona.document.save",
               let id = submission.expectedCall.args["id"]?.stringValue,
               let document = state.documents.first(where: { $0.id == id }) {
                if case .string(let submitted)? = submission.values?["content"], document.content == submitted {
                    return .init(words: "The saved document matches.", effects: .known, accepted: true,
                        committed: [.init(id: "content", value: .string(document.content))])
                }
                conflictDocumentID = id
                conflictVersion = document
            }
            return .init(words: "The owner read does not confirm this save. Compare the saved version before deciding what to do.",
                effects: .unknown)
        } catch { return .interrupted(error) }
    }

    private func formFailure(_ cause: String) -> WireFailure {
        WireFailure(code: "persona_form_refused", message: "The identity form was not saved.", cause: cause, effects: .none)
    }

    private func keepUnsavedDocument(_ content: String, in document: PersonaDocSpec) {
        selectedDocumentID = document.id
        session.setFormValue(.string(content), field: "content", block: documentBlock(document), section: "face:persona.document." + document.id)
    }

    @ViewBuilder private var unsavedSetupNotes: some View {
        if let outcome = session.operations["persona.starter"]?.outcome,
           outcome.committed?.contains(where: { $0.id == "agentName" }) == true,
           let notes = session.formValues(starterBlock, section: "face:persona.starter")["notes"]?.stringValue,
           !notes.isEmpty {
            Text("Unsaved setup notes").font(ShellType.label)
            FaceDocumentContent(text: notes)
            FaceView(face: PartFace(sections: [.init(id: "persona.setup-notes", rows: [
                .init(id: "persona.setup-notes", title: "Keep editing the notes", actions: [
                    .init(id: "open", label: "Read SOUL and open its editor", call: .init("persona.setup-notes.open"))])
            ])]), door: ClosureFaceDoor(open: { _ in }) { _ in
                do {
                    let reading = try await appModel.readPersonaFormState(documents: true)
                    guard let soul = reading.documents.first(where: { $0.id.uppercased() == "SOUL" }) else {
                        throw formFailure("SOUL is not available. The setup notes are kept here.")
                    }
                    let section = "\n\n## From setup\n" + notes.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    if soul.content.contains(section) {
                        return .init(words: "These setup notes are present in the saved SOUL document.", effects: .none, accepted: true)
                    }
                    keepUnsavedDocument(soul.content + section, in: soul)
                    return .init(words: "The notes are in the SOUL editor. Review them and Save document.", effects: .none, accepted: true)
                } catch {
                    return .interrupted(error)
                }
            }, session: session)
        }
    }

    private func loadProfile(forceRefresh: Bool) async {
        guard !profileReadInFlight else { return }
        profileReadInFlight = true
        isLoadingProfile = true
        defer { profileReadInFlight = false; isLoadingProfile = false; profileReadCompleted = true }
        if forceRefresh || appModel.personaProfile == nil { await appModel.refreshForSidebarItem(.personality) }
        else { await reloadDocuments() }
    }

    private func reloadDocuments() async {
        guard !isReloadingDocuments else { return }
        isReloadingDocuments = true
        defer { isReloadingDocuments = false }
        _ = await appModel.reloadPersonalityDocuments()
    }
}

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

enum PersonalityDocHelpCopy {
    static let memoryOwnedDocument =
        """
            This document is written for you from your long-term memory profile, so it cannot be edited here. To change what it \
            says, edit your memories on the Memories page.
            """
}

/// Friendly names are presentation only; document IDs still own selection and saving.
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
