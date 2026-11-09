import Foundation
import ChatTurnRuntime
import ChatTurnContracts
import NativeAgentCore
import PersistenceCore
import NativeAgentShared
import Experiences
// Blueprint: | `AttentionRouter+HeldDelivery.swift` | Release ForPerson's owed deliveries; retain failed observation results |

extension AttentionRouter {
    /// The delivery part's wake: any change to what is for the person sends what is owed, so an owner below the router only tells ForPerson with its doors.
    public func watch() async {
        for await _ in await ForPerson.at(dataRoot).changes() {
            guard !stopped else { return }
            do { _ = try await Self.release(dataRoot: dataRoot, router: self) }
            catch is CancellationError { return }
            catch {
                let failed = Experience(id: "attention.delivery.watch:" + UUID().uuidString.lowercased(), kind: .run,
                    outcome: .init(domain: "attention.delivery.watch", status: "failed", effects: .unknown),
                    face: .init(words: "Delivery remains owed: " + error.localizedDescription
                        + ". Repair the named door or experience store; its next change reopens observation.", artifacts: []))
                await ExperienceStore.record(dataRoot, failed.id) { store in _ = try await store.begin(failed) }.value
            }
        }
    }

    public static func hasHeld(dataRoot: URL) async throws -> Bool {
        try await !ForPerson.at(dataRoot).owed().isEmpty
    }

    /// Every matter with a door still owed goes now, unless the person's quiet hours still hold it; `retrying` adds doors that refused, for a wake on what
    /// they depend on (launch, network up, a door configured).
    public static func release(dataRoot: URL, router: AttentionRouter, retrying: Bool = false) async throws -> Int {
        var seen = Set<String>(), released = 0, failures: [String] = []
        for (matter, _) in try await ForPerson.at(dataRoot).owed(retrying: retrying) where seen.insert(matter.id).inserted {
            try Task.checkCancellation()
            do {
                if matter.face?.row?.tone != .failed, try quietHoursEnd(at: Date(), dataRoot: dataRoot) != nil { continue }
                let result = try await router.deliver(matter.id)
                if result.deliveryProjection == .accepted { released += 1 }
                for (door, outcome) in result.destinationOutcomes {
                    if case .notDelivered(let reason) = outcome { failures.append(matter.id + " " + door + ": " + reason) }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(matter.id + ": " + error.localizedDescription) }
        }
        if !failures.isEmpty {
            throw ToolFailureError("Delivery still owed (\(released) settled): " + failures.joined(separator: "; "),
                effects: .unknown, owner: "experiences", code: "held_delivery_unavailable",
                instruction: "Repair the named door. An unconfirmed send needs the door's own receipt before another attempt.", recovery: .reconcile)
        }
        return released
    }
}
