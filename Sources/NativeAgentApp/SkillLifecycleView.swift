import Connectors
import Skills
import ProviderRouting
import SwiftUI
import Skills
import AppKit
import PersistenceCore
import PersonaEngine

// MARK: - SkillLifecycleView (redesigned 2026-07-03, User's direction)
//
// Routines are reached through recall; this page reviews their code and lifecycle.
enum SkillLifecycleSearchPresentation {
    struct Results {
        let displayed: [SkillInfo]
        let isFiltering: Bool
        let resultCountText: String?
        let emptyTitle: String
        let emptyDetail: String
    }

    static func results(_ skills: [SkillInfo], query: String) -> Results {
        let isFiltering = !normalized(query).isEmpty
        let displayed = filtered(skills, query: query)
        return Results(
            displayed: displayed,
            isFiltering: isFiltering,
            resultCountText: isFiltering
                ? "\(displayed.count) \(displayed.count == 1 ? "match" : "matches")"
                : nil,
            emptyTitle: isFiltering ? "No matches" : "No skills yet",
            emptyDetail: isFiltering
                ? "Nothing matches \u{201C}\(query)\u{201D}."
                : "Ask me to build a skill — a draft lands here for your review, and once you approve it I can use it."
        )
    }

    static func filtered(_ skills: [SkillInfo], query: String) -> [SkillInfo] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return skills }
        return skills.filter { info in
            searchableFields(for: info).contains { normalized($0).contains(needle) }
        }
    }

    private static func searchableFields(for info: SkillInfo) -> [String] {
        [
            info.id,
            info.registry.name,
            info.registry.state,
            info.manifest.name,
            info.manifest.type,
            info.manifest.description,
        ] + (info.manifest.tags ?? [])
    }

    private static func normalized(_ value: String) -> String {
        let folded = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// The review sheet is an approval surface for a chat-built draft, not a
/// general-purpose state changer. Its displayed outcome is derived only after
/// the authoritative registry refresh confirms the post-write state.
struct SkillReviewInstallReceipt: Equatable {
    let requestedName: String
    let confirmedName: String
    let confirmedState: String
}

enum SkillReviewInstallOutcome: Equatable {
    case installed(SkillReviewInstallReceipt)
    case refused(detail: String)
    case failed(detail: String)
}

enum SkillReviewInstallPresentation {
    static let installAccessibilityIdentifier = "skills.review.install"

    struct InstallControl: Equatable {
        let isEnabled: Bool
        let refusal: String?
    }

    /// The review sheet's install affordance and the writer share this exact
    /// eligibility decision. A visible disabled control must name the same
    /// reason that `installReviewedSkill` will return if invoked directly.
    static func installControl(for info: SkillInfo, isInstalling: Bool) -> InstallControl {
        let refusal = InstalledSkillInventory.reviewInstallRefusal(
            version: info.registry.version, state: info.registry.state, name: info.registry.name,
            hasCandidate: info.candidateDigest != nil && info.readme != nil,
            validationStatus: info.validationStatus)
        return InstallControl(
            isEnabled: !isInstalling && refusal == nil,
            refusal: refusal
        )
    }

    static func needsOAuth(for info: SkillInfo) -> Bool {
        info.manifest.type == "connector" && info.manifest.oauth?.deviceFlow == true
    }

    static func successMessage(for receipt: SkillReviewInstallReceipt) -> String {
        let verb = receipt.confirmedState == "active" ? "is now active" : "is installed"
        // Package metadata and routine publication retain their own verification.
        return "‘\(receipt.confirmedName)’ \(verb)."
    }
}

/// Header actions have separate production owners: Build writes a chat draft,
/// while Refresh reads the skill authorities. Keep the action result typed so
/// neither a missing chat session nor an existing draft is called a build.
enum SkillLifecycleActionPresentation {
    enum Build: Equatable {
        case draftPrepared
        case existingDraftPreserved
        case awaitingChatSession
    }

    static func build(activeSessionID: String, existingDraft: String) -> Build {
        guard !activeSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .awaitingChatSession
        }
        return existingDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .draftPrepared
            : .existingDraftPreserved
    }
}

/// Both visible Skills entry points start the same real chat-draft handoff.
/// Keeping the starter and owner here prevents the empty-state button from
/// drifting from the header button and makes an existing draft's preservation
/// part of the button contract rather than an incidental UI detail.
enum SkillBuildButtonPresentation {
    static let starter = "Build me a skill that "

