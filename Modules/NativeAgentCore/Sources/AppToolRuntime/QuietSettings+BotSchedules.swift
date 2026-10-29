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
// Blueprint: | `QuietSettings+BotSchedules.swift` | QuietSettings bot cadence parsing and schedule rows; snapshot reads stay scoped to display and writes reread the definition |

extension QuietSettings {
    /// A bot's cadence, in one line the model can both read and write: `manual`, `interval:900`, or `cron:<expression>`, on the Mac's local
    /// clock.
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

    /// One cadence row and one paused row per bot that exists right now.
    ///
    /// Bots are made and deleted while the app runs, so this part of the registry cannot be a compile-time list. It is still a registry and
    /// not reflection: each row names one bot by id and carries the same two store calls the Bots page makes (`update`, `pause`). A bot
    /// that has been deleted simply has no rows, which is the honest answer to "can I change its schedule".
    @MainActor
    static func botRows(_ appModel: (any QuietSettingsHost)?, snapshot: Bool = false) -> [QuietSetting] {
        guard let appModel,
              let bots = try? botStore(appModel).list() else { return [] }
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
                        guard let current = try? botStore(appModel).get(bot.id) else { return .string("") }
                        return .string(cadenceText(current.cadence))
                    },
                    write: { appModel, value in
                        let text = try stringValue(value, "\(name) schedule")
                        let store = botStore(appModel)
                        // Read fresh: `update` refuses a definition edited from a stale read, so the row must not carry the snapshot it was
                        // listed with.
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
                        guard let current = try? botStore(appModel).get(bot.id) else { return .bool(false) }
                        return .bool(current.paused)
                    },
                    write: { appModel, value in
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
            .int(Int64((BotRunLimits.minimumInterval / 60).rounded()))
        }
    )
}
