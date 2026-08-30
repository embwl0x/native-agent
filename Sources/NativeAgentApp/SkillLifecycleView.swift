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
                : "Ask the agent to build a skill — a draft lands here for your review, and once approved it becomes a playbook recall can surface."
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

    static func preflight(for info: SkillInfo) -> String? {
        let state = info.registry.state.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard state == "drafted" else {
            let shownState = state.isEmpty ? "missing" : state
            return "Only a drafted skill can be installed from this review sheet. This skill is currently \(shownState)."
        }
        let name = info.registry.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "This draft has no registry identity, so NativeAgent cannot install it safely."
        }
        return nil
    }

    /// The review sheet's install affordance and the writer share this exact
    /// eligibility decision. A visible disabled control must name the same
    /// reason that `installReviewedSkill` will return if invoked directly.
    static func installControl(for info: SkillInfo, isInstalling: Bool) -> InstallControl {
        let refusal = preflight(for: info)
        return InstallControl(
            isEnabled: !isInstalling && refusal == nil,
            refusal: refusal
        )
    }

    static func needsOAuth(for info: SkillInfo) -> Bool {
        info.manifest.type == "connector" && info.manifest.oauth?.deviceFlow == true
    }

    static func connectorID(for provider: String) -> String? {
        switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "x", "twitter": return "x"
        case "gmail", "email": return "gmail"
        case "calendar", "google_calendar": return "calendar"
        default: return nil
        }
    }

    /// OAuth is an admission step, not a partial registry mutation. A cancel
    /// or failed callback cannot reach the draft-install action.
    static func installAfterAuthorizedOAuth(
        oauthSucceeded: Bool,
        wasCancelled: Bool,
        install: @MainActor () async -> Bool
    ) async -> Bool {
        guard oauthSucceeded, !wasCancelled else { return false }
        return await install()
    }

    static func successMessage(for receipt: SkillReviewInstallReceipt) -> String {
        let verb = receipt.confirmedState == "active" ? "is now active" : "is installed"
        // This receipt proves the registry state, not that a manifest-only
        // package has a canonical body or a discoverable memory pointer.
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

/// The pointer-sync receipt is the only confirmation that skill bodies were
/// reconciled into recallable memory pointers. Do not infer that outcome from
/// the currently loaded manifest list: it can be stale, filtered, or reflect
/// a different source shelf.
enum SkillPointerSyncReceiptPresentation {
    struct Receipt: Equatable, Sendable {
        let at: String
        let added: Int
        let updated: Int
        let removed: Int
        let unchanged: Int

        var reconciledPointerCount: Int { added + updated + unchanged }
    }

    enum State: Equatable, Sendable {
        case loading
        case current(Receipt)
        case failed(detail: String)
        case unavailable(detail: String)
    }

    /// The sync writer and the Skills surface share this exact data-root
    /// boundary.  A receipt from another app body must never make the current
    /// root claim that its skill pointers are reconciled.
    static func receiptURL(dataRoot: URL) -> URL {
        dataRoot
            .standardizedFileURL
            .appendingPathComponent("skills/.pointer_sync_receipt.json")
    }

    static func read(dataRoot: URL) -> State {
        read(at: receiptURL(dataRoot: dataRoot))
    }

    static func read(at url: URL) -> State {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return .unavailable(detail: "No pointer-sync receipt has been recorded yet.")
        }
        do {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = object["status"] as? String else {
                return .unavailable(detail: "The pointer-sync receipt is malformed.")
            }
            switch status.lowercased() {
            case "ok":
                guard let at = nonEmptyString(object["at"]),
                      let added = nonNegativeInt(object["added"]),
                      let updated = nonNegativeInt(object["updated"]),
                      let removed = nonNegativeInt(object["removed"]),
                      let unchanged = nonNegativeInt(object["unchanged"])
                else {
                    return .unavailable(detail: "The successful pointer-sync receipt is incomplete.")
                }
                return .current(Receipt(
                    at: at,
                    added: added,
                    updated: updated,
                    removed: removed,
                    unchanged: unchanged
                ))
            case "failed":
                return .failed(detail: boundedDetail(nonEmptyString(object["error"]) ?? "unknown"))
            default:
                return .unavailable(detail: "The pointer-sync receipt has an unknown status.")
            }
        } catch {
            return .unavailable(detail: "The pointer-sync receipt could not be read: \(boundedDetail(error.localizedDescription))")
        }
    }

    static func line(for state: State) -> String {
        switch state {
        case .loading:
            return "Checking recall-pointer sync receipt…"
        case .current(let receipt):
            return "\(receipt.reconciledPointerCount) recall pointers confirmed · synced \(friendlyTime(receipt.at))"
        case .failed(let detail):
            return "Pointer sync failed · \(boundedDetail(detail))"
        case .unavailable(let detail):
            return "Pointer sync receipt unavailable · \(boundedDetail(detail))"
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonNegativeInt(_ value: Any?) -> Int? {
        // The writer's durable schema stores every receipt field as a string.
        // Reject coerced JSON values and implausible counts rather than making
        // a malformed receipt look like an enormous completed reconciliation.
        guard let text = value as? String,
              let integer = Int(text),
              (0...100_000).contains(integer) else { return nil }
        return integer
    }

    private static func boundedDetail(_ detail: String, limit: Int = 240) -> String {
        let normalized = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "…"
    }

    private static func friendlyTime(_ iso: String) -> String {
        UserDisplayFormatters.relativeISOTimestamp(iso, unitsStyle: .short, fallback: "at an unknown time")
    }
}

struct SkillPointerSyncReceiptLine: View {
    let state: SkillPointerSyncReceiptPresentation.State

    var body: some View {
        Label(SkillPointerSyncReceiptPresentation.line(for: state), systemImage: icon)
            .font(.caption)
            .foregroundStyle(color)
            .help("Every skill gets a one-line pointer in memory so recall can surface it. Synced at launch and after skill changes.")
    }

    private var icon: String {
        switch state {
        case .current: return "checkmark.circle"
        case .failed, .unavailable: return "exclamationmark.triangle"
        case .loading: return "hourglass"
        }
    }

    private var color: Color {
        switch state {
        case .current: return .secondary
        case .failed: return .red
        case .unavailable: return .orange
        case .loading: return .secondary
        }
    }
}

struct SkillLifecycleView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var reviewTarget: SkillInfo?
    @State private var readerTarget: SkillInfo?
    @State private var syncReceiptState: SkillPointerSyncReceiptPresentation.State = .loading
    private let loadsOnAppear: Bool

    init(initialSearchText: String = "", loadsOnAppear: Bool = true) {
        _searchText = State(initialValue: initialSearchText)
        self.loadsOnAppear = loadsOnAppear
    }

    private var searchResults: SkillLifecycleSearchPresentation.Results {
        SkillLifecycleSearchPresentation.results(appModel.skillManifests, query: searchText)
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
                    _ = SkillBuildButtonPresentation.beginBuild(using: appModel)
                } label: {
                    Label("Build in Chat", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("skills.lifecycle.build")

                Button {
                    Task {
                        await appModel.loadSkillManifests()
                        await loadSyncReceipt()
                    }
                } label: {
                    Label(appModel.isLoadingSkillManifests ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.naFeel)
                .disabled(appModel.isLoadingSkillManifests)
                .accessibilityIdentifier("skills.lifecycle.refresh")
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.top, NativeAgentSpacing.lg)
            .padding(.bottom, NativeAgentSpacing.sm)

            HStack(spacing: NativeAgentSpacing.sm) {
                TextField("Search skills", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .accessibilityIdentifier("skills.lifecycle.search")
                if searchResults.isFiltering, let resultCountText = searchResults.resultCountText {
                    Text(resultCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("skills.lifecycle.search.resultCount")
                    Button("Clear search", systemImage: "xmark.circle.fill") {
                        searchText = ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear skill search")
                    .accessibilityIdentifier("skills.lifecycle.search.clear")
                }
                SkillPointerSyncReceiptLine(state: syncReceiptState)
                Spacer()
            }
            .padding(.horizontal, NativeAgentSpacing.xl)
            .padding(.bottom, NativeAgentSpacing.md)

            Divider()

            if let feedback = appModel.skillLifecycleFeedback, feedback.kind == .failure {
                HStack(spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(NativeAgentTheme.warn)
                    Text(feedback.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { appModel.dismissSkillManifestFeedback() }
                        .buttonStyle(.naFeel)
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.vertical, NativeAgentSpacing.sm)
                .background(NativeAgentTheme.warn.opacity(0.08))
            }

            if let feedback = appModel.skillLifecycleFeedback, feedback.kind == .success {
                HStack(spacing: NativeAgentSpacing.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(NativeAgentTheme.ok)
                    Text(feedback.message).font(.callout)
                    Spacer()
                }
                .padding(.horizontal, NativeAgentSpacing.xl)
                .padding(.vertical, NativeAgentSpacing.sm)
                .background(NativeAgentTheme.ok.opacity(0.08))
                .transition(.opacity)
                .task(id: feedback.id) {
                    try? await Task.sleep(for: .seconds(3))
                    appModel.dismissSkillManifestSuccess(id: feedback.id)
                }
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
            } else if searchResults.displayed.isEmpty {
                NativeEmptyState(
                    title: searchResults.emptyTitle,
                    detail: searchResults.emptyDetail,
                    systemImage: searchResults.isFiltering ? "magnifyingglass" : "puzzlepiece.extension",
                    actionTitle: searchResults.isFiltering ? nil : "Build a Skill",
                    actionImage: searchResults.isFiltering ? nil : "wand.and.stars",
                    action: searchResults.isFiltering ? nil : {
                        _ = SkillBuildButtonPresentation.beginBuild(using: appModel)
                    }
                )
            } else {
                ScrollView {
                    VStack(spacing: NativeAgentSpacing.sm) {
                        ForEach(searchResults.displayed) { info in
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
            guard loadsOnAppear else { return }
            await appModel.loadSkillManifests()
            await loadSyncReceipt()
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
            let dataRoot = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
            let personaRoot = appModel.dataRootOverride.map { override in
                // A preview opened from an injected data root is a sandboxed
                // read: never let an environment or stamped-repository
                // persona redirect it outside that root.
                return PersonaRootResolver.resolveIsolated(dataRoot: override)
            } ?? PersonaRootResolver.resolve()
            SkillBodySheet(
                info: info,
                dataRoot: dataRoot,
                personaRoot: personaRoot
            ) { readerTarget = nil }
        }
    }

    /// Read the pointer-sync receipt the launch/mutation syncs write. Missing
    /// or malformed evidence stays visibly unavailable rather than reading as
    /// an empty successful sync.
    ///
    /// Render-cost audit F9: the `Data(contentsOf:)` + `JSONSerialization`
    /// pair used to run synchronously on the MainActor on every appear. Same
    /// parse, same resulting line, now off the main thread.
    private func loadSyncReceipt() async {
        let dataRoot = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
        syncReceiptState = await Task.detached(priority: .utility) {
            SkillPointerSyncReceiptPresentation.read(dataRoot: dataRoot)
        }.value
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
        .naInteractive(radius: 8)
        .onTapGesture { onRead() }
    }
}

// MARK: - Read-only body sheet

enum SkillBodyPresentation {
    static let maximumDisplayBytes = 128 * 1024

    enum State: Equatable, Sendable {
        case loading
        case content(String, truncated: Bool)
        case empty
        case unavailable(String)
    }

    static func bodyRoots(dataRoot: URL, personaRoot: URL) -> [URL] {
        [
            dataRoot.appendingPathComponent("skills/bodies", isDirectory: true),
            personaRoot.appendingPathComponent("skills/bodies", isDirectory: true),
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// Component comparison is intentional: a textual prefix would accept
    /// `bodies-backup/` as though it were nested inside `bodies/`.
    private static func isDescendant(_ child: URL, of root: URL) -> Bool {
        let childComponents = child.pathComponents
        let rootComponents = root.pathComponents
        return childComponents.count > rootComponents.count
            && childComponents.starts(with: rootComponents)
    }

    static func read(
        path: String,
        dataRoot: URL,
        personaRoot: URL,
        fileManager: FileManager = .default
    ) -> State {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .unavailable("This skill has no body file recorded.")
        }

        let raw = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let allowed = bodyRoots(dataRoot: dataRoot, personaRoot: personaRoot)
        guard allowed.contains(where: { isDescendant(raw, of: $0) }) else {
            return .unavailable("The recorded body path is outside this skill store.")
        }

        guard raw.pathExtension.lowercased() == "md" else {
            return .unavailable("The recorded body is not a Markdown skill file.")
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: raw.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .unavailable("The recorded body file is missing.")
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: raw.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                return .unavailable("The recorded body is not a regular file.")
            }
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount > 0 else { return .empty }
            let handle = try FileHandle(forReadingFrom: raw)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumDisplayBytes) ?? Data()
            return .content(
                String(decoding: data, as: UTF8.self),
                truncated: byteCount > Int64(maximumDisplayBytes)
            )
        } catch {
            return .unavailable("The body file could not be read: \(error.localizedDescription)")
        }
    }
}

struct SkillBodySheet: View {
    let info: SkillInfo
    let dataRoot: URL
    let personaRoot: URL
    let onDismiss: () -> Void
    @State private var state: SkillBodyPresentation.State = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: NativeAgentSpacing.md) {
            HStack {
                Text(info.id).font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            switch state {
            case .loading:
                ProgressView("Loading skill body…")
                    .accessibilityIdentifier("skills.lifecycle.body.loading")
            case .content(let body, let truncated):
                ScrollView {
                    Text(body)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("skills.lifecycle.body.content")
                if truncated {
                    Text("Showing the first \(SkillBodyPresentation.maximumDisplayBytes.formatted()) bytes of this skill body.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .empty:
                Label("Skill body is empty", systemImage: "doc")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("skills.lifecycle.body.empty")
            case .unavailable(let detail):
                VStack(alignment: .leading, spacing: 6) {
                    Label("Skill body unavailable", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.orange)
                .accessibilityIdentifier("skills.lifecycle.body.unavailable")
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
        .task(id: info.registry.path) {
            let path = info.registry.path
            let dataRoot = dataRoot
            let personaRoot = personaRoot
            state = await Task.detached(priority: .utility) {
                SkillBodyPresentation.read(
                    path: path,
                    dataRoot: dataRoot,
                    personaRoot: personaRoot
                )
            }.value
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
                        if let refusal = installRefusal {
                            installError = refusal
                        } else if SkillReviewInstallPresentation.needsOAuth(for: info) {
                            showOAuthFlow = true
                        } else {
                            Task { _ = await installSkill() }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!installControl.isEnabled)
                    .accessibilityIdentifier(SkillReviewInstallPresentation.installAccessibilityIdentifier)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let installRefusal {
                    Label(installRefusal, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, NativeAgentSpacing.xl)
                        .padding(.vertical, NativeAgentSpacing.sm)
                        .background(NativeAgentTheme.warn.opacity(0.08))
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
                                _ = await SkillReviewInstallPresentation.installAfterAuthorizedOAuth(
                                    oauthSucceeded: true,
                                    wasCancelled: false,
                                    install: { await installSkill() }
                                )
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
            Text(installError ?? "The installed registry state could not be verified.")
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
                .buttonStyle(.naFeel)
                Text("\(text.count - visibleText.count) characters hidden to keep the review sheet responsive.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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

    private var oauthDataRoot: URL {
        appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
    }

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
                wasCancelled = false
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
        guard let connectorId = SkillReviewInstallPresentation.connectorID(for: provider) else {
            self.error = "Native OAuth is not configured for \(provider)."
            isLoading = false
            return
        }
        let result = await NativeOAuthFlow.startConnectorOAuthFlow(
            connectorId: connectorId,
            dataRoot: oauthDataRoot
        )
        guard !Task.isCancelled, !wasCancelled else { isLoading = false; return }
        isLoading = false
        if result.ok {
            successLogin = ""
            withAnimation {
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
