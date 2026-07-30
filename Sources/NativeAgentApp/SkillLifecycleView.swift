import SwiftUI
import AppKit
import PersistenceCore
import PersonaEngine

// MARK: - SkillLifecycleView (redesigned 2026-07-03, User's direction)
//
// The old tab wrapped a drafted→installed→active→dormant lifecycle wall
// around what reality actually holds: markdown playbooks in
// persona/skills/bodies (+ data/skills/bodies) and an EMPTY registry.
// Since the skills-recall rework, skills surface themselves — each body has
// a pointer row in the memory store that per-turn recall surfaces
// in-territory, and the agent pulls the full body with read_skill. This tab
// now shows exactly that: the playbooks, the pointer-sync receipt, and a
// reader. The Review sheet survives for the one live lifecycle moment (a
// chat-built DRAFT awaiting approval); the filter chips, settings sheet,
// and per-card lifecycle furniture are gone.

struct SkillLifecycleView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var reviewTarget: SkillInfo?
    @State private var readerTarget: SkillInfo?
    @State private var toastMessage: String?
    @State private var syncReceiptLine: String?

    private var filtered: [SkillInfo] {
        let base = appModel.skillManifests
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return base }
        return base.filter {
            $0.id.lowercased().contains(q)
                || $0.manifest.description.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    GradientText(text: "Skills", colors: [NativeAgentBrand.accentDeep, NativeAgentBrand.accent, NativeAgentBrand.accentCool], font: NativeAgentFont.title)
                    Text("\(appModel.skillManifests.count) playbooks · recall surfaces the right one when a conversation enters its territory; the full text loads only on demand.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appModel.requestSkillBuild(starter: "Build me a skill that")
                } label: {
                    Label("Build a Skill", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    Task {
                        await appModel.loadSkillManifests()
                        loadSyncReceipt()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.top, NativeAgentSpacing.lg)
            .padding(.bottom, NativeAgentSpacing.sm)

            HStack(spacing: NativeAgentSpacing.sm) {
                TextField("Search skills", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                if let syncReceiptLine {
                    Label(syncReceiptLine, systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Every skill gets a one-line pointer in memory so recall can surface it. Synced at launch and after skill changes.")
                }
                Spacer()
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.bottom, NativeAgentSpacing.md)

            Divider()

            if let err = appModel.skillManifestError {
                HStack(spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(NativeAgentTheme.warn)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { appModel.skillManifestError = nil }
                        .buttonStyle(.borderless)
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.vertical, NativeAgentSpacing.sm)
                .background(NativeAgentTheme.warn.opacity(0.08))
            }

            if let msg = toastMessage {
                HStack(spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NativeAgentTheme.ok)
                    Text(msg).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.vertical, NativeAgentSpacing.sm)
                .background(NativeAgentTheme.ok.opacity(0.08))
                .transition(.opacity)
            }

            if appModel.isLoadingSkillManifests {
                ScrollView {
                    VStack(spacing: NativeAgentSpacing.sm) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                                .frame(height: 58)
                                .appShimmer()
                        }
                    }
                    .padding(NativeAgentSpacing.xl)
                }
            } else if filtered.isEmpty {
                NativeEmptyState(
                    title: searchText.isEmpty ? "No skills yet" : "No matches",
                    detail: searchText.isEmpty
                        ? "Ask the agent to build a skill — a draft lands here for your review, and once approved it becomes a playbook recall can surface."
                        : "Nothing matches \u{201C}\(searchText)\u{201D}.",
                    systemImage: searchText.isEmpty ? "puzzlepiece.extension" : "magnifyingglass",
                    actionTitle: searchText.isEmpty ? "Build a Skill" : nil,
                    actionImage: searchText.isEmpty ? "wand.and.stars" : nil,
                    action: searchText.isEmpty ? {
                        appModel.requestSkillBuild(starter: "Build me a skill that")
                    } : nil
                )
            } else {
                ScrollView {
                    VStack(spacing: NativeAgentSpacing.sm) {
                        ForEach(filtered) { info in
                            SkillRow(info: info,
                                     onRead: { readerTarget = info },
                                     onReview: { reviewTarget = info })
                        }
                    }
                    .padding(NativeAgentSpacing.xl)
                }
            }
        }
        .task {
            await appModel.loadSkillManifests()
            loadSyncReceipt()
        }
        .sheet(item: $reviewTarget) { info in
            SkillReviewSheet(info: info, onDismiss: {
                reviewTarget = nil
            }, onInstallSuccess: { name in
                reviewTarget = nil
                showToast("\u{2018}\(name)\u{2019} is now active.")
                Task { await appModel.loadSkillManifests() }
            })
            .environment(appModel)
        }
        .sheet(item: $readerTarget) { info in
            SkillBodySheet(info: info) { readerTarget = nil }
        }
    }

    /// Read the pointer-sync receipt the launch/mutation syncs write. Absent
    /// file → no line (fresh install before first sync).
    private func loadSyncReceipt() {
        let receipt = PersistenceCore.defaultDataRoot()
            .appendingPathComponent("skills/.pointer_sync_receipt.json")
        guard let data = try? Data(contentsOf: receipt),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else {
            syncReceiptLine = nil
            return
        }
        if obj["status"] == "ok" {
            let total = appModel.skillManifests.count
            syncReceiptLine = "\(total) recall pointers in memory · synced \(Self.friendlyTime(obj["at"]))"
        } else {
            syncReceiptLine = "pointer sync FAILED — \(obj["error"] ?? "unknown")"
        }
    }

    private static func friendlyTime(_ iso: String?) -> String {
        guard let iso else { return "recently" }
        // Route through the shared parser (fractional seconds tolerated). The
        // old bare ISO8601DateFormatter() lacked .withFractionalSeconds, so
        // every daemon timestamp failed to parse and rendered "recently".
        return UserDisplayFormatters.relativeISOTimestamp(iso, unitsStyle: .short, fallback: "recently")
    }

    private func showToast(_ msg: String) {
        withAnimation { toastMessage = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation { toastMessage = nil }
        }
    }
}

