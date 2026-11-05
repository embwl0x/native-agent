import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `AdvancedPresentation.swift` | Shared mobile presentation, bounded request summaries with raw prompts retained, and design samples |

/// Process-local screenshot fixtures. Never published to a store or transport.
enum MobileDesignSamples {
    static var screen: String? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-designScreen"), args.indices.contains(index + 1) {
            return args[index + 1]
        }
        #endif
        return nil
    }

    @MainActor static func rows<T: Decodable>(_ live: [T]) -> [T] {
        #if DEBUG
        guard screen != nil, live.isEmpty, let json = fixtures[String(describing: T.self)] else { return live }
        // Malformed DEBUG fixtures must fail visibly rather than masquerade as empty screens.
        do { return try JSONDecoder().decode([T].self, from: Data(json.utf8)) }
        catch {
            SystemToastCenter.shared.push(error: "Design sample is unavailable: \(error.localizedDescription)")
            return []
        }
        #else
        return live
        #endif
    }

    #if DEBUG
    private static let fixtures: [String: String] = [
        "ProviderInfo": #"[{"provider_id":"design-provider","display_name":"Research and long-form writing provider","auth_modes":["api_key"],"auth_status":{"provider_id":"design-provider","state":"ready","detail":"Connected","eligible":true},"models":[]}]"#,
        "ApprovalRequest": ##"[{"id":"design-approval-hygiene","title":"Run memory hygiene after the test-heavy week","action":"self_improvement.apply","risk":"medium","reason":"[run_memory_hygiene] Run memory hygiene to consolidate duplicates and clear test-derived noise before it settles into long-term memory.","status":"pending","localOnly":true,"remoteResolvable":false},{"id":"design-approval-skill","title":"Keep this as a skill: workspace → workspace","action":"skill.proposal","risk":"low","reason":"This exact sequence ran 3 times across 2 days, verified successful every time. Approve to save the draft below as a skill body — she will find it through recall when a conversation enters its territory. It grants no permission, activates nothing, and runs nothing on its own. Deny and nothing is written.","payloadPreview":"# learned-workspace-then-workspace-8c211c66\n\nUse when a request calls for the same run of work this sequence keeps doing: `workspace` → `workspace`.\n\n## Steps\n1. `workspace` — arguments: path.\n2. `workspace` — arguments: path.\n","status":"pending","localOnly":true,"remoteResolvable":false},{"id":"design-approval","title":"Review the weekend project plan before sharing","action":"Share project summary","risk":"medium","reason":"The summary includes the updated milestones and a link to the working draft.","payloadPreview":"{\"tool\":\"mail_send\",\"input\":{\"to\":\"Sam\",\"subject\":\"Weekend project plan\",\"message\":\"Here is the updated plan with the new milestones. The working draft is linked at the bottom.\",\"attachDraft\":true,\"draftId\":\"doc_4821\"}}","status":"pending","localOnly":false,"remoteResolvable":true}]"##,
        "InboxItemRecord": #"[{"id":"design-inbox","created_at":"2026-09-07T18:00:00Z","source":"desk","severity":"info","title":"The research summary is ready to read","summary":"Three sources agree on the main result. One open question is included for the next conversation.","actions":[],"status":"unread"}]"#,
        "MobileDeskItem": #"[{"handle":"design-desk","alias":"D-14","kind":"task","status":"active","project":"Weekend research and planning","title":"Collect the final notes for the project review","summary":"Compare the remaining sources and prepare a short summary.","openedAt":"2026-09-07T18:00:00Z","updatedAt":"2026-09-07T18:00:00Z","pinned":false,"blockedOn":[],"origin":"user","requiresOwnerInput":false,"recentNotes":[]}]"#,
        "KGEntity": #"[{"id":"design-entity","name":"Weekend research and planning","type":"project","mention_count":12,"aliases":["Reading list"],"summary":"A collection of references and decisions for the next project review."}]"#,
        "SkillManifestEntry": #"[{"id":"design-skill","name":"Research notes and source comparison","description":"Collect useful sources, compare the evidence, and write a concise summary.","source":"persona_body","triggers":[],"status":"active"}]"#,
        "MobileAppSetting": #"[{"id":"chat.file_access","page":"chat","label":"Chat file access","type":"choice","choices":["auto","workspace","read_only","none"],"writable":true,"value":"read_only"},{"id":"chat.quiet_mode","page":"chat","label":"Quiet mode","type":"boolean","choices":[],"writable":true,"value":"true"},{"id":"memories.mode","page":"memories","label":"Memory mode","type":"choice","choices":["performance","balanced","low_memory"],"writable":true,"value":"low_memory"},{"id":"memories.cross_session","page":"memories","label":"Remember across conversations","type":"boolean","choices":[],"writable":true,"value":"false"}]"#,
        "TurnSummaryRecord": #"[{"id":"design-turn","surface":"iPhone conversation","startedAt":810000000,"lastAt":810000008,"eventCount":12,"wallMs":8200,"llmTokens":1240,"ttftMs":430,"kinds":{"reply":1,"tool":2}}]"#
    ]
    #endif
}

