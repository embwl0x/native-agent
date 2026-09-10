#if DEBUG
import Foundation
import StandingBots

/// Fixed, fictional evidence used only by the opt-in design preview and renderer.
enum BotsShelfSample {
    static var records: [BotsShelfRecord] {
        let day = Date(timeIntervalSince1970: 1_788_710_400)
        let names = ["Release notes and compatibility across the desktop and mobile apps, including setup changes and migration notices", "Trail conditions", "Reading list", "Inbox digest"]
        let briefs = ["Follow changes that affect the next app release.",
                      "Check access and closures before the weekend walk.",
                      "Collect useful papers about local inference.",
                      "Each morning, read new mail and tell me what needs an answer today."]
        return names.indices.map { index in
            let bot = BotDefinition(
                id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                name: names[index], brief: briefs[index], cadence: .interval(seconds: 43200),
                budget: BotBudget(tokens: 8000, seconds: 90), paused: index == 2, createdAt: day)
            let health: [ShelfRunHealth] = index == 0 ? [.partial, .nothingNew, .nothingNew, .failed, .ok, .nothingNew, .ok] : (index == 1 ? [.failed, .ok] : index == 2 ? [.failed, .nothingNew] : [.ok])
            let entries = health.enumerated().map { offset, health in
                let at = day.addingTimeInterval(Double(2 - offset) * 86400)
                var entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: at,
                    coverageStart: at.addingTimeInterval(-43200), coverageEnd: at,
                    headline: health == .failed ? "Source unavailable" : health == .nothingNew ? "No changes in the checked sources" : health == .partial ? "Release notes updated" : "Two changes worth reviewing",
                    findings: health == .failed ? "No comparison available for this run." : health == .nothingNew ? "" : health == .partial ? "Desktop: compatibility fix published. Mobile: setup instructions revised. Review both before the next release." : "The release notes add a compatibility fix and revised setup instructions. Both checked sources agree; the setup change affects new installations.",
                    changedSinceLastGood: "",
                    sourceLinks: health == .failed ? [] : [ShelfSourceLink(url: "https://example.com/release-notes", datedAt: at)],
                    uncertainties: health == .partial ? ["The secondary source was not checked before the time limit; additional changes may be missing."] : health == .failed ? ["The source did not respond. Current information could not be verified."] : [],
                    runHealth: health, spend: ShelfSpend(tokens: health == .failed ? 0 : 1240, seconds: health == .partial ? 90 : health == .failed ? 30 : 18))
                if health == .failed { entry.statusDetail = index == 2 ? "The mail account was signed out." : nil }
                if index == 3 { entry.status = .waitingForApproval; entry.statusDetail = "Approval is available in Approvals." }
                return entry
            }
            return BotsShelfRecord(definition: bot, entries: entries,
                unreadIDs: Set(entries.prefix(index == 0 ? 3 : index == 1 ? 1 : 0).map(\.id)),
                nextRun: day.addingTimeInterval(3 * 86400))
        }
    }
}
#endif
