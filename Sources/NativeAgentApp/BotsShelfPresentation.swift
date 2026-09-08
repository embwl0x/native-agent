import Foundation
import StandingBots

/// Defaults-backed design experiment, following NativeAgentShellPreference.
enum BotsShelfPreference {
    static let key = "uiBotsShelfPreview"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// Keeps the unflagged destination order intact, including callers' filtered lists.
enum BotsShelfRailProposal {
    static func destinations(_ items: [SidebarItem], enabled: Bool) -> [String] {
        guard enabled else { return items.map(\.rawValue) }
        return everyday(items).map(\.rawValue) + ["Bots"] + configuration(items).map(\.rawValue)
    }

    static func everyday(_ items: [SidebarItem]) -> [SidebarItem] {
        [.desk, .chat, .memories, .activity].filter(items.contains)
    }

    static func configuration(_ items: [SidebarItem]) -> [SidebarItem] {
        items.filter { !everyday(items).contains($0) }
    }
}

/// Value-only shelf projection. No store, acknowledgement, scheduling or budget writes.
struct BotsShelfRecord: Identifiable {
    var definition: BotDefinition
    var entries: [ShelfEntry]
    var unreadIDs: Set<UUID>
    var nextRun: Date?
    var unread: Int { unreadIDs.count }
    var sortedEntries: [ShelfEntry] { entries.sorted { $0.runAt > $1.runAt } }
    var latestProblem: ShelfEntry? {
        sortedEntries.first { $0.runHealth == .partial || $0.runHealth == .failed || !$0.uncertainties.isEmpty }
    }
    var catchUp: [ShelfEntry] {
        let warning = latestProblem
        return sortedEntries.filter { unreadIDs.contains($0.id) || $0.id == warning?.id }
            .sorted { left, right in
                if left.id == warning?.id { return right.id != warning?.id }
                if right.id == warning?.id { return false }
                return left.runAt > right.runAt
            }
    }
    var id: UUID { definition.id }
    var lastGood: ShelfEntry? {
        entries.filter { [.ok, .nothingNew].contains($0.runHealth) }.max { $0.runAt < $1.runAt }
    }
    var cadence: String {
        switch definition.cadence {
        case .interval(let seconds): "Every \(Int(seconds / 3600)) hours"
        case .cron(let expression, let timeZone): "\(expression) · \(timeZone)"
        }
    }
    var state: String {
        if definition.paused { return "Paused" }
        return entries.max { $0.runAt < $1.runAt }.map { Self.health($0.runHealth) } ?? "No runs yet"
    }
    static func health(_ health: ShelfRunHealth) -> String {
        switch health {
        case .ok: "Checked · findings available"
        case .nothingNew: "Checked, nothing new"
        case .partial: "Partly checked · coverage incomplete"
        case .failed: "Could not check"
        }
    }
    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    static func exactDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }
}