    @MainActor
    @discardableResult
    static func beginBuild(using appModel: AppModel) -> SkillLifecycleActionPresentation.Build {
        appModel.requestSkillBuild(starter: starter)
    }
}

struct SkillLifecycleView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var reviewTarget: SkillInfo?
    @State private var readerTarget: SkillInfo?
    private let loadsOnAppear: Bool

    init(initialSearchText: String = "", loadsOnAppear: Bool = true) {
        _searchText = State(initialValue: initialSearchText)
        self.loadsOnAppear = loadsOnAppear
    }

    private var searchResults: SkillLifecycleSearchPresentation.Results {
        SkillLifecycleSearchPresentation.results(appModel.skillManifests, query: searchText)
    }

    var body: some View {
        // 2026-09-03 Advanced refinement: the page's own gradient "Skills"
        // title, the rule under the controls and the two banner strips were
        // chrome sitting on the shell's sheet. What is left is one line about
        // what skills are, the controls, and the rows.
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("\(appModel.skillManifests.count) skills · I pull up the right one when a conversation calls for it; the full text loads only when it is needed.")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Build in chat") {
                    _ = SkillBuildButtonPresentation.beginBuild(using: appModel)
                }
                .accessibilityIdentifier("skills.lifecycle.build")

                Button(appModel.isLoadingSkillManifests ? "Refreshing…" : "Refresh") {
                    Task { await appModel.loadSkillManifests() }
                }
                .buttonStyle(.naFeel)
                .disabled(appModel.isLoadingSkillManifests)
                .accessibilityIdentifier("skills.lifecycle.refresh")
            }

            HStack(spacing: 8) {
                TextField("Search skills", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellType.label)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("skills.lifecycle.search")
                if searchResults.isFiltering, let resultCountText = searchResults.resultCountText {
                    Text(resultCountText)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .accessibilityIdentifier("skills.lifecycle.search.resultCount")
                    Button("Clear search") {
                        searchText = ""
                    }
                    .buttonStyle(.plain)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .accessibilityLabel("Clear skill search")
                    .accessibilityIdentifier("skills.lifecycle.search.clear")
                }
                Spacer(minLength: 8)
            }

            if let feedback = appModel.skillLifecycleFeedback, feedback.kind == .failure {
                HStack(spacing: 8) {
                    Text(feedback.message)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Dismiss") { appModel.dismissSkillManifestFeedback() }
                        .buttonStyle(.naFeel)
                }
            }

            if let feedback = appModel.skillLifecycleFeedback, feedback.kind == .success {
                Text(feedback.message)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.calm)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(NativeAgentMotion.fade)
                    .task(id: feedback.id) {
                        try? await Task.sleep(for: .seconds(3))
                        appModel.dismissSkillManifestSuccess(id: feedback.id)
                    }
            }

            if appModel.isLoadingSkillManifests {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: TodayMetrics.cardRadius, style: .continuous)
                                .fill(NativeAgentShell.quietFill)
                                .frame(height: 58)
                        }
                    }
                }
            } else if searchResults.displayed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(searchResults.emptyTitle)
                        .font(ShellType.bodySemibold)
                        .foregroundStyle(NativeAgentShell.text)
                    Text(searchResults.emptyDetail)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !searchResults.isFiltering {
                        Button("Build a skill") {
                            _ = SkillBuildButtonPresentation.beginBuild(using: appModel)
                        }
                        .padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(searchResults.displayed) { info in
                            SkillRow(info: info,
                                     onRead: { readerTarget = info },
                                     onReview: { reviewTarget = info })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            guard loadsOnAppear else { return }
            await appModel.loadSkillManifests()
        }
        .sheet(item: $reviewTarget) { info in
            SkillReviewSheet(info: info, onDismiss: {
                reviewTarget = nil
            }, onInstallSuccess: { message in
                reviewTarget = nil
                appModel.recordSkillManifestSuccess(message)
                Task { await appModel.loadSkillManifests() }
            })
            .environment(appModel)
        }
        .sheet(item: $readerTarget) { info in
            SkillSourceSheet(info: info, onDismiss: { readerTarget = nil })
        }
    }
}

// MARK: - One skill row

private struct SkillRow: View {
    let info: SkillInfo
    let onRead: () -> Void
    let onReview: () -> Void

