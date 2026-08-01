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

struct PersonalityView: View {
    @Environment(AppModel.self) private var appModel
    @State private var draft = PersonalityProfile.defaultProfile
    @State private var isLoadingProfile = true
    @State private var selectedDocId = "SOUL"
    @State private var personalityDocDraft = ""

    // Starter card state (shown only while no persona exists).
    @State private var starterAgentName = ""
    @State private var starterUserName = ""
    @State private var starterNotes = ""
    @State private var starterBusy = false
    @State private var starterError: String?
    @State private var docsLoadError: String?

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

    var body: some View {
        Group {
            if isLoadingProfile {
                NativeEmptyState(
                    title: "Loading Personality",
                    detail: "Reading the saved profile before showing controls.",
                    systemImage: "person.wave.2",
                    actionTitle: nil,
                    actionImage: nil,
                    action: nil
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if personaInitialized {
                            identityPanel
                            docsPanel
                            ResetPersonaView {
                                await loadProfile(forceRefresh: true)
                            }
                        } else if let docsLoadError {
                            // A failed docs load leaves personalityDocs empty,
                            // which must NOT masquerade as "no persona yet" —
                            // a live persona would see a false Create card
                            // (gpt-5.5 review LOW, 2026-07-03). Fail loud.
                            NativePanel(title: "Persona Unavailable", systemImage: "exclamationmark.triangle") {
                                Text("The persona documents couldn't be read: \(docsLoadError)")
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                Button("Retry", systemImage: "arrow.clockwise") {
                                    Task { await loadProfile(forceRefresh: true) }
                                }
                            }
                        } else {
                            starterPanel
                        }
                    }
                    .frame(maxWidth: 920, alignment: .leading)
                    .padding()
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
        NativePanel(title: "Create Your Agent", systemImage: "sparkles") {
            Text("Give them a name. Add a few things about who they should be if you want — everything can grow and change later.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Name", text: $starterAgentName)
                .textFieldStyle(.roundedBorder)

            TextField("Your name (optional)", text: $starterUserName)
                .textFieldStyle(.roundedBorder)

            AdvancedTextEditor(
                title: "A few things about them (optional)",
                text: $starterNotes,
                minHeight: 92
            )

            HStack(spacing: 10) {
                Button {
                    Task { await createStarterPersona() }
                } label: {
                    if starterBusy {
                        Label("Creating\u{2026}", systemImage: "hourglass")
                    } else {
                        Label("Create", systemImage: "checkmark.circle")
                    }
                }
                .disabled(starterBusy || starterAgentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let starterError {
                    Text(starterError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    @MainActor
    private func createStarterPersona() async {
        starterBusy = true
        starterError = nil
        defer { starterBusy = false }
        let name = starterAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let resp = try await appModel.completeOnboarding(
                agentName: name,
                personaType: "ai",
                userName: starterUserName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            guard resp.ok else {
                starterError = resp.detail ?? resp.error ?? "Could not create the persona."
                return
            }
            await appModel.loadPersonalityDocs()
            // Fold the starter notes into SOUL.md so they land in the real
            // persona, not a side file nothing reads.
            let notes = starterNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !notes.isEmpty,
               let soul = appModel.personalityDocs.first(where: { $0.id.uppercased() == "SOUL" }) {
                await appModel.savePersonalityDoc(
                    id: soul.id,
                    content: soul.content + "\n\n## From setup\n" + notes + "\n"
                )
            }
            await loadProfile(forceRefresh: true)
        } catch {
            starterError = error.localizedDescription
        }
    }

    // MARK: identity — the one live profile field

    private var identityPanel: some View {
        NativePanel(title: "Identity", systemImage: "person.wave.2") {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.roundedBorder)
            Text("The name shown across the app and in chat.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Save Name", systemImage: "checkmark.circle") {
                    Task { await appModel.savePersonality(draft) }
                }
                // savePersonality persists the WHOLE draft. If the profile
                // never loaded, draft is .defaultProfile and saving would
                // overwrite the real profile.json with defaults (gpt-5.5
                // review MED, 2026-07-03) — so no real profile, no save.
                .disabled(appModel.personality == nil)
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await loadProfile(forceRefresh: true) }
                }
                Spacer()
                if let updatedAt = draft.updatedAt {
                    Text("Updated: \(updatedAt)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: documents — the persona itself

    private var docsPanel: some View {
        NativePanel(title: "Persona Documents", systemImage: "doc.text") {
            Text("These documents ARE the personality. Every chat turn compiles them into the system prompt in this order: SOUL \u{2192} VOICE \u{2192} USER \u{2192} GROWTH \u{2192} MEMORY \u{2192} AGENTS.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Document", selection: $selectedDocId) {
                ForEach(appModel.personalityDocs) { doc in
                    Text(doc.filename).tag(doc.id)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedDocId) {
                syncPersonalityDocDraft()
            }

            AdvancedTextEditor(
                title: selectedPersonalityDoc?.filename ?? "SOUL.md",
                text: $personalityDocDraft,
                minHeight: 320,
                isReadOnly: selectedPersonalityDocIsMemoryOwnedUser
            )
            .help(selectedPersonalityDocIsMemoryOwnedUser ? PersonalityDocHelpCopy.memoryOwnedDocument : "")

            HStack {
                Button("Save Document", systemImage: "checkmark.circle") {
                    let docId = selectedDocId
                    let content = personalityDocDraft
                    Task {
                        await appModel.savePersonalityDoc(id: docId, content: content)
                        syncPersonalityDocDraft()
                    }
                }
                .disabled(selectedDocId.isEmpty || selectedPersonalityDocIsMemoryOwnedUser)

                Button("Reload Documents", systemImage: "arrow.clockwise") {
                    Task {
                        await appModel.loadPersonalityDocs()
                        syncPersonalityDocDraft()
                    }
                }

                if let path = selectedPersonalityDoc?.path {
                    Text(path)
                        .font(NativeAgentFont.mono)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
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
        if appModel.personalityDocs.isEmpty || forceRefresh {
            // Load directly so a failure is distinguishable from a genuinely
            // empty fresh install (AppModel.loadPersonalityDocs swallows the
            // error into statusText, leaving docs empty either way).
            docsLoadError = nil
            do {
                appModel.personalityDocs = try await appModel.client.getPersonalityDocs().docs
            } catch {
                docsLoadError = error.localizedDescription
            }
        }
        draft = appModel.personality ?? .defaultProfile
        syncPersonalityDocDraft()
        isLoadingProfile = false
    }

    private var selectedPersonalityDoc: PersonalityDoc? {
        appModel.personalityDocs.first { $0.id == selectedDocId } ?? appModel.personalityDocs.first
    }

    private var selectedPersonalityDocIsMemoryOwnedUser: Bool {
        selectedPersonalityDoc?.id.uppercased() == "USER"
    }

    private func syncPersonalityDocDraft() {
        if !appModel.personalityDocs.contains(where: { $0.id == selectedDocId }) {
            selectedDocId = appModel.personalityDocs.first?.id ?? "SOUL"
        }
        personalityDocDraft = selectedPersonalityDoc?.content ?? ""
    }
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
