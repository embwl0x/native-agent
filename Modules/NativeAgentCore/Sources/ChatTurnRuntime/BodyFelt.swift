import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore
import Synchronization

// Blueprint: | `BodyFelt.swift` | `BodyFelt`: the one body line a turn carries for deviations the agent's turns have not been told, and its said-memory |

/// The body felt on the decision path: when an organ deviates and no delivered turn has carried it yet, the next turn's facts carry one short line in the
/// agent's own voice. A quiet body, an unread body and a body with no beats add nothing. What the agent's turns were told lives in `mind/body_said.json`,
/// stamped only when the provider accepts a context that carried the line, so a refused turn leaves it owed and a relaunch does not say it again.
enum BodyFelt {
    struct Pending: Sendable, Equatable {
        let line: String
        /// The organs the line names.
        let organs: [String]
        /// Every organ deviating when the line was read; a stamp keeps other turns' marks only for these.
        let deviating: Set<String>
        /// The said-memory once this line is delivered; nil when the saved memory could not be read and the line says so.
        let said: [String: OrganBody.Mark]?
    }

    static func saidURL(dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("mind/body_said.json")
    }

    /// The line this turn carries, or nil when there is nothing the agent's turns have not been told.
    static func pending(dataRoot: URL, now: Date) async -> Pending? {
        let read: OrganBody?
        do { read = try await OrganBody.read(now: now) }
        catch {
            // An unreadable record is not a quiet body: the line names the gap and is said again until the body reads.
            return Pending(line: "In my body: I can't read my organ beats (\(error.localizedDescription)); mind.body names what is known.",
                           organs: [], deviating: [], said: nil)
        }
        guard let body = read, !body.felt.isEmpty else { return nil }
        let said: [String: OrganBody.Mark]
        do { said = try load(dataRoot: dataRoot) }
        catch {
            // Without the memory every deviation would be said on every turn; the line names the gap instead, with the organs it cannot judge.
            let organs = body.felt.map(\.organ)
            return Pending(line: "In my body: I can't tell what I've already felt, because mind/body_said.json is unreadable (\(error.localizedDescription)); "
                + "mind.body shows " + organs.map(OrganBody.name).joined(separator: ", ") + ".", organs: organs, deviating: Set(organs), said: nil)
        }
        let unfelt = body.unfelt(said)
        guard let line = OrganBody.feltLine(unfelt) else { return nil }
        // Only the organs the line names are told; the rest stay owed to the next turn.
        let told = Array(unfelt.prefix(OrganBody.feltLineLimit))
        return Pending(line: line, organs: told.map(\.organ), deviating: Set(body.felt.map(\.organ)), said: body.marks(feeling: told, over: said))
    }

    /// Provider acceptance stamps what the line said. An unsaved stamp owes repair and the line is said again; the turn itself goes on.
    static func markSaid(_ pending: Pending, dataRoot: URL) {
        guard let said = pending.said else { return }
        do {
            try lock.withLock { _ in
                // Another turn may have stamped since this one read: keep its marks for organs that still deviate, take this line's for its own.
                var merged = try load(dataRoot: dataRoot).filter { pending.deviating.contains($0.key) }
                for organ in pending.organs { merged[organ] = said[organ] }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(merged), to: saidURL(dataRoot: dataRoot))
            }
            RepairOwed.settle(dataRoot, operation: operation, evidence: .init(source: "mind/body_said.json", id: pending.organs.joined(separator: ",")))
        } catch {
            RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .run, operation: operation, owner: "mind/body_said.json",
                           words: "A turn carried my body line, but what it said could not be saved: \(error.localizedDescription). I will say it again.",
                           lever: "Repair mind/body_said.json so it can be written; the next delivered body line stamps it.")
        }
    }

    /// A missing file is a body whose deviations no turn has been told.
    private static func load(dataRoot: URL) throws -> [String: OrganBody.Mark] {
        let data: Data
        do { data = try Data(contentsOf: saidURL(dataRoot: dataRoot)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: OrganBody.Mark].self, from: data)
    }

    private static let operation = "body.said"
    /// Concurrent turns write whole files; one at a time.
    private static let lock = Mutex(())
}
