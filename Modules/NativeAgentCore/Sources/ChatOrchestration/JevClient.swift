import Foundation
import PersistenceCore

// MARK: - Jev: the decision service behind the advisory triage lanes
//
// Jev is not a chat provider and takes no part in routing. It is a small
// decision service: it is handed a JSON state and a set of typed questions,
// and it answers with choices, 0..1 nouls and scores. Everything it says is a
// HINT. No lane here grants, denies, blocks, rewrites or deletes anything.
//
// The endpoint and the model id live in `JevCatalog` and nowhere else.
//
// Fails open, always: no key, a timeout, a non-200, malformed JSON — every
// path returns nil and the ordinary turn runs exactly as it would without any
// of this. Existing safeguards are untouched; Jev simply disappears.

/// Endpoint, model id and the version string stamped into every log row.
/// The only place either literal appears.
enum JevCatalog {
    static let endpoint = URL(string: "https://api.typesafe.ai/v1/systemone")!
    static let model = "jev-latest"
    /// Bumped whenever the wording of a lane's questions changes, so a log
    /// read months from now knows which prompt produced a row.
    static let promptVersion = "jev-questions-6"
    /// The backticked path a question points at when it reads the agent's own
    /// profile, and the one line saying what that value is.
    ///
    /// A request carries only the context its questions need. Both of these,
    /// and the profile itself, ride a request ONLY when that request holds a
    /// question that declares it reads the profile — and only when the agent
    /// under that root has written one. Every other question, and every
    /// request made entirely of them, is exactly what it was without a profile.
    static let profilePath = "`agent_profile`"
    static let profileFocus = "`agent_profile` describes the agent being helped; "
        + "respect what it asks for and what it asks to be left alone."
    /// One call must never hold a turn up.
    static let timeout: TimeInterval = 2.0
}

// MARK: - Questions

/// What one question asks, and where it looks.
///
/// The guide asks for structure rather than dense prose: the question itself,
/// the backticked path or paths it reads (`inspect` for one, `compare` for
/// several weighed against each other) and a `focus` naming what to judge. A
/// question short and unambiguous enough to need none of that stays a plain
/// string and is emitted as one, so a call site that writes a string literal
/// asks exactly the question it asked before.
struct JevInstructions: Sendable, ExpressibleByStringLiteral {
    var question: String
    var inspect: String?
    var compare: [String]
    var focus: String?
    /// This question reads the agent's own profile. Only a question that says
    /// so gets the path and the profile; see `JevCatalog.profilePath`.
    var readsAgentProfile: Bool

    init(stringLiteral value: String) { self.init(question: value) }

    init(
        question: String,
        inspect: String? = nil,
        compare: [String] = [],
        focus: String? = nil,
        readsAgentProfile: Bool = false
    ) {
        self.question = question
        self.inspect = inspect
        self.compare = compare
        self.focus = focus
        self.readsAgentProfile = readsAgentProfile
    }

    /// The same instructions with the profile folded into what they read. A
    /// lone `inspect` becomes the first entry of `compare`, because the
    /// question now weighs two things rather than reading one, and the
    /// question's own focus keeps its place ahead of the profile's.
    func readingAgentProfile() -> JevInstructions {
        var updated = self
        if let inspect = updated.inspect {
            updated.compare.insert(inspect, at: 0)
            updated.inspect = nil
        }
        updated.compare.append(JevCatalog.profilePath)
        updated.focus = [updated.focus, JevCatalog.profileFocus]
            .compactMap { $0 }
            .joined(separator: " ")
        return updated
    }

    var payload: JSONValue {
        guard inspect != nil || !compare.isEmpty || focus != nil else { return .string(question) }
        var out: [String: JSONValue] = ["question": .string(question)]
        if let inspect { out["inspect"] = .string(inspect) }
        if !compare.isEmpty { out["compare"] = .array(compare.map(JSONValue.string)) }
        if let focus { out["focus"] = .string(focus) }
        return .object(out)
    }
}

/// One side of a decision boundary: a Choice option, or one end of a Noul.
///
/// A one-line description stays a string. When two sides are easy to confuse,
/// each says what it covers, what belongs to the other side instead, and a few
/// representative inputs — the same field names on both sides, so they can be
/// compared directly.
struct JevOption: Sendable, ExpressibleByStringLiteral {
    var what: String
    var notFor: String?
    var examples: [String]

    init(stringLiteral value: String) { self.init(what: value) }

    init(what: String, notFor: String? = nil, examples: [String] = []) {
        self.what = what
        self.notFor = notFor
        self.examples = examples
    }

