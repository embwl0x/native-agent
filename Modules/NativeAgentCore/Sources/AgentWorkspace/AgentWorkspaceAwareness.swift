import Foundation
import PersistenceCore
// Blueprint: | `AgentWorkspaceAwareness.swift` | `AgentWorkspaceNavigation`: resident observation stamps and current item binding |

extension AgentWorkspaceNavigation {
    func observationStamps(key: String) -> [AgentWorkspaceChanges.Stamp] {
        sessions[key]?.observations ?? []
    }

    func observe(location: AgentWorkspaceLocation, result: JSONValue, key: String) -> JSONValue? {
        let previous = AgentWorkspaceChanges.identity(location: location).flatMap { id in sessions[key]?.observations.first { $0.identity == id } }
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

    func bindCurrent(from previous: AgentWorkspaceLocation, to bound: AgentWorkspaceLocation, key: String) {
        guard previous != bound, var session = sessions[key] else { return }
        if session.current == previous { session.current = bound }
        if let index = session.watched.lastIndex(of: previous) { session.watched[index] = bound }
        sessions[key] = session
    }
}
