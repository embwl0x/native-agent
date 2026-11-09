import SwiftUI
import Foundation
import NativeAgentShared
// Blueprint: | `AdvancedPresentation.swift` | Shared mobile presentation and design samples |

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
        "ApprovalRequest": ##"[{"id":"design-approval-hygiene","title":"Run memory hygiene after the test-heavy week","action":"self_improvement.apply","risk":"medium","reason":"[run_memory_hygiene] Run memory hygiene to consolidate duplicates and clear test-derived noise before it settles into long-term memory.","status":"pending","localOnly":true,"remoteResolvable":false},{"id":"design-approval-skill","title":"Keep this as a skill: workspace → workspace","action":"skill.proposal","risk":"low","reason":"This exact sequence ran 3 times across 2 days, verified successful every time. Approve to save the draft below as a skill body — I will find it through recall when a conversation enters its territory. It grants no permission, activates nothing, and runs nothing on its own. Deny and nothing is written.","payloadPreview":"# learned-workspace-then-workspace-8c211c66\n\nUse when a request calls for the same run of work this sequence keeps doing: `workspace` → `workspace`.\n\n## Steps\n1. `workspace` — arguments: path.\n2. `workspace` — arguments: path.\n","status":"pending","localOnly":true,"remoteResolvable":false},{"id":"design-approval","title":"Review the weekend project plan before sharing","action":"Share project summary","risk":"medium","reason":"The summary includes the updated milestones and a link to the working draft.","payloadPreview":"{\"tool\":\"mail_send\",\"input\":{\"to\":\"Sam\",\"subject\":\"Weekend project plan\",\"message\":\"Here is the updated plan with the new milestones. The working draft is linked at the bottom.\",\"attachDraft\":true,\"draftId\":\"doc_4821\"}}","status":"pending","localOnly":false,"remoteResolvable":true}]"##,
        "InboxItemRecord": #"[{"id":"design-inbox","created_at":"2026-09-07T18:00:00Z","source":"desk","severity":"info","title":"The research summary is ready to read","summary":"Three sources agree on the main result. One open question is included for the next conversation.","actions":[],"status":"unread"}]"#,
        "KGEntity": #"[{"id":"design-entity","name":"Weekend research and planning","type":"project","mention_count":12,"aliases":["Reading list"],"summary":"A collection of references and decisions for the next project review."}]"#,
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

enum StatusConnectionPresentation {
    enum SyncState: Equatable {
        case current(age: TimeInterval)
        case stale(age: TimeInterval, limit: TimeInterval)
        case neverSynced
        case clockMismatch(futureBy: TimeInterval)
    }

    static func syncState(
        lastSyncedAt: Date?,
        now: Date = Date(),
        staleAfter: TimeInterval? = nil,
        maximumFutureClockSkew: TimeInterval = 60
    ) -> SyncState {
        guard let lastSyncedAt else { return .neverSynced }

        let age = now.timeIntervalSince(lastSyncedAt)
        if age < -max(0, maximumFutureClockSkew) {
            return .clockMismatch(futureBy: -age)
        }
        if let staleAfter, age >= max(0, staleAfter) { return .stale(age: age, limit: max(0, staleAfter)) }
        return .current(age: max(0, age))
    }

    static func ageText(_ interval: TimeInterval) -> String {
        guard interval.isFinite, let seconds = Int(exactly: max(0, interval).rounded(.down)) else { return "age unavailable" }
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return "\(seconds / 3_600)h"
    }

    static func cardValue(for state: SyncState) -> String {
        switch state {
        case .current(let age): return "\(ageText(age)) ago"
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

    static func presenceDetail(for state: SyncState) -> String? {
        switch state {
        case .current:
            return nil
        case .stale(_, let limit):
            return "Expected to hear from your Mac within \(ageText(limit))."
        case .neverSynced:
            return "This iPhone has not heard from your Mac yet."
        case .clockMismatch(let futureBy):
            return "The Mac's last contact is \(ageText(futureBy)) ahead of this phone."
        }
    }

    static func needsAttention(_ state: SyncState) -> Bool {
        switch state {
        case .current: false
        case .stale, .neverSynced, .clockMismatch: true
        }
    }
}