    var payload: JSONValue {
        guard notFor != nil || !examples.isEmpty else { return .string(what) }
        var out: [String: JSONValue] = ["what": .string(what)]
        if let notFor { out["not_for"] = .string(notFor) }
        if !examples.isEmpty { out["examples"] = .array(examples.map(JSONValue.string)) }
        return .object(out)
    }
}

/// What a yes and a no mean, for a Noul whose boundary is subtle enough to
/// need saying. A Noul has exactly two ends and no third.
struct JevNoulCriteria: Sendable {
    var yes: JevOption
    var no: JevOption

    init(yes: JevOption, no: JevOption) {
        self.yes = yes
        self.no = no
    }

    var payload: JSONValue { .object(["true": yes.payload, "false": no.payload]) }
}

/// One typed question. `choice` carries an option→description map, `noul`
/// answers 0..1 and optionally says what its two ends mean, `score` carries
/// ordered level descriptions.
enum JevQuestion: Sendable {
    case choice(instructions: JevInstructions, criteria: [String: JevOption?])
    case noul(instructions: JevInstructions, criteria: JevNoulCriteria? = nil)
    case score(instructions: JevInstructions, levels: [String])

    var instructions: JevInstructions {
        switch self {
        case let .choice(instructions, _): return instructions
        case let .noul(instructions, _): return instructions
        case let .score(instructions, _): return instructions
        }
    }

    /// The same question pointed at the agent's profile as well. A question
    /// that does not read the profile comes back untouched.
    func readingAgentProfile() -> JevQuestion {
        guard instructions.readsAgentProfile else { return self }
        let updated = instructions.readingAgentProfile()
        switch self {
        case let .choice(_, criteria): return .choice(instructions: updated, criteria: criteria)
        case let .noul(_, criteria): return .noul(instructions: updated, criteria: criteria)
        case let .score(_, levels): return .score(instructions: updated, levels: levels)
        }
    }

    var payload: JSONValue {
        switch self {
        case let .choice(instructions, criteria):
            var options: [String: JSONValue] = [:]
            for (key, value) in criteria { options[key] = value?.payload ?? .null }
            return .object([
                "type": .string("choice"),
                "instructions": instructions.payload,
                "criteria": .object(options),
            ])
        case let .noul(instructions, criteria):
            var out: [String: JSONValue] = [
                "type": .string("noul"),
                "instructions": instructions.payload,
            ]
            if let criteria { out["criteria"] = criteria.payload }
            return .object(out)
        case let .score(instructions, levels):
            return .object([
                "type": .string("score"),
                "instructions": instructions.payload,
                "criteria": .array(levels.map(JSONValue.string)),
            ])
        }
    }
}

// MARK: - Answers

/// The answers for one call, already reduced to the three shapes the lanes
/// read. A missing id simply reads as absent — no lane ever forces a default.
struct JevAnswers: Sendable {
    struct Choice: Sendable {
        let choice: String
        let confidence: Double
    }

    private let choices: [String: Choice]
    private let nouls: [String: Double]
    private let scores: [String: Double]
    private let scoreConfidences: [String: Double]
    let distributions: [String: [String: Double]]
    /// The same reduction, ready for the log's `answers` field.
    let flattened: [String: String]
    let modelVersion: String
    let inputTokens: Int
    let outputTokens: Int

