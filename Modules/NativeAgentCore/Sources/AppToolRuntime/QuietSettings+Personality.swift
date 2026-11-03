import Foundation
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import Studio
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
import ProviderRouting
import DeviceSync
import TrustCenter
import AgentWorkspace
import ChatTurnContracts
import ChromeControl
import MemoryV2
import StandingBots
import TurnTrace
// Blueprint: | `QuietSettings+Personality.swift` | QuietSettings dreams and name; name reads and writes require the loaded profile; dream controls require checked Trust |

extension QuietSettings {
    static let personalityRows: [QuietSetting] = {
        var rows: [QuietSetting] = []
        // ── Personality / memories ──────────────────────────────────────────
        rows.append(defaultsBool(
            id: "personality.self_improvement", page: "settings",
            label: "Weekly self-improvement pass", key: "selfImprovementEnabled", defaultOn: true
        ))
        rows.append(QuietSetting(
            id: "personality.dreams", page: "settings", label: "Dreams at night",
            kind: .boolean,
            note: "One switch over two policy gates (personalityPolicy.dream_cycle_enabled and "
                + "trainingPolicy.dream_scheduler), which move together. The read-back is the "
                + "composite, so it says whether dreams can actually run.",
            requiresTrustPolicy: true,
            read: { appModel in .bool(try await appModel.dreamEnabled()) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Dreams at night")
                guard await appModel.setDreamCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The dream setting could not be saved.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "personality.rem_cycle", page: "settings",
            label: "Weekly dream consolidation", kind: .boolean,
            requiresTrustPolicy: true,
            read: { appModel in .bool(try loadedTrustPolicy(appModel, "Weekly dream consolidation").trainingPolicy?.rem_cycle_enabled ?? true) },
            write: { appModel, value in
                let enabled = try boolValue(value, "Weekly dream consolidation")
                guard await appModel.setRemCycleEnabled(enabled) else {
                    throw QuietSettingError.unavailable(
                        appModel.dreamError ?? "The weekly consolidation setting could not be saved.")
                }
            }
        ))
        rows.append(QuietSetting(
            id: "personality.rem_approval_mode", page: "personality",
            label: "REM approval", kind: .text,
            note: "Always manual, and not a setting: every REM proposal is staged for approval "
                + "before it changes a memory. There is no automatic mode to switch to. Shown "
                + "here so the agent can say why a REM run produced proposals and not changes.",
            read: { _ in .string("manual") }
        ))
        rows.append(QuietSetting(
            id: "personality.studio_shelf_slots", page: "personality",
            label: "Studio shelf slots in use", kind: .number,
            note: "The shelf holds at most three slots and that cap is fixed, not a setting. The "
                + "slots themselves are written as one complete ordered list by app studio.shelf_set, "
                + "not one at a time, so this is the count only.",
            read: { appModel in
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let slots = try StudioWorkingShelf(dataRoot: root).selections()
                return .int(Int64(slots.count))
            }
        ))
        return rows
    }()

    static let personalityName = QuietSetting(
        id: "personality.name", page: "personality", label: "Name",
        kind: .text,
        note: "The name the app shows and the agent goes by. A generic label is refused.",
        read: { appModel in .string(try loadedPersonality(appModel).name) },
        write: { appModel, value in
            _ = try loadedPersonality(appModel)
            let name = try stringValue(value, "Name")
            if let problem = await appModel.savePersonalityName(name) {
                throw QuietSettingError.unavailable("The name was not saved: \(problem)")
            }
        }
    )

    @MainActor
    private static func loadedPersonality(_ host: any QuietSettingsHost) throws -> PersonalityProfile {
        if let problem = host.personalityError {
            throw QuietSettingError.unavailable("Personality is unavailable: \(problem). Open Personality and repair its reported profile error before reading or changing the name.")
        }
        guard let profile = host.personality else {
            throw QuietSettingError.unavailable("Personality is unavailable. Open Personality and repair its reported profile error before reading or changing the name.")
        }
        return profile
    }
}
