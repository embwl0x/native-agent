import Foundation
import PersistenceCore

extension AgentWorkspaceNavigation {
    func observationStamps(key: String) -> [AgentWorkspaceChanges.Stamp] {
        sessions[key]?.observations ?? []
    }

    /// Reading a source acknowledges only the evidence actually presented.
    /// Conversation listings inspect these stamps without changing them.
    func observe(location: AgentWorkspaceLocation, result: JSONValue, key: String) -> JSONValue? {
        guard let candidate = AgentWorkspaceChanges.evaluate(location: location, result: result, previous: nil) else { return nil }
        guard let stamp = candidate.nextStamp else { return candidate.metadata }
        let previous = sessions[key]?.observations.first { $0.identity == stamp.identity }
        guard let observation = AgentWorkspaceChanges.evaluate(location: location, result: result, previous: previous) else { return nil }
        if let next = observation.nextStamp {
            sessions[key]?.observations.removeAll { $0.identity == next.identity }
            sessions[key]?.observations.append(next)
            if let count = sessions[key]?.observations.count, count > 64 {
                sessions[key]?.observations.removeFirst(count - 64)
            }
        }
        return observation.metadata
    }

    /// Replace a broad contact locator with the exact conversation chosen by
    /// its canonical owner, without making the model reconstruct that binding.
    func bindCurrent(from previous: AgentWorkspaceLocation, to bound: AgentWorkspaceLocation, key: String) {
        guard previous != bound, var session = sessions[key] else { return }
        if session.path.last == previous { session.path[session.path.count - 1] = bound }
        session.places.removeAll { Self.placeIdentity($0) == Self.placeIdentity(previous) || Self.placeIdentity($0) == Self.placeIdentity(bound) }
        session.places.append(bound)
        if let saved = Self.keepablePlace(bound, session: session),
           let index = session.keptPlaces.firstIndex(where: { Self.placeIdentity($0) == Self.placeIdentity(previous) }) {
            session.keptPlaces[index] = saved
            var seen = Set<String>()
            session.keptPlaces = session.keptPlaces.filter { place in
                Self.placeIdentity(place).map { seen.insert($0).inserted } ?? false
            }
        }
        if session.places.count > 24 { session.places.removeFirst(session.places.count - 24) }
        sessions[key] = session
    }
}
