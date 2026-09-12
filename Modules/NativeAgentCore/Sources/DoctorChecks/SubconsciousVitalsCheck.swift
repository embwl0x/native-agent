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
// the row, so a verdict always describes the build that is running. Rates over
// a handful of turns are shown but not graded — see `minimumRateTurns`.
//
// Reading the payload honestly takes some care. `context.snapshot` carries the
// assembled prompt as `_preview`, which is a TRUNCATED serialization of the
// real payload — so it usually will not parse as JSON. The reader below tries
// the structured path first (`cognitivePreview`, when the preview happens to be
// intact) and falls back to unescaping the text and reading the capsule's own
// labelled lines. A row that yields neither is counted as UNJUDGED, never as a
// missing capsule.

public struct SubconsciousVitalsCheck: DoctorCheck {
    public let id: String = "subconscious_vitals"
    public let title: String = "Subconscious Vitals"
    /// Doctor's eyes only. A window verdict must never become an unattended
    /// push notification — see `DoctorCheck.heartbeatEligible`.
    public let heartbeatEligible: Bool = false

    private let root: URL
    private let now: @Sendable () -> Date
    /// The build whose behavior this row is allowed to grade.
    private let identity: NativeAgentBuildIdentity
    private let cache: DoctorScanCache

    /// Hard ceiling on day FILES opened; the window's floor is this build's
    /// launch (see DoctorWindowFloor).
    private let maximumDayFiles = 7
    /// The surfaces where a capsule is expected on every turn.
    private let capsuleSurfaces: Set<String> = ["chat", "telegram", "ios"]
    /// Below this share of eligible turns, the capsule is not reaching her.
    private let capsuleFloorPercent = 95.0
    /// One felt word above this share of all felt words is vocabulary collapse.
    private let feltWarnPercent = 25.0
    private let feltFailPercent = 40.0
    /// The Sound line that says her phrasing has gone stale.
    private let rutMarker = "same words keep echoing"
    private let rutWarnPercent = 20.0
    private let rutFailPercent = 40.0
    /// Below this many turns the RATES above are reported but not graded. The
    /// measurement window now opens at this build's launch, so a freshly
    /// relaunched app legitimately has a handful of turns — and "the rut line
    /// is on 100% of turns" over two turns is a number, not a finding. Every
    /// figure is still shown; only the verdict waits for enough evidence.
    private let minimumRateTurns = 20
    /// Inner-line variety, judged only once there are enough turns to judge.
    private let innerVarietyFloor = 6
    private let innerVarietyMinimumTurns = 100
    /// A chemical dimension this close to a rail is stuck, not expressive.
    private let pinnedHigh = 0.98
    private let pinnedLow = 0.02
    private let chemistryDimensions = ["agency", "confidence", "coherence", "warmth"]

    public init(
        root: URL = defaultDataRoot(),
        now: @escaping @Sendable () -> Date = { Date() },
        identity: NativeAgentBuildIdentity = .current,
        cacheTTL: TimeInterval = 60
    ) {
        self.root = root
        self.now = now
        self.identity = identity
        self.cache = DoctorScanCache(ttl: cacheTTL)
    }

    public func run() async -> CheckResult {
        let moment = now()
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
        var seenTurns = Set<String>()

        let moment = now()
        let window = DoctorWindowFloor.resolve(root: root, now: moment, identity: identity)
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
            let text = CognitivePreviewReader.text(from: row.payload)

            if flag == true || (capsuleBytes ?? 0) > 0
                || (text?.contains("[CognitiveSubstrate]") ?? false) {
                capsulePresent.insert(key)
            } else if flag == nil && capsuleBytes == nil && text == nil {
                // Nothing in this row can speak to the capsule either way.
                capsuleUnjudged.insert(key)
            }

            guard let text else { return }
            if let felt = CognitivePreviewReader.feltWords(in: text), !felt.isEmpty {
                feltTurns += 1
                for word in felt { feltCounts[word, default: 0] += 1 }
            }
            if let sound = CognitivePreviewReader.line(after: "- Sound: ", in: text) {
                soundTurns += 1
                if sound.localizedCaseInsensitiveContains(rutMarker) { rutTurns += 1 }
            }
            if let inner = CognitivePreviewReader.line(after: "- Inner: ", in: text) {
                innerTurns += 1
                innerLines[inner.lowercased(), default: 0] += 1
            }
        }

