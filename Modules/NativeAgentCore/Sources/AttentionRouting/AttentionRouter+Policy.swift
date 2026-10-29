import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import NativeAgentShared
import NotificationInbox
import PersistenceCore
import TelegramBot
import DeviceSync
import Experiences
import Transcripts
// Blueprint: | `AttentionRouter+Policy.swift` | `AttentionRouter` class/origin routing policy, channel switches, urgency and shared quiet-hour window |

extension AttentionRouter {
    public static func delivery(
        importance: AttentionImportance,
        origin: AttentionOrigin? = nil
    ) -> AttentionDelivery {
        allowed(policy(importance: importance, origin: origin))
    }

    /// The person's channel switches, applied to whatever the table chose.
    ///
    /// A channel that is switched off is NOT quietly re-routed to another one:
    /// being told on the phone instead of Telegram is a different thing from
    /// being told, and silently upgrading the interruption is exactly what this
    /// router exists to prevent. Off means this way out is not used; the
    /// durable card in the app is still written either way.
    public static func allowed(
        _ delivery: AttentionDelivery,
        origin: AttentionOrigin? = nil,
        defaults: UserDefaults = .standard
    ) -> AttentionDelivery {
        switch delivery {
        case .none: return .none
        case .phone: return NotificationChannelPreference.push(in: defaults) ? .phone : .none
        case .telegram: return NotificationChannelPreference.telegram(in: defaults) ? .telegram : .none
        case .conversation:
            // Returning a follow-up to the conversation the PERSON opened is
            // not a new way in, so it is not gated by a new switch. The one
            // switch that already exists still means what it says: "don't knock
            // me on Telegram" closes the Telegram route, origin or not.
            return origin?.surface == .telegram
                && !NotificationChannelPreference.telegram(in: defaults)
                ? .none : .conversation
        }
    }

    /// The whole table, untouched by the switches — kept separate so the
    /// routing rule stays a pure function of importance and origin.
    public static func policy(
        importance: AttentionImportance,
        origin: AttentionOrigin? = nil
    ) -> AttentionDelivery {
        switch importance {
        case .routineSuccess:
            // Already in the rollup. Interrupting User to say a thing worked is
            // the exact noise this router exists to remove.
            return .none
        case .requestedResult:
            return .phone
        case .informational:
            // The morning brief and its kind: the phone, once. Not the surface
            // he happens to be on — an informational delivery is something he
            // reads when he chooses to, and its card is the durable receipt.
            return .phone
        case .ownerWaiting, .adverse:
            // FIRST: the conversation this came from, when it is one she can
            // answer into. A request about a piece of work belongs beside the
            // work, in the thread where it was asked for — not as a decoupled
            // phone push that makes the person go and find what it was about.
            if let origin, origin.canReturnToConversation { return .conversation }
            // Without a returnable conversation, send to his phone with Reply.
            return .phone
        }
    }

    /// Only adverse facts wake the device through Focus.
    public static func wakesTheDevice(_ importance: AttentionImportance) -> Bool {
        importance == .adverse
    }

    /// Non-waking classes wait through quiet hours; accepted destinations clear on release.
    public static func honorsQuietHours(_ importance: AttentionImportance) -> Bool {
        !wakesTheDevice(importance)
    }

    /// The declared TurnQuietHoursWindow is shared with the turn clock; absent means no hold.
    public static func inQuietHours(
        at date: Date,
        dataRoot: URL,
        calendar: Calendar = .current
    ) -> Bool {
        guard let window = TurnQuietHoursWindow.read(dataRoot: dataRoot) else { return false }
        return window.contains(hour: calendar.component(.hour, from: date))
    }
}
