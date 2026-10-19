import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - Subconscious vitals (Cognition)
//
// The cognitive capsule is the one part of her that nobody sees. It rides
// INSIDE the prompt, it is never quoted back, and when it degrades — the
// capsule stops being attached, the felt vocabulary collapses onto two words,
// the same Inner line repeats for a week — the chat still looks fine. That is
// exactly the drift NORTHSTAR clause 2 calls theater: a live mechanism whose
// failure is silent.
//
// This row reads the `context.snapshot` turn-trace rows (bounded tail read, at
// most 7 day files, only when Doctor runs) and the organism's own chemistry
// file, and reports MEASURED numbers with their denominators. Nothing here is a
// placeholder, and nothing here runs on a turn.
//
// The window starts at THIS BUILD's launch (DoctorWindowFloor) and is named in
// the row. Rates and variety describe that window without grading her health.
//
// Wording comes only from the bounded `cognitiveCue` field, retained even when
// the snapshot is truncated. Missing or clipped wording is not measured.

public struct SubconsciousVitalsCheck: DoctorCheck {
    public let id: String = "subconscious_vitals"
    public let title: String = "Subconscious Vitals"
    /// Doctor's eyes only. A window verdict must never become an unattended
    /// push notification — see `DoctorCheck.heartbeatEligible`.
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let cache: DoctorScanCache