// MARK: - One skill row

private struct SkillRow: View {
    let info: SkillInfo
    let onRead: () -> Void
    let onReview: () -> Void

    private var isDraft: Bool { info.registry.state == "drafted" }
    private var sourceLabel: String {
        if isDraft { return "draft" }
        if info.registry.path.contains("/persona/") { return "persona" }
        return "runtime"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(info.id)
                    .font(.body.weight(.medium))
                Text(info.manifest.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text(sourceLabel)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(
                    (isDraft ? Color.orange : Color.primary).opacity(isDraft ? 0.16 : 0.08),
                    in: Capsule()
                )
                .foregroundStyle(isDraft ? Color.orange : Color.secondary)
            if isDraft {
                Button("Review", systemImage: "checkmark.seal") { onReview() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10).padding(.horizontal, 12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { onRead() }
    }
}

// MARK: - Read-only body sheet

private struct SkillBodySheet: View {
    let info: SkillInfo
    let onDismiss: () -> Void
    @State private var body_: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            HStack {
                Text(info.id).font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            if body_.isEmpty {
                Text("Couldn\u{2019}t read the skill body at \(info.registry.path)")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else {
                ScrollView {
                    Text(body_)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text(info.registry.path)
                .font(NativeAgentFont.mono)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .task {
            // Bounded read (gpt-5.5 review MED): a malformed registry/body
            // row must not turn this sheet into an arbitrary-file viewer.
            // Only the two skills roots are readable here.
            let raw = URL(fileURLWithPath: info.registry.path).standardizedFileURL
            let allowedRoots = [
                PersistenceCore.defaultDataRoot()
                    .appendingPathComponent("skills/bodies", isDirectory: true),
                PersonaRootResolver.resolve()
                    .appendingPathComponent("skills/bodies", isDirectory: true),
            ].map { $0.standardizedFileURL.path.hasSuffix("/") ? $0.standardizedFileURL.path : $0.standardizedFileURL.path + "/" }
            guard allowedRoots.contains(where: { raw.path.hasPrefix($0) }) else {
                body_ = ""
                return
            }
            body_ = (try? String(contentsOf: raw, encoding: .utf8)) ?? ""
        }
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

    var body: some View {
        NavigationStack {
            ScrollView {
                // PATCH-2026-05-11: skill-review-freeze-fix — LazyVStack so
                // sections below the fold don't all force layout up-front.
                // Previously VStack measured every NativePanel (each with an
                // .ultraThinMaterial background) on first present, which on
                // a slow render compounds and looked like a freeze.
                LazyVStack(alignment: .leading, spacing: NativeAgentSpacing.xl) {
                    // Description section
                    reviewSection(title: "Description", systemImage: "text.alignleft") {
                        Text(info.manifest.description)
                            .font(NativeAgentFont.body)
                    }

                    // Type section
                    reviewSection(title: "Type", systemImage: "puzzlepiece") {
                        Text(info.manifest.type)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                    }

                    // Author
                    if let author = info.manifest.author {
                        reviewSection(title: "Author", systemImage: "person.circle") {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(author.name).font(NativeAgentFont.body)
                                if let email = author.email {
                                    Text(email).font(NativeAgentFont.mono).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // Permissions
                    if let perms = info.manifest.permissions, !perms.isEmpty {
                        reviewSection(title: "Permissions", systemImage: "lock.shield") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(perms, id: \.self) { perm in
                                    Label(perm, systemImage: "checkmark.shield")
                                        .font(NativeAgentFont.mono)
                                }
                            }
                        }
                    }

                    // Tools
                    if let tools = info.manifest.tools, !tools.isEmpty {
                        reviewSection(title: "Tools (\(tools.count))", systemImage: "hammer") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(tools.prefix(toolPreviewLimit))) { tool in
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tool.name)
                                            .font(NativeAgentFont.mono)
                                            .fontWeight(.semibold)
                                        Text(tool.description)
                                            .font(.callout)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if tools.count > toolPreviewLimit {
                                    Text("\(tools.count - toolPreviewLimit) more tool definitions hidden in the review preview.")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    // OAuth
                    if let oauth = info.manifest.oauth {
                        reviewSection(title: "OAuth", systemImage: "key.fill") {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Provider:")
                                        .foregroundStyle(.secondary)
                                    Text(oauth.provider)
                                        .font(NativeAgentFont.mono)
                                }
                                HStack(alignment: .top) {
                                    Text("Scopes:")
                                        .foregroundStyle(.secondary)
                                    Text(oauth.scopes.joined(separator: ", "))
                                        .font(NativeAgentFont.mono)
                                }
                                if oauth.deviceFlow == true {
                                    Label("Uses device flow — no browser login required", systemImage: "iphone.and.arrow.forward")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    // README — deferred to second frame; see readmeReady above.
                    if let readme = info.readme, !readme.isEmpty {
                        reviewSection(title: "README", systemImage: "doc.text") {
                            if readmeReady {
                                BoundedSkillText(text: readme, limit: readmePreviewLimit)
                            } else {
                                // Cheap placeholder so the section frame is
                                // reserved without triggering text layout.
                                Text("Loading preview…")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(NativeAgentSpacing.xl)
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
                        let needsOAuth = info.manifest.type == "connector" && info.manifest.oauth?.deviceFlow == true
                        if needsOAuth {
                            showOAuthFlow = true
                        } else {
                            Task { await installSkill() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isInstalling)
                }
            }
            .sheet(isPresented: $showOAuthFlow) {
                if let provider = info.manifest.oauth?.provider {
                    OAuthFlowSheet(
                        provider: provider,
                        skillName: info.manifest.name,
                        onSuccess: { _ in
                            showOAuthFlow = false
                            Task { await installSkill() }
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
            Text(installError ?? "The installed registry state could not be verified.")
        }
    }

    @MainActor
    private func installSkill() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        guard await appModel.enableSkillManifest(name: info.id) else {
            installError = appModel.skillManifestError ?? "The installed registry state could not be verified."
            return
        }
        onInstallSuccess(info.id)
    }

    private func reviewSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        NativePanel(title: title, systemImage: systemImage) {
            content()
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
            .font(NativeAgentFont.mono)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isTruncated {
                Button(expanded ? "Collapse preview" : "Show full preview") {
                    expanded.toggle()
                }
                .buttonStyle(.borderless)
                Text("\(text.count - visibleText.count) characters hidden to keep the review sheet responsive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - OAuth flow sheet

struct OAuthFlowSheet: View {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: NativeAgentSpacing.xl) {
                if showSuccess {
                    successView
                } else if isLoading {
                    ProgressView("Starting OAuth for \(provider)...")
                        .padding()
                } else if let err = error {
                    errorView(err)
                }
            }
            .padding(NativeAgentSpacing.xl)
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
        .task { await startFlow() }
        .onDisappear { flowTask?.cancel() }
    }

    @ViewBuilder
    private var successView: some View {
        VStack(spacing: NativeAgentSpacing.lg) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(NativeAgentTheme.ok)
            Text("Connected" + (successLogin.isEmpty ? "!" : " as \(successLogin)!"))
                .font(NativeAgentFont.title)
            Text("Authorization complete. Finishing the \(skillName) installation…")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorView(_ err: String) -> some View {
        VStack(spacing: NativeAgentSpacing.lg) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(NativeAgentTheme.fail)
            Text("Authorization failed")
                .font(NativeAgentFont.title)
            Text(err)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                isLoading = true
                error = nil
                flowTask?.cancel()
                flowTask = Task { await startFlow() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @MainActor
    private func startFlow() async {
        isLoading = true
        error = nil
        guard let connectorId = nativeOAuthConnectorId(for: provider) else {
            self.error = "Native OAuth is not configured for \(provider)."
            isLoading = false
            return
        }
        let result = await NativeOAuthFlow.startConnectorOAuthFlow(connectorId: connectorId)
        guard !Task.isCancelled else { isLoading = false; return }
        isLoading = false
        if result.ok {
            successLogin = ""
            withAnimation {
                showSuccess = true
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            onSuccess(successLogin)
        } else {
            self.error = result.error ?? "Sign-in failed."
        }
    }

    private func nativeOAuthConnectorId(for provider: String) -> String? {
        switch provider.lowercased() {
        case "x", "twitter": return "x"
        case "gmail", "email": return "gmail"
        case "calendar", "google_calendar": return "calendar"
        default: return nil
        }
    }

    private func cancelFlow() {
        flowTask?.cancel()
        onCancel()
    }
}


extension Notification.Name {
    static let skillBuildRequest = Notification.Name("NativeAgent.skillBuildRequest")
}
