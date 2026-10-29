import Connectors
import ProviderRouting
import SwiftUI
import AppKit
import PersistenceCore
import PersonaEngine

// Blueprint: | `SkillLifecycleView.swift` | `SkillLifecycleView`: persona-guidance list/search/source reads and explicit build-draft handoff through existing chat owners |

// This page reads persona guidance; authored abilities live in Tools.
enum SkillLifecycleSearchPresentation {
    struct Results {
        let displayed: [SkillRecord]
        let isFiltering: Bool
        let resultCountText: String?
        let emptyTitle: String
        let emptyDetail: String
    }

    static func results(_ skills: [SkillRecord], query: String) -> Results {
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
                : "Ask me to build an ability in chat. You can review it in Tools."
        )
    }

    static func filtered(_ skills: [SkillRecord], query: String) -> [SkillRecord] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return skills }
        return skills.filter { info in
            searchableFields(for: info).contains { normalized($0).contains(needle) }
        }
    }

    private static func searchableFields(for info: SkillRecord) -> [String] {
        [info.id, info.name, info.description, "built in", "guidance"]
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
    @State private var readerTarget: String?

    private var skills: [SkillRecord] {
        appModel.engine.tools.skills.map { record in
            var skill = record
            if skill.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skill.id = skill.name }
            if skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { skill.name = skill.id }
            return skill
        }
    }

    private var searchResults: SkillLifecycleSearchPresentation.Results {
        SkillLifecycleSearchPresentation.results(skills, query: searchText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text("\(skills.count) skills · I pull up the right one when a conversation calls for it; the full text loads only when it is needed.")
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

            if let feedback = appModel.skillLifecycleFeedback {
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
                            SkillRow(info: info, onRead: { readerTarget = info.id })
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task {
            await appModel.loadSkillManifests()
        }
        .sheet(isPresented: Binding(get: { readerTarget != nil }, set: { if !$0 { readerTarget = nil } })) {
            if let info = skills.first(where: { $0.id == readerTarget }) {
                SkillSourceSheet(info: info, onDismiss: { readerTarget = nil })
            }
        }
    }
}

// MARK: - One skill row

private struct SkillRow: View {
    let info: SkillRecord
    let onRead: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(ShellType.bodySemibold)
                    .foregroundStyle(NativeAgentShell.text)
                Text(info.description)
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Text("built in")
                .font(ShellType.captionSemibold)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(NativeAgentShell.quietFill, in: Capsule())
                .foregroundStyle(NativeAgentShell.secondary)
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
    let info: SkillRecord
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(info.name).font(ShellType.title)
                Spacer()
                Button("Done") { onDismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                if let source = info.body {
                    BoundedSkillText(text: source, limit: 4_000)
                } else {
                    Text("This guidance has no text to show.")
                }
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
        .houseSheet()
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
            // Enable selection only for expanded previews to avoid per-glyph TextKit setup at first paint.
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

extension Notification.Name {
    static let skillBuildRequest = Notification.Name("NativeAgent.skillBuildRequest")
}
/// The latest user-visible outcome of a skill lifecycle operation. Identity is
/// part of the contract: a repeated failure is a new event even when its text
/// is byte-for-byte identical to the prior one.
struct SkillLifecycleFeedback: Identifiable, Equatable, Sendable {
    let id: UUID
    let message: String

    init(message: String) {
        self.id = UUID()
        self.message = message
    }
}

extension AppModel {
    @MainActor
    func recordSkillManifestFailure(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        skillManifestError = trimmed
        skillLifecycleFeedback = SkillLifecycleFeedback(message: trimmed)
    }

    @MainActor
    func dismissSkillManifestFeedback() {
        skillManifestError = nil
        skillLifecycleFeedback = nil
    }

}
