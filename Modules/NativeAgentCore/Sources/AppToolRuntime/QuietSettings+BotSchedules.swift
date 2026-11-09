import Foundation
import NativeAgentCore
import PersistenceCore
import StandingBots
import AgentConversations
import AuthoredCapabilities
import ChatToolRuntime
import MacIntegration
import PersonaEngine
import Senses
import ToolRegistry
import MultimodalTTS
import ChatSessionWork
import Cognition
import Context
import AttentionRouting
import NativeAgentShared
import ProviderRouting
import DeviceSync
import TrustCenter
import AgentWorkspace
import ChatTurnContracts
import ChromeControl
import MemoryV2
import TurnTrace
import Studio
// Blueprint: | `QuietSettings+BotSchedules.swift` | Bot cadence rows; mutation rereads canonical definitions |

extension QuietSettings {
    /// Cadence text must round-trip between the model and scheduler on the Mac's local clock.
    public static func cadenceText(_ cadence: BotCadence) -> String {
        switch cadence {
        case .manual: return "manual"
        case .interval(let seconds):
            if let rounded = Int(exactly: seconds.rounded()) { return "interval:\(rounded)" }
            return "interval:\(seconds)"
        case .cron(let expression): return "cron:\(expression)"
        }
    }

    public static func parseCadence(_ raw: String, _ label: String) throws -> BotCadence {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.caseInsensitiveCompare("manual") == .orderedSame { return .manual }
        if text.lowercased().hasPrefix("interval:") {
            let tail = String(text.dropFirst("interval:".count)).trimmingCharacters(in: .whitespaces)
            guard let seconds = Double(tail), seconds.isFinite, seconds > 0,
                  Int(exactly: seconds.rounded()) != nil else {
                throw QuietSettingError.badValue("\(label): interval takes positive seconds below \(Int.max), as interval:900.")
            }
            return .interval(seconds: seconds)
        }
        if text.lowercased().hasPrefix("cron:") {
            let expression = text.dropFirst("cron:".count).trimmingCharacters(in: .whitespaces)
            guard !expression.contains(":") else {
                throw QuietSettingError.badValue(
                    "\(label): cron takes cron:<expression>, as cron:0 7 * * *; it runs on this Mac's local clock, so there is no zone.")
            }
            return .cron(expression: expression)
        }
        throw QuietSettingError.badValue(
            "\(label) takes manual, interval:<seconds>, or cron:<expression> (on this Mac's local clock).")
    }

    @MainActor
    private static func botStore(_ appModel: any QuietSettingsHost) -> BotDefinitionStore {
        BotDefinitionStore(dataRoot: appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot())
    }

    /// Bots change at runtime, so rows bind exact ids to page-owned update/pause calls; deleted bots expose no stale controls.
    @MainActor
    static func botRows(_ appModel: (any QuietSettingsHost)?, snapshot: Bool = false) throws -> [QuietSetting] {
        guard let appModel else { throw QuietSettingError.unavailable("The helper settings owner is unavailable. Open Bots again before reading schedules.") }
        let bots = try botStore(appModel).list()
        return botRows(bots, snapshot: snapshot)
    }

    @MainActor
    static func botRows(_ bots: [BotDefinition], snapshot: Bool = false) -> [QuietSetting] {
        return bots.flatMap { bot -> [QuietSetting] in
            let key = bot.id.uuidString.lowercased()
            let name = bot.name
            return [
                QuietSetting(
                    id: "bots.\(key).cadence",
                    page: "bots",
                    label: "\(name) schedule",
                    kind: .text,
                    note: "manual, interval:<seconds>, or cron:<expression> (cron:0 8 * * *), on this Mac's local clock wherever it is. Scheduled runs "
                        + "may be no closer together than the bot floor "
                        + "(bots.minimum_interval_minutes), which the store enforces.",
                    read: { appModel in
                        if snapshot { return .string(cadenceText(bot.cadence)) }
                        let current = try botStore(appModel).get(bot.id)
                        return .string(cadenceText(current.cadence))
                    },
                    write: { appModel, value, context in
                        let text = try stringValue(value, "\(name) schedule")
                        let store = botStore(appModel)
                        // Reread definitions at mutation: update rejects stale snapshots retained from row discovery.
                        var edited = try store.get(bot.id)
                        edited.cadence = try parseCadence(text, "\(name) schedule")
                        _ = try store.update(edited)
                    }
                ),
                QuietSetting(
                    id: "bots.\(key).paused",
                    page: "bots",
                    label: "\(name) paused",
                    kind: .boolean,
                    note: "Paused stops scheduled turns. Follow-ups and run-once still work.",
                    read: { appModel in
                        if snapshot { return .bool(bot.paused) }
                        let current = try botStore(appModel).get(bot.id)
                        return .bool(current.paused)
                    },
                    write: { appModel, value, context in
                        _ = try botStore(appModel).pause(
                            bot.id, paused: try boolValue(value, "\(name) paused"))
                    }
                ),
            ]
        }
    }

    static let botScheduleFloor = QuietSetting(
        id: "bots.minimum_interval_minutes", page: "bots",
        label: "Closest a bot may run", kind: .number,
        note: "1 to 15 minutes; 15 when unset. The floor every bot cadence is held to. "
            + "The person's, by the same rule the bot tools follow: no bot tool sets it.",
        ownerOnly: true,
        read: { _ in
            .int(Int64((try BotRunLimits.checkedMinimumInterval() / 60).rounded()))
        }
    )
}