struct MobileReadingSurface<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    @ViewBuilder var content: () -> Content

    var body: some View {
        // Content uses a fill over the haze; glass belongs to controls.
        content()
            .padding(NativeAgentMobileTheme.Spacing.lg)
            .aliveCard(radius: 16)
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
                }
            }
    }
}

struct MobileReadingStat: View {
    let label: String
    let value: String
    let systemImage: String

    var body: some View {
        MobileAdaptiveRow(spacing: 12) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(.caption, weight: .regular)).foregroundStyle(.secondary)
                Text(value).font(.system(.body, weight: .regular))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
    }
}

struct MobileAdaptiveRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = NativeAgentMobileTheme.Spacing.sm
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: alignment, spacing: spacing))
        layout { content() }
    }
}

extension View {
    func mobileReadingScreen() -> some View {
        scrollContentBackground(.hidden)
            .background { AliveRoom() }
            // Sheet backgrounds extend edge to edge so haze remains continuous under the bar.
            .presentationBackground { AliveRoom() }
            .hazeTinted()
            .environment(\.defaultMinListRowHeight, NativeAgentMobileTheme.Layout.controlHeight)
            .navigationBarTitleDisplayMode(.inline)
            .allowsHitTesting(MobileDesignSamples.screen == nil)
    }
}

enum RunKindPresentation {
    static func displayName(_ kind: String) -> String {
        RunKindVocabulary.displayName(kind, on: .iOS)
    }

    static func icon(_ kind: String) -> String {
        RunKindVocabulary.symbol(kind) ?? "questionmark.circle"
    }

}

struct RunDetailModelFact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

enum RunDetailPresentation {
    static func modelFacts(for run: RunRecord) -> [RunDetailModelFact] {
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }

        var facts: [RunDetailModelFact] = []
        let model = nonEmpty(run.model)
        if let model { facts.append(.init(label: "Model", value: model)) }
        if let requested = nonEmpty(run.requestedModel), requested != model {
            facts.append(.init(label: "Requested (substituted)", value: requested))
        }
        if let effort = nonEmpty(run.reasoningEffort) {
            facts.append(.init(label: "Reasoning effort", value: effort == "xhigh" ? "XHigh" : effort.capitalized))
        }
        if let sandbox = nonEmpty(run.codexSandbox) {
            facts.append(.init(label: "Sandbox", value: sandbox))
        }
        if let fileAccess = nonEmpty(run.fileAccessMode) {
            facts.append(.init(label: "File access", value: fileAccess))
        }
        return facts
    }
}

enum RunDetailCopyPresentation {
    static func successMessage(for section: String) -> String {
        let label = section.trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty
            ? "Copied run detail to clipboard."
            : "Copied \(label) to clipboard."
    }
}

enum RunDetailPromptPresentation {
    static let unavailableDescription = "The prompt was not captured for this run."

    /// Preserve the prompt verbatim for copying; blank payloads must not offer a section or Copy action.
    static func copyablePrompt(_ prompt: String?) -> String? {
        guard let prompt,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return prompt
    }

    /// Show content fields rather than packed instructions; name malformed/unknown data while retaining raw access.
    static func summary(_ prompt: String?) -> String? {
        guard let raw = copyablePrompt(prompt) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func text(_ value: String) -> String? {
            let line = value.split(whereSeparator: \.isNewline).joined(separator: " ")
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("{") || line.hasPrefix("[") { return nil }
            return line.count > 200 ? String(line.prefix(199)) + "…" : line
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) {
            func content(_ value: Any, depth: Int = 0) -> String? {
                guard depth < 4 else { return nil }
                if let string = value as? String { return text(string) }
                if let fields = value as? [String: Any] {
                    for key in ["title", "objective", "text", "prompt", "content", "messages"] {
                        if let value = fields[key], let line = content(value, depth: depth + 1) { return line }
                    }
                }
                if let rows = value as? [Any] {
                    for row in rows.prefix(8) {
                        if let fields = row as? [String: Any], fields["role"] as? String == "system" { continue }
                        if let line = content(row, depth: depth + 1) { return line }
                    }
                }
                return nil
            }
            return content(object) ?? "Structured request. Open the raw prompt for details."
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("```json") {
            return "Structured request; a readable summary is unavailable. Open the raw prompt for details."
        }
        return text(trimmed)
    }
}

enum StatusConnectionPresentation {
    static let staleAfter: TimeInterval = 30

    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval = Self.staleAfter,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        let limit = max(0, staleAfter)
        return age > limit ? .stale(age: age, limit: limit) : .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, let seconds = Int(exactly: max(0, interval).rounded(.down)) else { return "age unavailable" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "Fresh · \(ageText(age)) ago"
        case .stale(let age, _): return "STALE · \(ageText(age)) old"
        case .neverSynced: return "Never synced"
        case .clockMismatch: return "Clock mismatch"
        }
    }

    static func detail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected a newer iCloud snapshot within \(ageText(limit))."
        case .neverSynced:
            return "No iCloud snapshot has reached this phone yet."
        case .clockMismatch(let futureBy):
            return "The Mac snapshot is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}
