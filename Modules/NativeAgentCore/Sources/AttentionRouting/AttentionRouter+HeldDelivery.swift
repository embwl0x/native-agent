import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import Experiences
// Blueprint: | `AttentionRouter+HeldDelivery.swift` | Releasing what the person's quiet hours held, and doors refused once what they depend on changed; read from ForPerson in memory |

extension AttentionRouter {
    /// The delivery part's wake: any change to what is for the person sends what is owed, so an owner below the router only tells ForPerson with its doors.
    public func watch() async {
        for await _ in await ForPerson.at(dataRoot).changes() {
            guard !stopped else { return }
            do { _ = try await Self.release(dataRoot: dataRoot, router: self) }
            catch { nativeLog("[AttentionRouter] %@", error.localizedDescription) }
        }
    }

    public static func hasHeld(dataRoot: URL) async throws -> Bool {
        try await !ForPerson.at(dataRoot).owed().isEmpty
    }

    /// Every matter with a door still owed goes now, unless the person's quiet hours still hold it; `retrying` adds doors that refused, for a wake on what
    /// they depend on (launch, network up, a door configured).
    public static func release(dataRoot: URL, router: AttentionRouter, retrying: Bool = false) async throws -> Int {
        let quiet = inQuietHours(at: Date(), dataRoot: dataRoot)
        var seen = Set<String>(), released = 0, failures: [String] = []
        for (matter, _) in try await ForPerson.at(dataRoot).owed(retrying: retrying) where seen.insert(matter.id).inserted {
            guard !Task.isCancelled else { break }
            if quiet, matter.face?.row?.tone != .failed { continue }
            do {
                let result = try await router.deliver(matter.id)
                if result.deliveryProjection == .accepted { released += 1 }
                for (door, outcome) in result.destinationOutcomes {
                    if case .notDelivered(let reason) = outcome { failures.append(matter.id + " " + door + ": " + reason) }
                }
            } catch { failures.append(matter.id + ": " + error.localizedDescription) }
        }
        if !failures.isEmpty {
            throw ToolFailureError("Delivery still owed (\(released) settled): " + failures.joined(separator: "; "),
                effects: .unknown, owner: "experiences", code: "held_delivery_unavailable",
                instruction: "Repair the named door. An unconfirmed send needs the door's own receipt before another attempt.", recovery: .reconcile)
        }
        return released
    }
}
