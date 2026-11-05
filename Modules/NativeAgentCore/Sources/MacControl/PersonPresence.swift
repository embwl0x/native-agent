import Foundation
import NativeAgentShared
import PersistenceCore

// Blueprint: | `PersonPresence.swift` | One Mac/phone presence; phone departure arms physical return, missing evidence stays unknown |
public enum PersonPresence {
    public static let phoneFreshFor = PhoneSenseHistory.freshFor
    public struct Reading: Sendable {
        public let line: String
        public let transition: (here: Bool, since: Date)?
    }

    public static func read(dataRoot: URL, now: Date = Date()) -> Reading {
        let mac = MacPersonInput.presence()
        let lastPersonInput = (MacPersonInput.idle()?.seconds).map { now.addingTimeInterval(-$0) }
        var transition = MacPersonInput.presenceChange()
        var lines = [mac.map { $0.here
            ? "at the computer (Mac input, \(Int($0.seconds))s ago)"
            : "away from computer \(Int($0.seconds / 60))m (Mac input)" }
            ?? "computer presence unknown (Mac input unavailable)"]
        do {
            let places = try PhonePlaceHistory.read(dataRoot)
            let senses = try PhoneSenseHistory.read(dataRoot)
            let newest = (places.map(\.timestamp) + senses.map(\.timestamp)).max()
            func clock(_ date: Date) -> String { date.formatted(.iso8601) }
            func fresh(_ date: Date) -> Bool { (0...phoneFreshFor).contains(now.timeIntervalSince(date)) }
            let place = places.max { $0.timestamp < $1.timestamp }
            if let place {
                lines.append(
                    """
                        phone \(place.transition == .left ? "left" : "at") \(String(reflecting: place.name)) at \(clock(place.timestamp)) (phone \
                        place\(fresh(place.timestamp) ? "" : ", last observation"))
                        """)
            }
            var latest: [PhoneSenseEvent.Source: PhoneSenseEvent] = [:]
            for event in senses where !event.isSetup && (latest[event.source].map({ $0.timestamp < event.timestamp }) ?? true) { latest[event.source] = event }
            for source in PhoneSenseEvent.Source.allCases {
                guard let event = latest[source] else { continue }
                lines.append(PhoneSenseHistory.observationLine(event, now: now))
            }
            let setups = senses.filter(\.isSetup)
            let latestSetup = PhoneSenseEvent.Source.allCases.compactMap { source in
                setups.filter { $0.source == source }.max { $0.timestamp < $1.timestamp }
            }
            let needsSetup = latestSetup.filter { !($0.setup?.missing.isEmpty ?? false) }.map { $0.source.title }
            if !needsSetup.isEmpty {
                lines.append(
                    """
                        phone setup missing for \(needsSetup.joined(separator: ", ")); read app {page:\"pairing\",item:\"phone-senses\"} for the missing steps \
                        and phone senses guide
                        """)
            } else if latestSetup.count < PhoneSenseEvent.Source.allCases.count {
                lines.append("phone sense setup not fully reported; open the paired phone app, then read app {page:\"pairing\",item:\"phone-senses\"}")
            }
            let firstMovement = senses.filter { observation in
                observation.isMovement
                    && (lastPersonInput.map { observation.timestamp > $0 } ?? true)
            }.min { $0.timestamp < $1.timestamp }
            // A Mac-away deadline confirms the same absence, not a new departure.
            if let settled = transition, !settled.here, let firstMovement, firstMovement.timestamp < settled.since {
                transition = (false, firstMovement.timestamp)
            }
            if let newest { if !fresh(newest) { lines.append("phone unknown since \(clock(newest))") } }
            else { lines.append("phone unknown as of \(clock(now)) (never reported)") }
            // Motion proves departure, never arrival; later physical Mac input wins, while focus and charging alone prove neither.
            if let motion = latest[.motion], fresh(motion.timestamp), motion.isMovement,
               lastPersonInput.map({ $0 < motion.timestamp }) ?? true {
                let began = firstMovement?.timestamp ?? motion.timestamp
                transition = (false, transition.flatMap { !$0.here ? min($0.since, began) : nil } ?? began)
                MacPersonInput.observeReturn(after: began)
                lines.append("away from computer inferred from phone \(motion.value)")
            }
            if let charging = latest[.charging], charging.value == "charging", charging.localNight == true,
               fresh(charging.timestamp), let motion = latest[.motion], motion.value == "stationary", motion.supportsPresenceInference, fresh(motion.timestamp),
               mac?.here != true {
                lines.append("probably asleep (inference: phone charging, phone stationary, phone-local night)")
            }
        } catch {
            lines.append("phone unknown (evidence unreadable: \(error.localizedDescription))")
        }
        return Reading(line: lines.joined(separator: "; "), transition: transition)
    }
}