    private var isDraft: Bool { info.registry.state == "drafted" || info.validationStatus == "valid" }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.manifest.name.isEmpty ? info.id : info.manifest.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(info.manifest.description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(info.registry.state)
                .font(ShellType.captionSemibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    isDraft ? NativeAgentShell.trouble.opacity(0.16) : NativeAgentShell.quietFill,
                    in: Capsule()
                )
                .foregroundStyle(isDraft ? NativeAgentShell.trouble : NativeAgentShell.secondary)
            if isDraft {
                Button("Review") { onReview() }
                    .controlSize(.small)
            }
            Image(systemName: "chevron.right")
                .font(ShellType.captionSemibold)
                .foregroundStyle(NativeAgentShell.secondary)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(minHeight: 48)
        .aliveCard(radius: TodayMetrics.cardRadius)
        .contentShape(Rectangle())
        .naInteractive(radius: TodayMetrics.cardRadius)
        .onTapGesture { onRead() }
    }
}

// MARK: - Source review

struct SkillSourceSheet: View {
    let info: SkillInfo
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(info.manifest.name).font(ShellType.title)
                Spacer()
                Button("Done") { onDismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                if let source = info.readme {
                    BoundedSkillText(text: source, limit: 4_000)
                } else {
                    Text("No JS routine source is available. Read Tools census for its conversion status.")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .houseSheet()
    }
}

// MARK: - Skill review sheet (chat-built drafts awaiting approval)

struct SkillReviewSheet: View {
    @Environment(AppModel.self) private var appModel
    let info: SkillInfo
    let onDismiss: () -> Void
    let onInstallSuccess: (String) -> Void

    @State private var showOAuthFlow = false
    @State private var isInstalling = false
    @State private var installError: String?
    // PATCH-2026-05-11: skill-review-freeze-fix — defer README rendering
    // until after first paint. The README section is the heaviest content
    // (BoundedSkillText with .textSelection(.enabled) over thousands of
    // mono-font characters inside a material-backed NativePanel). Rendering
    // it synchronously during sheet presentation contributed to a multi-
    // second main-thread stall on macOS. We flip this true in `.task` so
    // the chrome paints first and the README streams in a frame later.
    @State private var readmeReady = false
    private let toolPreviewLimit = 40
    // PATCH-2026-05-11: skill-review-freeze-fix — tighter initial README
    // limit (was 24_000). Even 24k characters of mono text with selection
    // enabled inside .ultraThinMaterial is enough to stall presentation;
    // 4k is plenty for the at-a-glance review pane, and users can click
    // "Show full preview" if they want more.
    private let readmePreviewLimit = 4_000

    private var installRefusal: String? {
        installControl.refusal
    }

    private var installControl: SkillReviewInstallPresentation.InstallControl {
        SkillReviewInstallPresentation.installControl(for: info, isInstalling: isInstalling)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                // PATCH-2026-05-11: skill-review-freeze-fix — LazyVStack so
                // sections below the fold don't all force layout up-front.
                // Previously VStack measured every NativePanel (each with an
                // .ultraThinMaterial background) on first present, which on
                // a slow render compounds and looked like a freeze.
                LazyVStack(alignment: .leading, spacing: 24) {
                    // Description section
                    reviewSection(title: "What it does") {
                        Text(info.manifest.description)
                            .font(ShellType.label)
                            .foregroundStyle(NativeAgentShell.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // Type section
                    reviewSection(title: "Type") {
                        Text(info.manifest.type)
                            .font(ShellType.captionSemibold)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(NativeAgentShell.quietFill, in: Capsule())
                            .foregroundStyle(NativeAgentShell.secondary)
                    }

                    // Author
                    if let author = info.manifest.author {
                        reviewSection(title: "Author") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(author.name)
                                    .font(ShellType.label)
                                    .foregroundStyle(NativeAgentShell.text)
                                if let email = author.email {
                                    Text(email)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                }
                            }
                        }
                    }

                    // Permissions
                    if let perms = info.manifest.permissions, !perms.isEmpty {
                        reviewSection(title: "Permissions") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(perms, id: \.self) { perm in
                                    Text(perm)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.text)
                                }
                            }
                        }
                    }

