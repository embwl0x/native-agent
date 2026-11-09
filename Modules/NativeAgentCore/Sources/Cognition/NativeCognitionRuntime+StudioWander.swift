import CognitiveSubstrate
import Experiences
import Foundation
import MacControl
import MemoryV2
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import PersonaEngine
import Studio
// Blueprint: | `NativeCognitionRuntime+StudioWander.swift` | The hour's presence opportunity, material and wondering inside its ordinary thought |

/// Material held by one thought; the care owner checks its generation when keeping a returned question.
public struct HourOpportunity: Sendable {
    public let words: String
    let cares: [UUID]
    let generation: UInt64
}

extension NativeCognitionRuntime {
    /// The presence source has committed an away edge. The happening itself owns the local day's one opportunity.
    func senseHour(_ edge: Experience) async {
        while let held = sourceWakes.hourReading {
            await held.park()
            if Task.isCancelled { return }
        }
        let held = ScopedWaiter()
        sourceWakes.hourReading = held
        defer {
            sourceWakes.hourReading = nil
            held.resume()
        }
        guard !isFlushedForTermination, !Task.isCancelled,
              Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled,
              let presence = PersonPresence.read(dataRoot: dataRoot, now: now()).transition, !presence.here else { return }
        do {
            let at = now(), calendar = Calendar.current
            guard let edgeAt = NativeTimestampFormat.parseISO8601FractionalFirst(edge.at) else { throw CocoaError(.coderReadCorrupt) }
            guard calendar.isDate(edgeAt, inSameDayAs: at) else { return }
            let rest = try await restReading(at: at)
            guard let share = rest.objectValue?["activeShare"]?.numberValue(coercingStrings: false, finiteOnly: true), share >= 0.5 else { return }
            let parts = calendar.dateComponents([.year, .month, .day], from: at)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { throw CocoaError(.coderReadCorrupt) }
            let once = "hour:\(year)-\(month)-\(day)"
            guard try await ExperienceStore.at(dataRoot).experience("happening:" + once) == nil else { return }
            let body = await organismSnapshot()
            let shows = try JSONValue.object(["edge": .string(edge.id), "rest": rest,
                "curiosity": body.enabled ? .double(body.chemicalState.curiosity) : .null]).serialize(pretty: false)
            // Settings and presence may change while the owners are read.
            guard !isFlushedForTermination, !Task.isCancelled,
                  Self.studioWanderInstallationNow(dataRoot: dataRoot).isInstalled,
                  let current = PersonPresence.read(dataRoot: dataRoot, now: now()).transition,
                  !current.here, current.since == presence.since else { return }
            await Attention.post(Happening(.`self`, subject: "hour", door: "sense:hour", who: "self",
                words: "The person stepped away during his active hours. This time is mine, with nothing asked of it.",
                once: once, shows: shows), dataRoot: dataRoot).value
            if try await ExperienceStore.at(dataRoot).experience("happening:" + once) != nil {
                RepairOwed.settle(dataRoot, operation: "attention.hour", evidence: .init(source: "happening", id: "happening:" + once))
            }
        } catch {
            RepairOwed.owe(dataRoot, id: "hour", kind: .act, operation: "attention.hour", owner: "hour",
                words: error.localizedDescription, lever: "Repair the named hour evidence; no opportunity was inferred from its absence.")
        }
    }

    /// The live switches own installation; no cached copy can outlive a change in Settings.
    public static func studioWanderIsInstalled(dataRoot: URL) async -> Bool {
        studioWanderInstallationNow(dataRoot: dataRoot).isInstalled
    }

    static func studioWanderInstallationNow(dataRoot: URL) -> StudioWanderLane.Installation {
        StudioWanderLane.resolveInstallation(
            enabled: UserDefaults.standard.object(forKey: StudioWanderLane.enabledDefaultsKey) as? Bool,
            forcedNeutral: NativeAgentPublicSafety.shouldForceNeutralOrganism(dataRoot: dataRoot),
            subconsciousEnabled: UserDefaults.standard.object(forKey: "cognitiveSubstrateEnabled") == nil
                || UserDefaults.standard.bool(forKey: "cognitiveSubstrateEnabled"))
    }

    /// Empty sources permit exploration; unreadable sources keep their own named gaps beside the available material.
    public func hourOpportunity() async throws -> HourOpportunity {
        let (material, failures, cares, generation) = await composeStudioWanderMaterial()
        var words = try StudioWanderLane.prompt(material)
        if !failures.isEmpty { words += "\n\nUnread sources:\n" + failures.map { "- " + $0 }.joined(separator: "\n") }
        return HourOpportunity(words: words, cares: cares, generation: generation)
    }