    init?(response: JSONValue, questions: [String: JevQuestion]? = nil) {
        guard case .object(let root) = response,
              case .object(let answers)? = root["answers"] else { return nil }
        var choices: [String: Choice] = [:]
        var nouls: [String: Double] = [:]
        var scores: [String: Double] = [:]
        var scoreConfidences: [String: Double] = [:]
        var distributions: [String: [String: Double]] = [:]
        var flattened: [String: String] = [:]
        if let questions {
            guard Set(answers.keys) == Set(questions.keys) else { return nil }
        }
        for (id, raw) in answers {
            guard case .object(let entry) = raw,
                  case .string(let kind)? = entry["type"] else { return nil }
            if let question = questions?[id] {
                guard case .object(let shape) = question.payload, shape["type"] == entry["type"] else { return nil }
            }
            switch kind {
            case "choice":
                guard case .string(let pick)? = entry["choice"],
                      let confidence = Self.unit(entry["confidence"]),
                      let distribution = Self.distribution(entry["probabilities"]), distribution[pick] != nil
                else { return nil }
                if case .choice(_, let criteria)? = questions?[id], Set(distribution.keys) != Set(criteria.keys) { return nil }
                choices[id] = Choice(choice: pick, confidence: confidence)
                distributions[id] = distribution
                flattened[id] = "\(pick) \(JevAnswers.round2(confidence))"
            case "noul":
                guard let value = Self.unit(entry["noul"]) else { return nil }
                nouls[id] = value
                flattened[id] = JevAnswers.round2(value)
            case "score":
                guard let value = Self.number(entry["score"]), value.isFinite, value >= 0,
                      let confidence = Self.unit(entry["confidence"]),
                      let distribution = Self.distribution(entry["probabilities"])
                else { return nil }
                if case .score(_, let levels)? = questions?[id] {
                    guard value <= Double(levels.count - 1),
                          Set(distribution.keys) == Set(levels.indices.map(String.init)) else { return nil }
                }
                scores[id] = value
                scoreConfidences[id] = confidence
                distributions[id] = distribution
                flattened[id] = JevAnswers.round2(value)
            default:
                return nil
            }
        }
        self.choices = choices
        self.nouls = nouls
        self.scores = scores
        self.scoreConfidences = scoreConfidences
        self.distributions = distributions
        self.flattened = JevAnswers.folding(flattened)
        if case .string(let model)? = root["model"] { self.modelVersion = model } else { self.modelVersion = "" }
        var usage: [String: JSONValue] = [:]
        if case .object(let fields)? = root["usage"] { usage = fields }
        self.inputTokens = max(0, Int(exactly: JevAnswers.number(usage["input_tokens"]) ?? 0) ?? 0)
        self.outputTokens = max(0, Int(exactly: JevAnswers.number(usage["output_tokens"]) ?? 0) ?? 0)
    }

    /// Fold per-option answers into one log field each.
    ///
    /// A lane that asks one noul PER OPTION rather than one choice over all of
    /// them — which is what actually works, a single choice folds to `none` —
    /// would otherwise write one log field per option: twenty on every
    /// pre-turn row. Any id of the form `group.option` is collapsed into a
    /// single `group` field listing its options, strongest first.
    ///
    /// Only options at 0.30 or better are listed, because the point of the
    /// field is what the lane nearly acted on. If nothing reaches that, the
    /// single strongest is listed anyway — a row that says `none 0.02` is
    /// evidence, and a blank one is not. Capped so a wide lane stays readable.
    static func folding(_ flattened: [String: String]) -> [String: String] {
        let listCap = 6
        var out: [String: String] = [:]
        var groups: [String: [(option: String, text: String, value: Double)]] = [:]
        for (id, text) in flattened {
            guard let dot = id.firstIndex(of: "."), dot != id.startIndex else {
                out[id] = text
                continue
            }
            let group = String(id[id.startIndex..<dot])
            let option = String(id[id.index(after: dot)...])
            groups[group, default: []].append((option, text, Double(text) ?? 0))
        }
        for (group, members) in groups {
            let ranked = members.sorted {
                $0.value == $1.value ? $0.option < $1.option : $0.value > $1.value
            }
            var listed = ranked.filter { $0.value >= 0.30 }
            if listed.isEmpty, let top = ranked.first { listed = [top] }
            out[group] = listed.prefix(listCap)
                .map { "\($0.option) \($0.text)" }
                .joined(separator: ", ")
        }
        return out
    }

    /// The service answers numbers as either JSON ints or doubles.
    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    func choice(_ id: String) -> Choice? { choices[id] }
    func noul(_ id: String) -> Double? { nouls[id] }
    func score(_ id: String) -> Double? { scores[id] }
    func scoreConfidence(_ id: String) -> Double? { scoreConfidences[id] }

    private static func unit(_ value: JSONValue?) -> Double? {
        guard let number = number(value), number.isFinite, (0...1).contains(number) else { return nil }
        return number
    }

    private static func distribution(_ value: JSONValue?) -> [String: Double]? {
        guard case .object(let object)? = value, !object.isEmpty else { return nil }
        var values: [String: Double] = [:]
        for (key, raw) in object {
            guard let value = unit(raw) else { return nil }
            values[key] = value
        }
        guard abs(values.values.reduce(0, +) - 1) < 0.02 else { return nil }
        return values
    }

