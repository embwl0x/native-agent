import Foundation
import NativeAgentCore
import PersistenceCore

// Blueprint: | `SubconsciousVitalsCheck.swift` | `SubconsciousVitalsCheck`: measured capsule, felt vocabulary and chemistry |

// MARK: - Subconscious vitals (Cognition)
// Capsule drift may leave chat looking normal; measure bounded context snapshots and chemistry explicitly in Doctor. Name the window from this build's launch;
// rates and variety describe observations without grading the agent's health. The full feelingFrame and bounded cognitiveCue are measured independently;
// missing or clipped wording cannot be measured.

public struct SubconsciousVitalsCheck: DoctorCheck {
    public let id: String = "subconscious_vitals"
    public let title: String = "Subconscious Vitals"
    /// Measurement-window verdicts stay in Doctor and cannot trigger unattended pushes.
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let cache: DoctorScanCache

    private let capsuleSurfaces: Set<String> = ["chat", "telegram", "ios"]
    private let rutMarker = "let the moment pick the word"
    /// Values at chemistry rails remain readings, never health verdicts.
    private let pinnedHigh = 0.98
    private let pinnedLow = 0.02
    private let chemistryDimensions = ["agency", "confidence", "coherence", "warmth"]

    public init(
        root: URL = defaultDataRoot(),
        cacheTTL: TimeInterval = 60
    ) {
        self.root = root
        self.cache = DoctorScanCache(ttl: cacheTTL)
    }

    public func run() async -> CheckResult {
        let moment = Date()
        if let memo = await cache.fresh(now: moment) { return memo }
        let result = await measure()
        await cache.store(result, at: moment)
        return result
    }

    // MARK: - Measurement