    /// True only when this thought's returned question is durable in a new or continued care; no question supplies no care effect.
    public func keepHourWondering(_ output: String, opportunity: HourOpportunity, thought: String) async throws -> Bool {
        guard let question = Self.studioWanderQuestion(output) else { return false }
        let (asked, continuing) = Self.studioWanderContinuing(question, offered: opportunity.cares)
        guard try await substrate.noteHourWondering(asked, topic: nil, continuing: continuing,
            generation: opportunity.generation, source: thought) else {
            throw CognitiveCareNotSaved(detail: "the hour's care generation is no longer current")
        }
        return true
    }

    static func studioWanderQuestion(_ output: String) -> String? {
        output.components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }
            .last { $0.lowercased().hasPrefix("still wondering:") }
            .map { String($0.dropFirst("still wondering:".count)).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : String($0.prefix(240)) }
    }

    /// Let an explicit question key select the continued care; no key creates an independent care.
    static func studioWanderContinuing(_ question: String, offered: [UUID]) -> (question: String, care: UUID?) {
        guard question.hasPrefix("[w"), let close = question.firstIndex(of: "]"),
              let number = Int(question[question.index(question.startIndex, offsetBy: 2)..<close]),
              number > 0,
              offered.indices.contains(number - 1) else { return (question, nil) }
        let rest = question[question.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return (rest.isEmpty ? question : rest, offered[number - 1])
    }

    /// Compose only canonical open cares, consults, graph works and recent writing.
    /// Report unreadable sources separately from genuinely empty material.
    private func composeStudioWanderMaterial() async -> (
        material: StudioWanderLane.Material, sourceFailures: [String], offeredCares: [UUID], careGeneration: UInt64
    ) {
        let store = SwiftNativeStudioStore(dataRoot: dataRoot)
        var sourceFailures: [String] = []
        let (cares, careGeneration) = await substrate.caresForHour()

        var invitations: [StudioEncounterCandidate]
        do {
            let host = self.host, root = dataRoot
            invitations = try await store.namedEncounterIntake { input in
                try await host.callReadPart(id: "studio-intake", input: input, actions: ["studio.intake.read"],
                    dataRoot: root, origin: "studio_wander:intake")
            }
        } catch {
            invitations = []
            sourceFailures.append("named encounter intake: \(error.localizedDescription)")
        }
        do {
            let journaled = try await store.journaledWorkIdentities()
            let indexer = try SwiftNativeKnowledgeGraphIndexer(
                memorySQLitePath: dataRoot
                    .appendingPathComponent("memory/memory.sqlite")
                    .standardizedFileURL
            )
            invitations.append(contentsOf: try await indexer.unjournaledWorkCandidates(
                journaledWorks: journaled
            ))
        } catch {
            sourceFailures.append("knowledge graph work candidates: \(error.localizedDescription)")
        }

        let journal: [StudioJournalEntry]
        do {
            let read = try await store.readJournal()
            journal = read.entries
            sourceFailures += read.holes.map { "studio journal: \($0)" }
        } catch {
            journal = []
            sourceFailures.append("studio journal: \(error.localizedDescription)")
        }
        let recentTitles = journal
            .suffix(StudioWanderLane.Material.bulletLimit)
            .reversed()
            .map(\.work.title)

        var invitationLines: [String] = []
        do {
            let packet: [JSONValue] = invitations.map { candidate in
                .object(["source": .string(candidate.source.rawValue), "id": .string(candidate.originID),
                    "title": candidate.title.map(JSONValue.string) ?? .null,
                    "creator": candidate.creator.map(JSONValue.string) ?? .null,
                    "reference": candidate.reference.map(JSONValue.string) ?? .null])
            }
            let result = try await host.callReadPart(id: "studio-intake", input: .object([
                "operation": .string("invitations"), "candidates": .array(packet),
                "unavailable_sources": .array(sourceFailures.map(JSONValue.string))]),
                actions: ["studio.intake.read"], dataRoot: dataRoot, origin: "studio_wander:invitations")
            invitationLines = try JSONDecoder().decode([String].self, from: result.serializedData(pretty: false))
        } catch { sourceFailures.append("studio invitations: \(error.localizedDescription)") }
        let material = StudioWanderLane.Material(
            // Include consult IDs and their read action so the agent can receive actual artifact references rather than judge summaries alone.
            invitations: invitationLines,
            recentJournalTitles: Array(recentTitles),
            cares: cares.enumerated().map { "[w\($0.offset + 1)] \($0.element.about) — \($0.element.open ?? "")" }
        )
        return (material, sourceFailures, cares.map(\.id), careGeneration)
    }

    /// Saved provider preference identity; the hour's execution belongs to the ordinary mind stream.
    public static let studioWanderSurface = "studio_wander"
}
