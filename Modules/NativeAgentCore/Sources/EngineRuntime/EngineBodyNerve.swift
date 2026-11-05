import Cognition
import CognitiveSubstrate
import Experiences
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `EngineBodyNerve.swift` | `BodyNerve`: each beat re-reads the body; a newly felt deviation becomes a somatic signal and a fault owes repair |

/// The body's integrator. Every beat re-reads the whole body, so an organ's silence is noticed as soon as any other organ beats. A deviation the nerve has
/// not felt (new, changed, or doubled) becomes one `organDeviated` signal; a failed or stuck organ owes repair once, settled by its next completed pass.
/// What it has felt and what is owed live in `mind/body_nerve.json`, so a relaunch neither signals an ongoing deviation again nor forgets its debt.
public actor BodyNerve {
    struct Memory: Codable, Equatable {
        var felt: [String: OrganBody.Mark] = [:]
        var owed: Set<String> = []
    }

    private enum State {
        case unread
        case read(Memory)
        /// The saved memory could not be read: nothing is felt this launch, since feeling it again would dose an ongoing deviation twice.
        case unreadable
    }

    private let dataRoot: URL
    private var state = State.unread
    private var feeling = false
    private var again = false
    /// Organs that completed a pass since the last integration.
    private var completed: Set<String> = []

    public init(dataRoot: URL) {
        self.dataRoot = dataRoot
    }

    var memoryURL: URL { dataRoot.appendingPathComponent("mind/body_nerve.json") }

    /// Hears one beat once it is in its ring. Beats that arrive while the body is being read fold into one more pass.
    public func feel(_ pulse: OrganPulse) async {
        if pulse.outcome == .worked || pulse.outcome == .nothing { completed.insert(pulse.organ) }
        guard !feeling else { again = true; return }
        feeling = true
        defer { feeling = false }
        repeat {
            again = false
            await integrate()
        } while again
    }

    private func integrate() async {
        let read: OrganBody?
        do { read = try await OrganBody.read() }
        catch {
            // Unread, nothing is felt, owed or settled; the next beat reads the body again.
            nativeLog("Body nerve: the organ record could not be read: %@", error.localizedDescription)
            return
        }
        guard let body = read else { return }
        guard var memory = load() else { return }
        let settled = memory.owed.intersection(completed)
        completed = []
        let unfelt = body.unfelt(memory.felt)
        let owing = unfelt.filter { line in
            guard let kind = line.deviation?.kind, kind == .failed || kind == .stuck else { return false }
            return !memory.owed.contains(line.organ)
        }
        let next = Memory(felt: body.marks(feeling: unfelt, over: memory.felt),
                          owed: memory.owed.subtracting(settled).union(owing.map(\.organ)))
        guard next != memory else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            try SwiftNativePersistenceCore.writeDataAtomicDurable(encoder.encode(next), to: memoryURL)
            RepairOwed.settle(dataRoot, operation: Self.memoryOperation, evidence: .init(source: "mind/body_nerve.json", id: "written"))
        } catch {
            // Unsaved, a relaunch would feel these again; nothing is signalled or owed until the memory holds them.
            RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .run, operation: Self.memoryOperation, owner: "mind/body_nerve.json",
                           words: "What my body has felt could not be saved: \(error.localizedDescription).",
                           lever: "Repair mind/body_nerve.json so it can be written; the next beat feels the body again.")
            return
        }
        memory = next
        state = .read(memory)
        for organ in settled {
            RepairOwed.settle(dataRoot, operation: Self.operation(organ), evidence: .init(source: "beat", id: organ))
        }
        for line in owing {
            guard let deviation = line.deviation else { continue }
            RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .run, operation: Self.operation(line.organ), owner: line.organ,
                           words: "My \(OrganBody.name(line.organ)) \(deviation.why).",
                           lever: "Read mind.body for its last beats and repair the cause its note names; its next completed pass settles this.")
        }
        guard !unfelt.isEmpty else { return }
        Task {
            let cognition = NativeAgentEngine.liveCognition
            for line in unfelt {
                guard let deviation = line.deviation else { continue }
                await cognition.ingestOrganismSignal(kind: .organDeviated, sourceOrgan: "organ." + line.organ,
                    metadata: ["deviation": .string(deviation.kind.rawValue), "size": .int(Int64(deviation.size))])
            }
        }
    }

    /// The saved memory, read once per launch. A missing file is a body that has felt nothing yet.
    private func load() -> Memory? {
        switch state {
        case .read(let memory): return memory
        case .unreadable: return nil
        case .unread: break
        }
        do {
            let data: Data
            do { data = try Data(contentsOf: memoryURL) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                state = .read(Memory())
                return Memory()
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let memory = try decoder.decode(Memory.self, from: data)
            state = .read(memory)
            RepairOwed.settle(dataRoot, operation: Self.memoryOperation, evidence: .init(source: "mind/body_nerve.json", id: "read"))
            return memory
        } catch {
            state = .unreadable
            RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .run, operation: Self.memoryOperation, owner: "mind/body_nerve.json",
                           words: "What my body has felt could not be read, so I feel no organ until it is repaired: \(error.localizedDescription).",
                           lever: "Repair or remove mind/body_nerve.json, then relaunch; its bytes are preserved until then.")
            return nil
        }
    }

    static let memoryOperation = "body.nerve.memory"

    static func operation(_ organ: String) -> String { "organ:" + organ }
}
