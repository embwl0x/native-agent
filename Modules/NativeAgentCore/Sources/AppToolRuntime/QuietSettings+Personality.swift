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
// Blueprint: | `QuietSettings+Personality.swift` | QuietSettings personality lists, dreams and name; writes use the loaded profile and checked persistence |

extension QuietSettings {
    /// One of the profile's free-form lists, written through the same `savePersonality` the Personality page uses. The whole profile is the
    /// unit of write, so the read has to come from the loaded profile and a write with none loaded refuses rather than inventing one.
    private static func personalityList(
        id: String,
        label: String,
        note: String,
        get: @escaping @Sendable (PersonalityProfile) -> [String]?,
        set: @escaping @Sendable (inout PersonalityProfile, [String]) -> Void
    ) -> QuietSetting {
        QuietSetting(
            id: id, page: "personality", label: label, kind: .list, note: note,
            read: { appModel in
                guard let profile = appModel.personality else { return .array([]) }
                return .array((get(profile) ?? []).map { .string($0) })
            },
            write: { appModel, value in
                let lines = try listValue(value, label)
                guard var profile = appModel.personality else {
                    throw QuietSettingError.unavailable(
                        "The personality profile has not loaded yet, so \(label.lowercased()) cannot be changed.")
                }
                set(&profile, lines)
                // Propagate the checked persistence outcome into the setting receipt.
                do {
                    try await appModel.savePersonalityChecked(profile)
                } catch {
                    throw QuietSettingError.unavailable(
                        "\(label) was not saved: \(error.localizedDescription)")
                }
            }
        )
    }

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
            read: { appModel in .bool(await appModel.dreamEnabled()) },
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
            read: { appModel in .bool(appModel.trustPolicy?.trainingPolicy?.rem_cycle_enabled ?? true) },
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
        rows.append(personalityList(
            id: "personality.instincts", label: "Instincts",
            note: "Free-form lines on the profile. Send the whole list you want — adding and "
                + "removing are the same write.",
            get: { $0.instincts }, set: { $0.instincts = $1 }
        ))
        rows.append(personalityList(
            id: "personality.boundaries", label: "Boundaries",
            note: "Free-form lines on the profile.",
            get: { $0.boundaries }, set: { $0.boundaries = $1 }
        ))
        rows.append(personalityList(
            id: "personality.examples", label: "Examples",
            note: "Free-form lines on the profile.",
            get: { $0.examples }, set: { $0.examples = $1 }
        ))
        rows.append(personalityList(
            id: "personality.forbidden_patterns", label: "Forbidden patterns",
            note: "Free-form lines on the profile.",
            get: { $0.forbiddenPatterns }, set: { $0.forbiddenPatterns = $1 }
        ))
        rows.append(QuietSetting(
            id: "personality.studio_shelf_slots", page: "personality",
            label: "Studio shelf slots in use", kind: .number,
            note: "The shelf holds at most three slots and that cap is fixed, not a setting. The "
                + "slots themselves are written as one complete ordered list by app studio.shelf_set, "
                + "not one at a time, so this is the count only.",
            read: { appModel in
                let root = appModel.dataRootOverride ?? PersistenceCore.defaultDataRoot()
                let slots = (try? StudioWorkingShelf(dataRoot: root).selections()) ?? []
                return .int(Int64(slots.count))
            }
        ))
        return rows
    }()

    static let personalityName = QuietSetting(
        id: "personality.name", page: "personality", label: "Name",
        kind: .text,
        note: "The name the app shows and the agent goes by. A generic label is refused.",
        read: { appModel in .string(appModel.personality?.name ?? "") },
        write: { appModel, value in
            let name = try stringValue(value, "Name")
            if let problem = await appModel.savePersonalityName(name) {
                throw QuietSettingError.unavailable("The name was not saved: \(problem)")
            }
        }
    )
}