    private func measure() async -> CheckResult {
        var eligibleTurns = Set<String>()
        var capsulePresent = Set<String>()
        var capsuleUnjudged = Set<String>()
        var feltCounts: [String: Int] = [:]
        var feltTurns = 0
        var soundTurns = 0
        var rutTurns = 0
        var innerLines: [String: Int] = [:]
        var innerTurns = 0
        var wordingTurns = 0
        var feelingFrameTurns = 0
        var feelingFrameBytes = 0
        var feelingFrameMaxBytes = 0
        var seenTurns = Set<String>()

        let moment = Date()
        guard let window = DoctorWindowFloor.resolve(root: root, now: moment) else {
            return CheckResult(source: root.appendingPathComponent(NativeAgentBuildIdentity.launchStampFilename).path,
                id: id, title: title, status: "unmeasured",
                detail: """
                    This launch's build stamp is unavailable or invalid. Repair build_launch.json through the app launch owner before measuring \
                    this build.
                    """)
        }
        let summary: TurnTraceScanSummary
        do {
            summary = try await TurnTraceWindowReader.scan(
                root: root,
                now: moment,
                floor: window.floor,
                kinds: ["context.snapshot"]
            ) { row in
                let payload = row.payload.objectValue ?? [:]
                guard let surface = row.surface, capsuleSurfaces.contains(surface) else { return }
                // Count each turn once even when its snapshot is reassembled.
                let key = row.turnId.isEmpty ? UUID().uuidString : row.turnId
                guard seenTurns.insert(key).inserted else { return }
                eligibleTurns.insert(key)

                let flag = payload["containsCognitiveSubstrate"]?.boolValue
                let capsuleBytes = payload["cognitiveCapsuleBytes"]?.intValue
                if flag == true || (capsuleBytes ?? 0) > 0 {
                    capsulePresent.insert(key)
                } else if flag == nil && capsuleBytes == nil {
                    // Nothing in this row can speak to the capsule either way.
                    capsuleUnjudged.insert(key)
                }

                var wordingMeasured = false
                if case .object(let frame)? = payload["feelingFrame"], frame["complete"]?.boolValue == true,
                   let paragraph = frame["paragraph"]?.stringValue, !paragraph.isEmpty,
                   frame["bytes"]?.integerValue == Int64(paragraph.utf8.count),
                   case .array(let words)? = frame["words"],
                   words.allSatisfy({ $0.stringValue?.isEmpty == false }) {
                    wordingMeasured = true
                    feelingFrameTurns = min(feelingFrameTurns, Int.max - 1) + 1
                    let bytes = paragraph.utf8.count
                    feelingFrameBytes = min(feelingFrameBytes, Int.max - bytes) + bytes
                    feelingFrameMaxBytes = max(feelingFrameMaxBytes, bytes)
                    let felt = words.compactMap(\.stringValue).map { $0.lowercased() }
                    if !felt.isEmpty { feltTurns = min(feltTurns, Int.max - 1) + 1 }
                    for word in felt {
                        feltCounts[word] = min(feltCounts[word, default: 0], Int.max - 1) + 1
                    }
                }
                if case .object(let cue)? = payload["cognitiveCue"], cue["truncated"]?.boolValue == false,
                   let kind = cue["kind"]?.stringValue,
                   let line = cue["line"]?.stringValue, !line.isEmpty {
                    wordingMeasured = true
                    if kind == "sound" {
                        soundTurns += 1
                        if line.localizedCaseInsensitiveContains(rutMarker) { rutTurns += 1 }
                    }
                    if kind == "inner" {
                        innerTurns += 1
                        innerLines[line.lowercased(), default: 0] += 1
                    }
                }
                if wordingMeasured { wordingTurns = min(wordingTurns, Int.max - 1) + 1 }
            }
        } catch {
            return CheckResult(source: TurnTraceWindowReader.source,
                id: id, title: title, status: "fail",
                detail: "The experience record could not be read, so the agent's subconscious vitals are unmeasured \(window.describedAs): \(error).",
                harm: "The agent's subconscious behavior cannot be checked from the saved turns.")
        }

        let chemistry = readChemistry()
        if case .unreadable(let reason) = chemistry {
            return CheckResult(source: "cognition/organism_state.json",
                id: id, title: title, status: "fail",
                detail: "data/cognition/organism_state.json exists but \(reason), so the agent's chemistry is unmeasured.",
                harm: "The agent's saved body state cannot be read.",
                human_action: ToolFailureError.fileRepairInstruction(root.appendingPathComponent("cognition/organism_state.json"),
                    shape: """
                        This JSON object retains organism state, including a chemicalState object with finite numeric agency, confidence, coherence \
                        and warmth values. Recover only values supported by the retained bytes.
                        """))
        }

        let coverageDetail = summary.coverageDetail

        if summary.isEmptyFeed {
            return CheckResult(source: "\(TurnTraceWindowReader.source) and cognition/organism_state.json",
                id: id, title: title, status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — no matching trace details were recorded; "
                    + chemistryLine(chemistry).sentence + coverageDetail + "."
            )
        }
        guard !eligibleTurns.isEmpty else {
            return CheckResult(source: "\(TurnTraceWindowReader.source) and cognition/organism_state.json",
                id: id, title: title,
                status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — \(summary.eventsRead) context.snapshot event(s)"
                    + " in window, but none on a capsule surface"
                    + " (\(capsuleSurfaces.sorted().joined(separator: "/"))), so the agent's subconscious behavior cannot be measured; "
                    + chemistryLine(chemistry).sentence + coverageDetail + "."
            )
        }

        var parts: [String] = [window.describedAs, summary.windowCovered]

        let judged = eligibleTurns.count - capsuleUnjudged.count
        if judged > 0 {
            let percent = Double(capsulePresent.count) / Double(judged) * 100
            parts.append(
                String(
                    format: "capsule on %.1f%% of %d judged %@ turn(s)",
                    percent, judged, capsuleSurfaces.sorted().joined(separator: "/")
                )
            )
        } else {
            parts.append("capsule attachment UNMEASURED — no eligible turn could be judged")
        }
        if !capsuleUnjudged.isEmpty {
            parts.append(
                "\(capsuleUnjudged.count) turn(s) carried neither the capsule flag nor its"
                    + " byte count and were UNJUDGED rather than counted as missing"
            )
        }
        parts.append(
            "feeling paragraph measured on \(feelingFrameTurns) of \(eligibleTurns.count) turn(s);"
                + " \(feelingFrameBytes) UTF-8 bytes in full, largest \(feelingFrameMaxBytes) bytes"
        )
        parts.append(
            "capsule wording measured on \(wordingTurns) of \(eligibleTurns.count) turn(s);"
                + " missing or clipped wording is NOT MEASURED"
        )

        let feltTotal = feltCounts.values.reduce(0) { min($0, Int.max - $1) + $1 }
        if feltTotal > 0, let top = feltCounts.max(by: { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }) {
            let share = Double(top.value) / Double(feltTotal) * 100
            parts.append(
                String(
                    format: "felt vocabulary: %d word instance(s) over %d turn(s), %d distinct;"
                        + " heaviest \"%@\" at %.1f%%",
                    feltTotal, feltTurns, feltCounts.count, top.key, share
                )
            )
        } else {
            parts.append("felt vocabulary UNMEASURED — no complete feeling paragraph supplied described feeling words")
        }

        if soundTurns > 0 {
            let percent = Double(rutTurns) / Double(soundTurns) * 100
            parts.append(
                String(
                    format: "Sound rut line on %.1f%% of %d turn(s) with a Sound line",
                    percent, soundTurns
                )
            )
        } else {
            parts.append("Sound line UNMEASURED — no turn yielded a readable Sound line")
        }

        if innerTurns > 0 {
            parts.append("\(innerLines.count) distinct Inner line(s) over \(innerTurns) turn(s)")
        } else {
            parts.append("Inner line NOT MEASURED — no turn yielded complete Inner wording")
        }

        // Chemistry values, including those at a rail, are observations rather than health grades.
        let chemLine = chemistryLine(chemistry)
        parts.append(chemLine.sentence)

        parts.append(contentsOf: summary.coverageParts)

        return CheckResult(source: "\(TurnTraceWindowReader.source) and cognition/organism_state.json",
            id: id, title: title, status: chemLine.level ?? (summary.unreadableRows == 0 ? "ok" : "unmeasured"),
            detail: parts.joined(separator: "; ") + "."
        )
    }

