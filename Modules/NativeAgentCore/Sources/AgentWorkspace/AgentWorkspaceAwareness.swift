import Foundation
import PersistenceCore
// Blueprint: | `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: `observationStamps`, `observe`, `bindCurrent` |

extension AgentWorkspaceNavigation {
    func observationStamps(key: String) -> [AgentWorkspaceChanges.Stamp] {
        sessions[key]?.arrangement.observations ?? []
    }

    /// Reading a source acknowledges only the evidence actually presented.
    /// Conversation listings inspect these stamps without changing them.
    func observe(location: AgentWorkspaceLocation, result: JSONValue, key: String) -> JSONValue? {
        let previous = AgentWorkspaceChanges.identity(location: location).flatMap { id in sessions[key]?.arrangement.observations.first { $0.identity == id } }
        guard let observation = AgentWorkspaceChanges.evaluate(location: location, result: result, previous: previous) else { return nil }
        if let next = observation.nextStamp {
            sessions[key]?.arrangement.observations.removeAll { $0.identity == next.identity }
            sessions[key]?.arrangement.observations.append(next)
            if let count = sessions[key]?.arrangement.observations.count, count > 64 {
                sessions[key]?.arrangement.observations.removeFirst(count - 64)
            }
        }
        return observation.metadata
    }

    /// Replace a broad contact locator with the exact conversation chosen by
    /// its canonical owner, without making the model reconstruct that binding.
    func bindCurrent(from previous: AgentWorkspaceLocation, to bound: AgentWorkspaceLocation, key: String) {
        guard previous != bound, var session = sessions[key] else { return }
        if session.arrangement.path.last == previous { session.arrangement.path[session.arrangement.path.count - 1] = bound }
        // Only a window already open is rebound: a read (a look, a contact's
        // conversation) left no window in navigate and must not gain one here.
        let ids = [Self.placeIdentity(previous), Self.placeIdentity(bound)]
        if session.arrangement.places.contains(where: { ids.contains(Self.placeIdentity($0)) }) {
            session.arrangement.places.removeAll { ids.contains(Self.placeIdentity($0)) }
            session.arrangement.places.append(bound)
        }
        if let saved = Self.keepablePlace(bound, session: session),
           let index = session.arrangement.keptPlaces.firstIndex(where: { Self.placeIdentity($0) == Self.placeIdentity(previous) }) {
            session.arrangement.keptPlaces[index] = saved
            var seen = Set<String>()
            session.arrangement.keptPlaces = session.arrangement.keptPlaces.filter { place in
                Self.placeIdentity(place).map { seen.insert($0).inserted } ?? false
            }
        }
        while session.arrangement.places.count > 24 {
            guard let index = session.arrangement.places.firstIndex(where: { if case .form = $0 { return false }; return true }) else { break }
            session.arrangement.places.remove(at: index)
        }
        sessions[key] = session
    }
}