                    // Tools
                    if let tools = info.manifest.tools, !tools.isEmpty {
                        reviewSection(title: "Tools (\(tools.count))") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(tools.prefix(toolPreviewLimit))) { tool in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(ShellType.code)
                                            .fontWeight(.semibold)
                                            .foregroundStyle(NativeAgentShell.text)
                                        Text(tool.description)
                                            .font(ShellType.label)
                                            .foregroundStyle(NativeAgentShell.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                if tools.count > toolPreviewLimit {
                                    Text("\(tools.count - toolPreviewLimit) more tools not shown here.")
                                        .font(ShellType.caption)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                }
                            }
                        }
                    }

                    // OAuth
                    if let oauth = info.manifest.oauth {
                        reviewSection(title: "Sign-in") {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text("Provider")
                                        .font(ShellType.label)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                    Text(oauth.provider)
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.text)
                                }
                                HStack(alignment: .top, spacing: 8) {
                                    Text("Scopes")
                                        .font(ShellType.label)
                                        .foregroundStyle(NativeAgentShell.secondary)
                                    Text(oauth.scopes.joined(separator: ", "))
                                        .font(ShellType.code)
                                        .foregroundStyle(NativeAgentShell.text)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Text("Sign-in opens in your browser.")
                                    .font(ShellType.caption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                            }
                        }
                    }

                    // README — deferred to second frame; see readmeReady above.
                    if let readme = info.readme, !readme.isEmpty {
                        reviewSection(title: "Read me") {
                            if readmeReady {
                                BoundedSkillText(text: readme, limit: readmePreviewLimit)
                            } else {
                                // Cheap placeholder so the section frame is
                                // reserved without triggering text layout.
                                Text("Loading preview…")
                                    .font(ShellType.caption)
                                    .foregroundStyle(NativeAgentShell.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(20)
            }
            // PATCH-2026-05-11: skill-review-freeze-fix — yield once after the
            // sheet's chrome lays out, then drop in the README. This lets the
            // OS finish presenting the sheet before we kick off TextKit work
            // for the README body.
            .task(id: info.id) {
                await Task.yield()
                readmeReady = true
            }
            .navigationTitle("Review: \(info.manifest.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Install") {
                        if let refusal = installRefusal {
                            installError = refusal
                        } else if SkillReviewInstallPresentation.needsOAuth(for: info) {
                            showOAuthFlow = true
                        } else {
                            Task { _ = await installSkill() }
                        }
                    }
                    .disabled(!installControl.isEnabled)
                    .accessibilityIdentifier(SkillReviewInstallPresentation.installAccessibilityIdentifier)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let installRefusal {
                    Text(installRefusal)
                        .font(ShellType.label)
                        .foregroundStyle(NativeAgentShell.trouble)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
            .sheet(isPresented: $showOAuthFlow) {
                if let provider = info.manifest.oauth?.provider {
                    OAuthFlowSheet(
                        provider: provider,
                        skillName: info.manifest.name,
                        onSuccess: { _ in
                            showOAuthFlow = false
                            Task {
                                _ = await installSkill()
                            }
                        },
                        onCancel: {
                            showOAuthFlow = false
                        }
                    )
                }
            }
        }
        .frame(minWidth: 540, minHeight: 480)
        .alert("Skill installation failed", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK", role: .cancel) { installError = nil }
        } message: {
            Text(installError ?? "The app could not confirm that the skill installed.")
        }
    }

    @MainActor
    private func installSkill() async -> Bool {
        guard !isInstalling else { return false }
        isInstalling = true
        defer { isInstalling = false }
        switch await appModel.installReviewedSkill(info) {
        case .installed(let receipt):
            onInstallSuccess(SkillReviewInstallPresentation.successMessage(for: receipt))
            return true
        case .refused(let detail), .failed(let detail):
            installError = detail
            return false
        }
    }

    /// The review sheet's sections wore `NativePanel`'s thin-material slab, an
    /// icon and a tinted border each. They are the Advanced list's shape now:
    /// an eyebrow, then the words on one card.
    private func reviewSection<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(ShellType.labelSemibold)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(NativeAgentShell.secondary)
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 12) { content() }
                .padding(16)
                .settingsCardSurface()
        }
    }
}

private struct BoundedSkillText: View {
    let text: String
    let limit: Int
    @State private var expanded = false

