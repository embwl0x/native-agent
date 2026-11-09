import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import Experiences
import MacControl
// Blueprint: | `AttentionRouter+Policy.swift` | The person's doors from the person's rulings (phone always, the thread it came from, the Mac while the person is at it); quiet hours |

extension AttentionRouter {
    /// The person's doors (`Door.person`), or the one door a pinned caller names.
    public static func doors(_ reach: Reach) -> [Door] {
        switch reach {
        case .inbox:
            return []
        case .person(let origin):
            return Door.person(thread: origin.flatMap(thread))
        case .pinned(let delivery, let origin):
            switch delivery {
            case .phone: return [.phone]
            case .mac: return [.mac]
            case .telegram, .conversation: return [origin.flatMap(thread)].compactMap { $0 }
            }
        }
    }

    /// The thread a matter came from, when the body can answer there (Telegram, Slack); Mac and phone conversations are labels, not doors.
    static func thread(_ origin: AttentionOrigin) -> Door? {
        guard origin.canReturnToConversation, let place = origin.destinationId else { return nil }
        switch origin.surface {
        case .telegram: return .telegram(chat: place, thread: origin.threadId)
        case .slack: return .slack(channel: place, thread: origin.threadId)
        case .chat, .ios: return nil
        }
    }

    /// The person is at the Mac when their own input says so; unknown is not here (the phone still gets it).
    public static func atMac() -> Bool { MacPersonInput.presence()?.here == true }

    /// A known window supplies both the hold and its release time; unavailable preferences supply neither verdict.
    public static func quietHoursEnd(at date: Date, dataRoot: URL) throws -> Date? {
        guard let window = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot),
              window.contains(hour: Calendar.current.component(.hour, from: date)) else { return nil }
        guard let end = window.end(after: date) else {
            throw ToolFailureError("The quiet-hours end could not be resolved. Repair the system calendar before releasing held notifications.",
                effects: .none, owner: "user_prefs.json", code: "quiet_hours_end_unavailable", recovery: .repair)
        }
        return end
    }

    /// An unreadable window holds: no interruption is admitted on unknown preferences (checkedRead records the owner failure).
    public static func inQuietHours(at date: Date, dataRoot: URL, calendar: Calendar = .current) -> Bool {
        do {
            guard let window = try TurnQuietHoursWindow.checkedRead(dataRoot: dataRoot) else { return false }
            return window.contains(hour: calendar.component(.hour, from: date))
        } catch { return true }
    }
}