    // MARK: - Organism chemistry

    private enum Chemistry {
        case unmeasured(String)
        case unreadable(String)
        case measured([String: Double])
    }

    private func readChemistry() -> Chemistry {
        let path = root
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return .unmeasured("no data/cognition/organism_state.json")
        }
        guard let data = try? Data(contentsOf: path) else {
            return .unreadable("could not be read")
        }
        guard let value = try? JSONValue.parse(data), case .object(let object) = value else {
            return .unreadable("did not parse as JSON")
        }
        guard let chemicalState = object["chemicalState"] else {
            return .unreadable("carries no chemicalState object")
        }
        guard case .object(let state) = chemicalState else {
            return .unreadable("carries a non-object chemicalState")
        }
        var measured: [String: Double] = [:]
        for dimension in chemistryDimensions {
            guard let value = state[dimension] else { continue }
            guard let number = value.numberValue(coercingStrings: false, finiteOnly: false), number.isFinite else {
                return .unreadable("carries a non-numeric \(dimension) in chemicalState")
            }
            measured[dimension] = number
        }
        guard !measured.isEmpty else {
            return .unreadable(
                "carries none of \(chemistryDimensions.joined(separator: "/")) in chemicalState"
            )
        }
        return .measured(measured)
    }

    private func chemistryLine(
        _ chemistry: Chemistry
    ) -> (sentence: String, level: String?) {
        switch chemistry {
        case .unmeasured(let reason):
            return (
                "organism chemistry UNMEASURED — \(reason)",
                "unmeasured"
            )
        case .unreadable(let reason):
            return ("organism chemistry UNREADABLE — \(reason)", "unmeasured")
        case .measured(let dimensions):
            let rendered = dimensions
                .sorted { $0.key < $1.key }
                .map { String(format: "%@=%.2f", $0.key, $0.value) }
                .joined(separator: ", ")
            let pinned = dimensions
                .filter { $0.value >= pinnedHigh || $0.value <= pinnedLow }
                .sorted { $0.key < $1.key }
            let missing = chemistryDimensions.filter { dimensions[$0] == nil }
            var sentence = "organism chemistry \(rendered)"
            if !missing.isEmpty {
                sentence += " (\(missing.joined(separator: "/")) absent from the file, unjudged)"
            }
            guard !pinned.isEmpty else { return (sentence, missing.isEmpty ? nil : "unmeasured") }
            let named = pinned
                .map { String(format: "%@=%.3f", $0.key, $0.value) }
                .joined(separator: ", ")
            return (
                sentence + "; PINNED at a rail: \(named)",
                missing.isEmpty ? nil : "unmeasured"
            )
        }
    }
}