    static func round2(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

// MARK: - Client

/// Plain HTTP against the decision service. One request, one short timeout,
/// one log row. Never throws to its caller.
actor JevClient {
    static let shared = JevClient()

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = JevCatalog.timeout
        configuration.timeoutIntervalForResource = JevCatalog.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    /// Ask one lane's questions. Returns nil on every failure, and on a missing
    /// key returns nil without touching the network or the log.
    ///
    /// - Parameters:
    ///   - lane: the lane id, written straight into the log row.
    ///   - state: the minimum data for this check — the message, the last
    ///     exchange, a tool call's name and truncated input, family purposes.
    ///     Never credentials, never a whole transcript, never persona files.
    ///   - summary: the 160-char summary the log row carries.
    ///   - dataRoot: the root the caller was built with. The key and the log
    ///     are resolved under it, never under the process default.
    ///
    /// Fails open by returning nil — EXCEPT on cancellation, which is rethrown
    /// so a Stop stops the caller too instead of being read as "no opinion".
    func ask(
        lane: JevLane,
        state: [String: JSONValue],
        questions: [String: JevQuestion],
        summary: String,
        dataRoot: URL,
        context: JevLogContext = JevLogContext()
    ) async throws -> JevAnswers? {
        try Task.checkCancellation()
        guard let key = JevSettings.apiKey(dataRoot: dataRoot), !key.isEmpty else { return nil }
        let started = Date()
        // A request carries only the context its questions need. The agent's
        // own profile therefore rides this request only when one of its
        // questions declares that it reads the profile — and the questions
        // that do point at it by path rather than carrying a sentence about
        // it. A request whose questions all ignore the profile, and every
        // request under a root with no profile, is byte for byte what it was.
        var state = state
        var questions = questions
        if questions.values.contains(where: { $0.instructions.readsAgentProfile }),
           let profile = JevSettings.agentProfile(dataRoot: dataRoot) {
            state["agent_profile"] = .string(profile)
            questions = questions.mapValues { $0.readingAgentProfile() }
        }
        let body = JSONValue.object([
            "model": .string(JevCatalog.model),
            "state": NativeAgentSecretRedactor.redactValue(.object(state)),
            "questions": .object(questions.mapValues { $0.payload }),
        ])

        var request = URLRequest(url: JevCatalog.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = JevCatalog.timeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let encoded = try body.serialize(pretty: false)
            request.httpBody = Data(encoded.replacingOccurrences(of: key, with: "[REDACTED]").utf8)
        } catch {
            JevLog.shared.append(
                lane: lane, summary: summary, answers: nil, seconds: 0,
                error: "encode", context: context, dataRoot: dataRoot
            )
            return nil
        }

        do {
            let (data, response) = try await session.data(for: request)
            let seconds = Date().timeIntervalSince(started)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                JevLog.shared.append(
                    lane: lane, summary: summary, answers: nil, seconds: seconds,
                    error: "http \(http.statusCode)", context: context, dataRoot: dataRoot
                )
                return nil
            }
            guard
                let object = try? JSONValue.parse(data),
                let answers = JevAnswers(response: object, questions: questions)
            else {
                JevLog.shared.append(
                    lane: lane, summary: summary, answers: nil, seconds: seconds,
                    error: "decode", context: context, dataRoot: dataRoot
                )
                return nil
            }
            JevLog.shared.append(
                lane: lane, summary: summary, answers: answers, seconds: seconds,
                error: nil, context: context, dataRoot: dataRoot
            )
            return answers
        } catch {
            // A Stop is not a failed check. Cancellation is rethrown so the
            // caller's own cancellation handling runs — in particular the save
            // path must never carry on into `store` after a Stop.
            if Self.isCancellation(error) { throw CancellationError() }
            let seconds = Date().timeIntervalSince(started)
            JevLog.shared.append(
                lane: lane, summary: summary, answers: nil, seconds: seconds,
                error: String(describing: error).prefix(200).description,
                context: context, dataRoot: dataRoot
            )
            return nil
        }
    }

    /// Cancellation reaches this actor two ways: structured concurrency throws
    /// `CancellationError`, and a cancelled `URLSession` task throws
    /// `URLError.cancelled`. Both mean Stop, neither means "no opinion".
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as? URLError)?.code == .cancelled { return true }
        return Task.isCancelled
    }
}

// MARK: - Truncation helper

extension String {
    /// Truncate for the minimum-data rule: no check ever carries more of a
    /// field than it needs to judge it.
    func jevTruncated(_ limit: Int) -> String {
        let safe = NativeAgentSecretRedactor.redactText(self)
        guard safe.count > limit else { return safe }
        // Preserve end-of-message constraints as well as the opening ask.
        let tail = max(0, limit / 3)
        return String(safe.prefix(max(0, limit - tail))) + " [excerpt omitted] " + String(safe.suffix(tail))
    }
}