    private var isTruncated: Bool { text.count > limit }
    private var visibleText: String {
        if expanded || !isTruncated { return text }
        return String(text.prefix(limit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // PATCH-2026-05-11: skill-review-freeze-fix — `.textSelection(.enabled)`
            // on a multi-thousand-character mono `Text` inside a material-
            // backed sheet panel installs TextKit selection state per glyph
            // at first paint. We now only enable selection once the user
            // explicitly expanded the preview; the truncated default path
            // renders without selection so presentation stays snappy.
            Group {
                if expanded {
                    Text(visibleText)
                        .textSelection(.enabled)
                } else {
                    Text(visibleText)
                        .textSelection(.disabled)
                }
            }
            .font(ShellType.code)
            .foregroundStyle(NativeAgentShell.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isTruncated {
                Button(expanded ? "Collapse preview" : "Show full preview") {
                    expanded.toggle()
                }
                .buttonStyle(.naFeel)
                Text("\(text.count - visibleText.count) more characters not shown, to keep this page quick.")
                    .font(ShellType.caption)
                    .foregroundStyle(NativeAgentShell.secondary)
            }
        }
    }
}

// MARK: - OAuth flow sheet

struct OAuthFlowSheet: View {
    @Environment(AppModel.self) private var appModel
    let provider: String
    let skillName: String
    let onSuccess: (String) -> Void
    let onCancel: () -> Void

    @State private var isLoading = true
    @State private var error: String?
    // Tracks the start/retry flow task so a dismissed sheet can cancel it before
    // it updates a torn-down view.
    @State private var flowTask: Task<Void, Never>?
    @State private var showSuccess = false
    @State private var successLogin = ""
    @State private var wasCancelled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var oauthDataRoot: URL {
        appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if showSuccess {
                    successView
                } else if isLoading {
                    ProgressView("Starting sign-in for \(provider)…")
                        .font(ShellType.label)
                        .padding(16)
                } else if let err = error {
                    errorView(err)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Connect \(provider.capitalized)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cancelFlow()
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 360)
        .task {
            flowTask = Task { @MainActor in await startFlow() }
        }
        .onDisappear {
            wasCancelled = true
            flowTask?.cancel()
        }
    }

    @ViewBuilder
    private var successView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(successLogin.isEmpty ? "Connected" : "Connected as \(successLogin)")
                .font(ShellType.title)
                .foregroundStyle(NativeAgentShell.calm)
            Text("Authorization is complete. Finishing the \(skillName) installation…")
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authorization failed")
                .font(ShellType.title)
                .foregroundStyle(NativeAgentShell.trouble)
            Text(err)
                .font(ShellType.label)
                .foregroundStyle(NativeAgentShell.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") {
                wasCancelled = false
                isLoading = true
                error = nil
                flowTask?.cancel()
                flowTask = Task { await startFlow() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func startFlow() async {
        isLoading = true
        error = nil
        guard let connectorId = ConnectorWizardSetupRoute.skillOAuthConnectorID(for: provider) else {
            self.error = "Sign-in is not set up for \(provider)."
            isLoading = false
            return
        }
        let result = await NativeOAuthFlow.startConnectorOAuthFlow(
            platform: NativeOAuthPlatform.self,
            connectorId: connectorId,
            dataRoot: oauthDataRoot
        )
        guard !Task.isCancelled, !wasCancelled else { isLoading = false; return }
        isLoading = false
        if result.ok {
            successLogin = ""
            // Motion pass: the bare default animation is now gated on the
            // reader's Reduce Motion setting, like every other move in the
            // shell.
            withAnimation(NativeAgentMotion.respecting(NativeAgentMotion.spring, reduceMotion: reduceMotion)) {
                showSuccess = true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, !wasCancelled else { return }
            onSuccess(successLogin)
        } else {
            self.error = result.error ?? "Sign-in failed."
        }
    }

    private func cancelFlow() {
        wasCancelled = true
        flowTask?.cancel()
        isLoading = false
        onCancel()
    }
}


extension Notification.Name {
    static let skillBuildRequest = Notification.Name("NativeAgent.skillBuildRequest")
}
/// The latest user-visible outcome of a skill lifecycle operation. Identity is
/// part of the contract: a repeated failure is a new event even when its text
/// is byte-for-byte identical to the prior one.
struct SkillLifecycleFeedback: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case success
        case failure
    }

    let id: UUID
    let kind: Kind
    let message: String

    init(kind: Kind, message: String) {
        self.id = UUID()
        self.kind = kind
        self.message = message
    }
}

extension AppModel {
    @MainActor
    func recordSkillManifestFailure(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        skillManifestError = trimmed
        skillLifecycleFeedback = SkillLifecycleFeedback(kind: .failure, message: trimmed)
    }

    @MainActor
    func recordSkillManifestSuccess(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        skillManifestError = nil
        skillLifecycleFeedback = SkillLifecycleFeedback(kind: .success, message: trimmed)
    }

    @MainActor
    func dismissSkillManifestFeedback() {
        skillManifestError = nil
        skillLifecycleFeedback = nil
    }

    @MainActor
    func dismissSkillManifestSuccess(id: UUID) {
        guard skillLifecycleFeedback?.id == id,
              skillLifecycleFeedback?.kind == .success else { return }
        skillLifecycleFeedback = nil
    }
}
