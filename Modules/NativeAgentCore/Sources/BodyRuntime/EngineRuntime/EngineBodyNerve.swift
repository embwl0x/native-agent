import MindCore
import SenseCore
import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `EngineBodyNerve.swift` | `BodyNerve`: each beat re-reads the body; a newly felt deviation becomes a somatic signal and a fault owes repair, kept with why it is owed (a failure settles only by a pass) |

/// The body's integrator. Every beat re-reads the whole body, so an organ's silence is noticed as soon as any other organ beats. A deviation the nerve has
/// not felt (new, changed, or doubled) becomes one `organDeviated` signal; a failed or stuck organ owes repair once, kept with why it is owed and settled
/// by its next completed pass (a stuck organ's also by a busy beat, which says it is not stuck; a failure only by a pass, however many beats follow it).
/// What it has felt and what is owed live in `mind/body_nerve.json`, so a relaunch neither signals an ongoing deviation again nor forgets its debt.
public actor BodyNerve {
    struct Memory: Codable, Equatable {
        var felt: [String: OrganBody.Mark] = [:]
        /// Each organ that owes repair, with why: what may settle it follows from the fault it was owed for, never from beats read later.
        var owed: [String: OrganRecord.Deviation.Kind] = [:]

        init(felt: [String: OrganBody.Mark] = [:], owed: [String: OrganRecord.Deviation.Kind] = [:]) {
            self.felt = felt
            self.owed = owed
        }

        private enum CodingKeys: String, CodingKey { case felt, owed }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            felt = try container.decodeIfPresent([String: OrganBody.Mark].self, forKey: .felt) ?? [:]
            // A memory written before the reason was kept names only the organs; each is held to a pass, the one settlement every fault takes.
            if let organs = try? container.decode([String].self, forKey: .owed) {
                owed = Dictionary(uniqueKeysWithValues: organs.map { ($0, .failed) })
            } else {
                owed = try container.decodeIfPresent([String: OrganRecord.Deviation.Kind].self, forKey: .owed) ?? [:]
            }
        }
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
            await RepairOwed.owe(dataRoot, id: UUID().uuidString.lowercased(), kind: .run,
                operation: Self.recordOperation, owner: "mind.body",
                words: "The organ record could not be read: \(error.localizedDescription).",
                lever: "Read mind.body and repair its named record; the next body beat reads it again.").value
            return
        }
        guard let body = read else { return }
        await RepairOwed.settle(dataRoot, operation: Self.recordOperation, evidence: .init(source: "mind.body", id: "read")).value
        guard var memory = load() else { return }
        // A completed pass settles what the organ owes. So does a busy beat for a repair owed for being stuck: busy is a slot held by other work,
        // not a hold, so the organ is not stuck. A failure stays owed until the organ passes.
        let busy = Set(body.lines.filter { $0.latest.outcome == .busy }.map(\.organ))
        let settled = Set(memory.owed.compactMap { organ, kind in
            completed.contains(organ) || (kind == .stuck && busy.contains(organ)) ? organ : nil
        })
        completed = []
        let unfelt = body.unfelt(memory.felt)
        // Settlement comes first, so a pass and then a fresh fault in one read settle the old repair and owe the new one.
        var owed = memory.owed.filter { !settled.contains($0.key) }
        let owing = unfelt.filter { line in
            guard let kind = line.deviation?.kind, kind == .failed || kind == .stuck else { return false }
            return owed[line.organ] == nil
        }
        for line in owing { owed[line.organ] = line.deviation?.kind }
        // A stuck organ that then fails owes the one repair it already owes, now for its failure.
        for line in unfelt where line.deviation?.kind == .failed && owed[line.organ] == .stuck { owed[line.organ] = .failed }
        let next = Memory(felt: body.marks(feeling: unfelt, over: memory.felt), owed: owed)
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
        // The nerve is attached only while a mind runs; one closed meanwhile feels nothing more.
        Task {
            guard let cognition = NativeAgentEngine.liveCognition else { return }
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
    static let recordOperation = "body.nerve.record"

    static func operation(_ organ: String) -> String { "organ:" + organ }
}