    /// Hard ceiling on day FILES opened; the window's floor is this build's
    /// launch (see DoctorWindowFloor).
    private let maximumDayFiles = 7
    /// The conversational surfaces whose capsule observations are counted.
    private let capsuleSurfaces: Set<String> = ["chat", "telegram", "ios"]
    /// The Sound line that says her phrasing has gone stale.
    private let rutMarker = "let the moment pick the word"
    /// Report the chemistry's distance from its rails without grading it.
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
        let result = measure()
        await cache.store(result, at: moment)
        return result
    }

    // MARK: - Measurement

    private func measure() -> CheckResult {
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
        var seenTurns = Set<String>()

        let moment = Date()
        let window = DoctorWindowFloor.resolve(root: root, now: moment)
        let summary = TurnTraceWindowReader.scan(
            root: root,
            now: moment,
            days: window.dayFilesToRead(now: moment, maximum: maximumDayFiles),
            floor: window.floor,
            kinds: ["context.snapshot"]
        ) { row in
            guard let surface = row.surface, capsuleSurfaces.contains(surface) else { return }
            // One snapshot per turn is the norm; a re-assembled turn must not
            // count twice in any denominator.
            let key = row.turnId.isEmpty ? UUID().uuidString : row.turnId
            guard seenTurns.insert(key).inserted else { return }
            eligibleTurns.insert(key)

            let flag = row.payload["containsCognitiveSubstrate"]?.boolValue
            let capsuleBytes = row.payload["cognitiveCapsuleBytes"]?.intValue
            if flag == true || (capsuleBytes ?? 0) > 0 {
                capsulePresent.insert(key)
            } else if flag == nil && capsuleBytes == nil {
                // Nothing in this row can speak to the capsule either way.
                capsuleUnjudged.insert(key)
            }

            guard case .object(let cue)? = row.payload["cognitiveCue"],
                  cue["truncated"]?.boolValue == false,
                  let kind = cue["kind"]?.stringValue,
                  let line = cue["line"]?.stringValue, !line.isEmpty else { return }
            wordingTurns += 1
            if kind == "felt" {
                let felt = line.split(separator: ",").map { Self.feelingWord(in: $0) }
                    .filter { !$0.isEmpty }
                feltTurns += 1
                for word in felt { feltCounts[word, default: 0] += 1 }
            }
            if kind == "sound" {
                soundTurns += 1
                // The named rut rides its own Sound line after the echo.
                if line.localizedCaseInsensitiveContains(rutMarker) { rutTurns += 1 }
            }
            if kind == "inner" {
                innerTurns += 1
                innerLines[line.lowercased(), default: 0] += 1
            }
        }

        if let day = summary.unreadableDays.first {
            let file = root.appendingPathComponent("turn_traces/\(day).jsonl")
            return CheckResult(source: file.path,
                nextCall: ToolFailureError.fileRepairCall(file, dataRoot: root,
                    shape: "This day file holds one persisted TurnTraceEvent JSON object per line, with its original event identity, timestamp and payload."),
                id: id, title: title, status: "fail",
                detail: "\(summary.unreadableDays.count) turn-trace day file(s) exist but could"
                    + " not be read (\(summary.unreadableDays.joined(separator: ", ")))."
                    + " Her subconscious vitals are UNMEASURED \(window.describedAs) — this"
                    + " row is not reporting healthy, it is reporting that it could not look.",
                harm: "Her subconscious behavior cannot be checked from the saved turns."
            )
        }

        let chemistry = readChemistry()
        if case .unreadable(let reason) = chemistry {
            return CheckResult(source: "cognition/organism_state.json",
                nextCall: ToolFailureError.fileRepairCall(root.appendingPathComponent("cognition/organism_state.json"), dataRoot: root,
                    shape: "This JSON object retains organism state, including a chemicalState object with finite numeric agency, confidence, coherence and warmth values. Recover only values supported by the retained bytes."),
                id: id, title: title, status: "fail",
                detail: "data/cognition/organism_state.json exists but \(reason)."
                    + " Her chemistry is UNMEASURED, which is a finding about this row's"
                    + " coverage, not a clean reading.",
                harm: "Her saved body state cannot be read."
            )
        }

        var coverageParts: [String] = []
        if !summary.truncatedDays.isEmpty {
            coverageParts.append(
                "\(summary.truncatedDays.count) day file(s) were tailed to the read budget"
                    + " (\(summary.truncatedDays.joined(separator: ", "))), so earlier turns"
                    + " that day were not scanned"
            )
        }
        if summary.malformedLines > 0 {
            coverageParts.append("\(summary.malformedLines) trace line(s) did not parse")
        }
        let coverageDetail = coverageParts.isEmpty ? "" : " " + coverageParts.joined(separator: "; ") + "."

        if summary.isEmptyFeed {
            return CheckResult(source: "turn_traces/ and cognition/organism_state.json",
                id: id, title: title, status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — no turn-trace day files under"
                    + " data/turn_traces. "
                    + chemistryLine(chemistry).sentence
            )
        }
        guard !eligibleTurns.isEmpty else {
            return CheckResult(source: "turn_traces/ and cognition/organism_state.json",
                id: id, title: title,
                status: "unmeasured",
                detail: "UNMEASURED \(window.describedAs) — \(summary.daysPresent.count)"
                    + " trace day(s) read and \(summary.matchedRows) context.snapshot row(s)"
                    + " in window, but none on a capsule surface"
                    + " (\(capsuleSurfaces.sorted().joined(separator: "/")))."
                    + " Nothing about her subconscious can be measured. "
                    + chemistryLine(chemistry).sentence + coverageDetail
            )
        }

        var parts: [String] = [window.describedAs]

        // 1. Capsule attachment.
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
        // Cadence can intentionally leave a turn quiet; attachment is an observation.
        parts.append(
            "capsule wording measured on \(wordingTurns) of \(eligibleTurns.count) turn(s);"
                + " missing or clipped wording is NOT MEASURED"
        )

        // 2. Felt-word mass.
        let feltTotal = feltCounts.values.reduce(0, +)
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
            parts.append("felt vocabulary UNMEASURED — no turn yielded a readable feeling line")
        }

        // 3. The Sound rut line.
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

        // 4. Inner-line variety.
        if innerTurns > 0 {
            parts.append("\(innerLines.count) distinct Inner line(s) over \(innerTurns) turn(s)")
        } else {
            parts.append("Inner line NOT MEASURED — no turn yielded complete Inner wording")
        }

        // 5. Organism chemistry is a reading, including values at a rail.
        let chemLine = chemistryLine(chemistry)
        parts.append(chemLine.sentence)

        if !coverageParts.isEmpty {
            parts.append(contentsOf: coverageParts)
            // A bounded read is coverage, not a fault; the detail names it.
        }

        return CheckResult(source: "turn_traces/ and cognition/organism_state.json",
            id: id, title: title, status: chemLine.level ?? "ok",
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
            guard let number = value.doubleValue, number.isFinite else {
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
                "unmeasured"
            )
        }
    }

    /// One comma-separated entry reduced to the feeling word itself. An entry
    /// may name what the feeling is ABOUT after a dash — "curious — completion
    /// event" is one feeling, "curious", not a distinct vocabulary item per
    /// subject. Keeping the subject inflates apparent emotional range every
    /// time the subject changes.
    private static func feelingWord(in entry: some StringProtocol) -> String {
        var value = entry.trimmingCharacters(in: .whitespaces)
        for separator in [" — ", " – ", " - ", "—", "–"] {
            if let range = value.range(of: separator) {
                value = String(value[..<range.lowerBound])
                break
            }
        }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