        if !summary.unreadableDays.isEmpty {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "\(summary.unreadableDays.count) turn-trace day file(s) exist but could"
                    + " not be read (\(summary.unreadableDays.joined(separator: ", ")))."
                    + " Her subconscious vitals are UNMEASURED \(window.describedAs) — this"
                    + " row is not reporting healthy, it is reporting that it could not look.",
                repair: "Check permissions and encoding on data/turn_traces/<day>.jsonl."
            )
        }

        let chemistry = readChemistry()
        if case .unreadable(let reason) = chemistry {
            return CheckResult(
                id: id, title: title, status: "fail",
                detail: "data/cognition/organism_state.json exists but \(reason)."
                    + " Her chemistry is UNMEASURED, which is a finding about this row's"
                    + " coverage, not a clean reading.",
                repair: "Inspect data/cognition/organism_state.json — the organism writes"
                    + " chemicalState on every save."
            )
        }

        if summary.isEmptyFeed {
            return CheckResult(
                id: id, title: title, status: "warn",
                detail: "UNMEASURED \(window.describedAs) — no turn-trace day files under"
                    + " data/turn_traces. "
                    + chemistryLine(chemistry).sentence,
                repair: nil
            )
        }
        guard !eligibleTurns.isEmpty else {
            return CheckResult(
                id: id, title: title, status: "warn",
                detail: "UNMEASURED \(window.describedAs) — \(summary.daysPresent.count)"
                    + " trace day(s) read and \(summary.matchedRows) context.snapshot row(s)"
                    + " in window, but none on a capsule surface"
                    + " (\(capsuleSurfaces.sorted().joined(separator: "/")))."
                    + " Nothing about her subconscious can be measured. "
                    + chemistryLine(chemistry).sentence,
                repair: nil
            )
        }

        var status = "ok"
        var repairs: [String] = []
        func raise(_ level: String) {
            if level == "fail" { status = "fail" }
            else if level == "warn", status != "fail" { status = "warn" }
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
            if judged < minimumRateTurns {
                parts.append(
                    "below the \(minimumRateTurns)-turn floor, so the rates in this row are"
                        + " MEASURED but NOT judged"
                )
            } else if percent < capsuleFloorPercent {
                raise("fail")
                repairs.append(
                    "The cognitive capsule is missing from"
                        + " \(judged - capsulePresent.count) turn(s). Check the assembly stage"
                        + " that attaches CognitiveSubstrate to the system prompt."
                )
            }
        } else {
            parts.append("capsule attachment UNMEASURED — no eligible turn could be judged")
            raise("warn")
        }
        if !capsuleUnjudged.isEmpty {
            parts.append(
                "\(capsuleUnjudged.count) turn(s) carried neither the capsule flag nor a"
                    + " readable preview and were UNJUDGED rather than counted as missing"
            )
            raise("warn")
        }

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
            if feltTurns < minimumRateTurns {
                // Reported above, deliberately ungraded.
            } else if share > feltFailPercent {
                raise("fail")
                repairs.append(
                    "\"\(top.key)\" carries \(Int(share.rounded()))% of her felt vocabulary."
                        + " The felt lane has collapsed onto one word."
                )
            } else if share > feltWarnPercent {
                raise("warn")
                repairs.append(
                    "\"\(top.key)\" is over \(Int(feltWarnPercent))% of her felt vocabulary —"
                        + " range is narrowing."
                )
            }
        } else {
            parts.append("felt vocabulary UNMEASURED — no turn yielded a readable feeling line")
            raise("warn")
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
            if soundTurns < minimumRateTurns {
                // Reported above, deliberately ungraded.
            } else if percent > rutFailPercent {
                raise("fail")
                repairs.append(
                    "Her own Sound channel says the phrasing is echoing on"
                        + " \(Int(percent.rounded()))% of turns. The rut is the steady state,"
                        + " not an occasional nudge."
                )
            } else if percent > rutWarnPercent {
                raise("warn")
            }
        } else {
            parts.append("Sound line UNMEASURED — no turn yielded a readable Sound line")
            raise("warn")
        }

        // 4. Inner-line variety.
        if innerTurns >= innerVarietyMinimumTurns {
            parts.append("\(innerLines.count) distinct Inner line(s) over \(innerTurns) turn(s)")
            if innerLines.count < innerVarietyFloor {
                raise("warn")
                repairs.append(
                    "Only \(innerLines.count) distinct Inner line(s) across \(innerTurns) turns —"
                        + " the inner voice is repeating rather than responding."
                )
            }
        } else {
            parts.append(
                "\(innerLines.count) distinct Inner line(s) over \(innerTurns) turn(s) —"
                    + " below the \(innerVarietyMinimumTurns)-turn floor, so variety is"
                    + " reported but NOT judged"
            )
        }

        // 5. Organism chemistry.
        let chemLine = chemistryLine(chemistry)
        parts.append(chemLine.sentence)
        if let level = chemLine.level {
            raise(level)
            if let repair = chemLine.repair { repairs.append(repair) }
        }

        if !summary.truncatedDays.isEmpty {
            parts.append(
                "\(summary.truncatedDays.count) day file(s) were tailed to the read budget"
                    + " (\(summary.truncatedDays.joined(separator: ", "))), so earlier turns"
                    + " that day were not scanned"
            )
            raise("warn")
        }
        if summary.malformedLines > 0 {
            parts.append("\(summary.malformedLines) trace line(s) did not parse")
        }

        return CheckResult(
            id: id, title: title, status: status,
            detail: parts.joined(separator: "; ") + ".",
            repair: repairs.isEmpty ? nil : repairs.joined(separator: " ")
        )
    }

    // MARK: - Organism chemistry

    private enum Chemistry {
        case absent
        case unreadable(String)
        case measured([String: Double])
    }

    private func readChemistry() -> Chemistry {
        let path = root
            .appendingPathComponent("cognition", isDirectory: true)
            .appendingPathComponent("organism_state.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return .absent }
        guard let data = try? Data(contentsOf: path) else {
            return .unreadable("could not be read")
        }
        guard let value = try? JSONValue.parse(data), case .object(let object) = value else {
            return .unreadable("did not parse as JSON")
        }
        guard case .object(let state)? = object["chemicalState"] else {
            return .unreadable("carries no chemicalState object")
        }
        var measured: [String: Double] = [:]
        for dimension in chemistryDimensions {
            if let number = state[dimension]?.doubleValue { measured[dimension] = number }
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
    ) -> (sentence: String, level: String?, repair: String?) {
        switch chemistry {
        case .absent:
            return (
                "organism chemistry UNMEASURED — no data/cognition/organism_state.json",
                "warn",
                nil
            )
        case .unreadable(let reason):
            return ("organism chemistry UNREADABLE — \(reason)", "fail", nil)
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
            guard !pinned.isEmpty else { return (sentence, missing.isEmpty ? nil : "warn", nil) }
            let named = pinned
                .map { String(format: "%@=%.3f", $0.key, $0.value) }
                .joined(separator: ", ")
            return (
                sentence + "; PINNED at a rail: \(named)",
                "warn",
                "A chemical dimension parked at 0 or 1 has stopped carrying information."
                    + " Pinned: \(named)."
            )
        }
    }
}

// MARK: - CognitivePreviewReader
//
// `context.snapshot._preview` is a TRUNCATED serialization of the payload, so
// the honest reader tries the structured path and then degrades to text — it
// never pretends a truncated blob is a parsed object.

enum CognitivePreviewReader {
    /// The capsule text for one snapshot row, or nil when the row carries none
    /// this reader can see (which the caller reports as UNJUDGED, not absent).
    static func text(from payload: [String: JSONValue]) -> String? {
        // Structured path: an untruncated preview parses, and its
        // `cognitivePreview` is the capsule verbatim.
        if let raw = payload["_preview"]?.stringValue {
            if let data = raw.data(using: .utf8),
               let parsed = try? JSONValue.parse(data),
               case .object(let object) = parsed,
               case .array(let blocks)? = object["cognitivePreview"] {
                let joined = blocks.compactMap(\.stringValue).joined(separator: "\n")
                if !joined.isEmpty { return joined }
            }
            // Text path: the preview is cut mid-JSON. Unescape it and read the
            // capsule's own labelled lines out of the resulting text.
            let unescaped = unescape(raw)
            return unescaped.isEmpty ? nil : unescaped
        }
        if case .array(let blocks)? = payload["cognitivePreview"] {
            let joined = blocks.compactMap(\.stringValue).joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// Undo one level of JSON string escaping so the capsule's newlines are
    /// real newlines again. Deliberately tolerant: a truncated tail that ends
    /// mid-escape is passed through rather than throwing the whole row away.
    static func unescape(_ raw: String) -> String {
        guard raw.contains("\\") else { return raw }
        var out = String()
        out.reserveCapacity(raw.count)
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            guard character == "\\" else {
                out.append(character)
                index = raw.index(after: index)
                continue
            }
            let next = raw.index(after: index)
            guard next < raw.endIndex else {
                out.append(character)
                break
            }
            switch raw[next] {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{08}")
            case "f": out.append("\u{0C}")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            case "/": out.append("/")
            case "u":
                let start = raw.index(next, offsetBy: 1, limitedBy: raw.endIndex) ?? raw.endIndex
                if let end = raw.index(start, offsetBy: 4, limitedBy: raw.endIndex),
                   let code = UInt32(raw[start..<end], radix: 16),
                   let scalar = Unicode.Scalar(code) {
                    out.append(Character(scalar))
                    index = end
                    continue
                }
                out.append("\\u")
            default:
                out.append(raw[next])
            }
            index = raw.index(next, offsetBy: 1, limitedBy: raw.endIndex) ?? raw.endIndex
        }
        return out
    }

    /// The remainder of the line following `marker`, trimmed. nil when the
    /// marker is not in this (possibly truncated) text.
    static func line(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker) else { return nil }
        let rest = text[range.upperBound...]
        let end = rest.firstIndex(of: "\n") ?? rest.endIndex
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// The comma-separated feeling words on the line under "How you feel:".
    static func feltWords(in text: String) -> [String]? {
        guard let line = line(after: "How you feel:\n\n", in: text)
            ?? line(after: "How you feel:\n", in: text) else { return nil }
        let words = line
            .split(separator: ",")
            .map { feelingWord(in: $0) }
            .filter { !$0.isEmpty }
        return words.isEmpty ? nil : words
    }

    /// One comma-separated entry reduced to the feeling word itself. An entry
    /// may name what the feeling is ABOUT after a dash — "curious — completion
    /// event" is one feeling, "curious", not a distinct vocabulary item per
    /// subject. Keeping the subject inflates apparent emotional range every
    /// time the subject changes.
    static func feelingWord(in entry: some StringProtocol) -> String {
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
