import Foundation
import NativeAgentCore
import PersistenceCore

// MARK: - `second_opinion`: the agent's OWN questions to the decision service
//
// The five advisory lanes ask questions this module wrote, about a turn the
// agent did not choose to have judged. This tool is the other direction: the
// agent composes the state and the typed questions itself, and reads the
// native typed answers back unchanged.
//
// MINIMUM DISCLOSURE IS THE CONTRACT. Exactly the state and the questions the
// call carried go out. Nothing is attached here — no conversation, no persona,
// no turn context, no tool history — and nothing is added on the agent's
// behalf. The state goes through the app's redactor first, and a state over
// the ceiling is REFUSED rather than quietly trimmed, because a silently
// shortened state is a different question than the one that was asked.
//
// NO SIDE EFFECTS. It writes no memory, changes no permission, schedules
// nothing and triggers no follow-up. Its only trace is one log row. The
// tool-call advisory lane skips this name (see `selfManagementToolNames`), so
// a check can never ask for a second opinion about a second opinion.
//
// Lazy, never on the always-on floor, and present only while a key is on file.
enum JevSecondOpinion {

    /// A HARD cap, the same race as the dedup lane's: the losing side is
    /// cancelled, so a slow service cannot go on holding a tool call after its
    /// time is up. Longer than the advisory lanes' 2 s because this call is
    /// the agent's own deliberate wait, not something a turn is made to absorb.
    static let budget: Duration = .seconds(4)
    static let budgetSeconds: TimeInterval = 4

    static let maxQuestions = 24
    static let maxIDCharacters = 48
    static let maxPurposeCharacters = 200
    /// The serialized state ceiling. Over it the call is refused.
    static let maxStateBytes = 24 * 1024

    /// The `insufficient_context` bar. Stated once, reported in the log row so
    /// a reader months later knows which rule produced the outcome rather than
    /// having to guess it back out of the numbers.
    static let choiceConfidenceFloor = 0.35
    static let noulUndecidedRange = 0.4...0.6
    static let insufficientRule =
        "the service answered, but every choice sat below \(choiceConfidenceFloor) confidence "
        + "and every noul landed between \(noulUndecidedRange.lowerBound) and "
        + "\(noulUndecidedRange.upperBound)"

    static let types: Set<String> = ["choice", "noul", "score"]
    /// Ids are stable handles the caller reads answers back by, so they are
    /// restricted to what can be typed the same way twice.
    private static let idCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789_.")

    // MARK: Validated request

    struct Ask: Sendable {
        let state: [String: JSONValue]
        /// The question payloads EXACTLY as given. Nothing here rewrites,
        /// normalizes or completes a question.
        let questions: [String: JSONValue]
        let purpose: String
        var ids: [String] { questions.keys.sorted() }
    }

    /// One clear sentence naming the problem, never a list of every rule.
    static func refusal(_ sentence: String) -> Error {
        AutonomyGateError.toolDenied(reason: "second_opinion: " + sentence)
    }

    static func validate(_ input: [String: JSONValue]) throws -> Ask {
        guard case .object(let state)? = input["state"] else {
            throw refusal("state is required and must be a JSON object holding the inputs you want judged.")
        }
        guard case .object(let questions)? = input["questions"] else {
            throw refusal("questions is required and must be a JSON object of question id to question.")
        }
        guard (1...maxQuestions).contains(questions.count) else {
            throw refusal("questions must hold 1 to \(maxQuestions) entries; this call had \(questions.count).")
        }
        guard case .string(let rawPurpose)? = input["purpose"] else {
            throw refusal("purpose is required: one short line saying what you are deciding. It is logged.")
        }
        let purpose = rawPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !purpose.isEmpty, purpose.count <= maxPurposeCharacters else {
            throw refusal("purpose must be 1 to \(maxPurposeCharacters) characters of plain text.")
        }

        for id in questions.keys.sorted() {
            guard (1...maxIDCharacters).contains(id.count),
                  id.allSatisfy({ idCharacters.contains($0) })
            else {
                throw refusal("question id '\(id)' is not usable: ids are 1 to \(maxIDCharacters) "
                    + "characters of a-z, 0-9, underscore and dot.")
            }
            guard case .object(let question) = questions[id] else {
                throw refusal("question '\(id)' must be an object carrying a type and instructions.")
            }
            guard case .string(let type)? = question["type"], types.contains(type) else {
                throw refusal("question '\(id)' needs a type of choice, noul or score.")
            }
            switch question["instructions"] {
            case .string(let text)? where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
                break
            case .object?:
                break
            case .array(let parts)? where !parts.isEmpty && parts.allSatisfy(isString):
                break
            default:
                throw refusal("question '\(id)' needs instructions: a non-empty string, an object, "
                    + "or a non-empty array of strings.")
            }
            // The typed shapes, enforced HERE. A question the service would
            // reject is a round trip that was never going to answer anything,
            // so it is refused before it leaves the machine.
            switch (type, question["criteria"]) {
            case ("choice", .object(let options)?):
                guard !options.isEmpty else {
                    throw refusal("choice question '\(id)' needs at least one option in criteria.")
                }
                // An option describes itself with prose, with nothing (null),
                // or with a nested object. Anything else is not a description.
                guard options.values.allSatisfy({ isString($0) || isNull($0) || isObject($0) }) else {
                    throw refusal("choice question '\(id)' needs each criteria option to map to a "
                        + "string, null, or an object; one of them maps to something else.")
                }
            case ("choice", _):
                throw refusal("choice question '\(id)' needs a criteria object mapping each option "
                    + "to what picking it would mean.")
            case ("score", .array(let levels)?):
                guard (2...7).contains(levels.count) else {
                    throw refusal("score question '\(id)' needs criteria of 2 to 7 ordered levels; "
                        + "this one had \(levels.count).")
                }
                guard levels.allSatisfy({ isString($0) || isObject($0) }) else {
                    throw refusal("score question '\(id)' needs each criteria level to be a string "
                        + "or an object; one of them is neither.")
                }
            case ("score", _):
                throw refusal("score question '\(id)' needs a criteria array of 2 to 7 ordered "
                    + "level descriptions, weakest first.")
            case ("noul", nil):
                // The ordinary shape: a noul answers 0..1 off its instructions.
                break
            case ("noul", .object(let poles)?):
                // The service also accepts a noul that names its two ends. If
                // criteria is there at all it must be that shape — a noul has
                // no third pole to describe.
                guard Set(poles.keys) == ["true", "false"] else {
                    throw refusal("noul question '\(id)' takes no criteria, or an object with "
                        + "exactly the keys true and false describing each end.")
                }
            case ("noul", _):
                throw refusal("noul question '\(id)' takes no criteria, or an object with exactly "
                    + "the keys true and false describing each end.")
            default:
                break
            }
        }
        return Ask(state: state, questions: questions, purpose: purpose)
    }

    // MARK: The call

    /// What came back, before any reading of it.
    private enum Reply: Sendable {
        case body(Data)
        case status(Int)
        case transport(String)
        case timedOut
    }

    /// Ask, and return the native answers plus a receipt. Throws only on a
    /// refusal (bad call, no key) and on cancellation — every service-side
    /// failure comes back as an `outcome`, because "the service was down" is
    /// an answer the agent needs to read, not an error to swallow.
    static func run(input: [String: JSONValue], dataRoot: URL) async throws -> JSONValue {
        guard JevSettings.isConfigured(dataRoot: dataRoot) else {
            throw refusal("a TypeSafe key is needed. Add it on the Providers page and call this again.")
        }
        guard JevSettings.isEnabled(.secondOpinion, dataRoot: dataRoot) else {
            throw refusal("asking your own questions is switched off in settings; turn it back on to use this.")
        }
        let ask = try validate(input)

        // Redact BEFORE measuring and before sending. `redactValue` is the
        // app's canonical redactor, the same one every log field goes through.
        let given = JSONValue.object(ask.state)
        let sent = NativeAgentSecretRedactor.redactValue(given)
        let redacted = sent != given
        guard let stateBytes = try? sent.serializedData(pretty: false).count else {
            throw refusal("state could not be serialized as JSON.")
        }
        guard stateBytes <= maxStateBytes else {
            throw refusal("state serializes to \(stateBytes) bytes, over the \(maxStateBytes)-byte "
                + "ceiling. Send fewer or smaller inputs — nothing is trimmed for you.")
        }
        // The whole body, and nothing but: model, the redacted state, the
        // questions as given.
        let body = JSONValue.object([
            "model": .string(JevCatalog.model),
            "state": sent,
            "questions": .object(ask.questions),
        ])
        guard let payload = try? body.serializedData(pretty: false) else {
            throw refusal("state and questions could not be serialized as JSON.")
        }
        guard let key = JevSettings.apiKey(dataRoot: dataRoot) else {
            throw refusal("a TypeSafe key is needed. Add it on the Providers page and call this again.")
        }

        let started = Date()
        let reply = try await withBudget { try await send(payload: payload, key: key) }
        let latency = Int((Date().timeIntervalSince(started) * 1000).rounded())

        var outcome = "answered"
        var answers: JSONValue?
        var model: String?
        var usage: JSONValue?
        var failure: String?
        switch reply {
        case .timedOut:
            outcome = "timeout"
            failure = "no reply inside the \(budgetSeconds)s budget"
        case .transport(let text):
            outcome = "transport"
            failure = text
        case .status(let code):
            outcome = "unavailable"
            failure = "http \(code)"
        case .body(let data):
            guard case .object(let root)? = try? JSONValue.parse(data),
                  case .object(let returned)? = root["answers"],
                  Set(returned.keys) == Set(ask.questions.keys)
            else {
                outcome = "malformed"
                failure = "the reply was not an answers object carrying exactly the question ids sent"
                break
            }
            // UNTOUCHED. Whatever shape each typed answer came back in —
            // choice/confidence/probabilities, noul, score/legend/probabilities
            // — is what the agent reads. Nothing is reduced, rounded, renamed
            // or explained here. Checking a shape is not changing it: the
            // original JSON is returned either way, and a reply that failed
            // the check is returned WITH `malformed` rather than withheld, so
            // the agent can see what actually came back.
            answers = .object(returned)
            if case .object? = root["usage"] { usage = root["usage"] }
            // The receipt's model must be the service's own word for what
            // answered. A 2xx with no model string is a reply this tool cannot
            // account for, so it is malformed rather than silently blank.
            guard case .string(let name)? = root["model"], !name.isEmpty else {
                outcome = "malformed"
                failure = "the reply carried no model string"
                break
            }
            model = name
            guard let sound = validated(returned, against: ask.questions) else {
                outcome = "malformed"
                failure = "an answer did not match the type its question asked for, "
                    + "or was missing a field that type requires"
                break
            }
            outcome = isInsufficient(sound) ? "insufficient_context" : "answered"
        }

        var receipt: [String: JSONValue] = [
            "observed_at": .string(stamp()),
            "latency_ms": .int(Int64(latency)),
            // Always false: an oversize state is refused, never shortened. The
            // field is here so a reader never has to assume which it was.
            "truncated": .bool(false),
            "redacted": .bool(redacted),
            "request_bytes": .int(Int64(payload.count)),
        ]
        if let usage { receipt["usage"] = usage }
        // The service's own word for what answered. OMITTED, never blank, when
        // the call brought none back: an empty string here would read as a
        // model with no name rather than as an answer that never arrived.
        if let model { receipt["model"] = .string(model) }

        var result: [String: JSONValue] = [
            "outcome": .string(outcome),
            "receipt": .object(receipt),
        ]
        if outcome == "answered" { result["status"] = .string("ok") }
        if let answers { result["answers"] = answers }
        // The bare cause, never a story about it.
        if answers == nil, let failure { result["error"] = .string(failure) }
        if outcome == "insufficient_context" { result["rule"] = .string(insufficientRule) }

        var extra: [String: JSONValue] = [
            "purpose": .string(ask.purpose),
            "question_ids": .array(ask.ids.map(JSONValue.string)),
            "outcome": .string(outcome),
            "latency_ms": .int(Int64(latency)),
            "truncated": .bool(false),
            "redacted": .bool(redacted),
            "request_bytes": .int(Int64(payload.count)),
        ]
        if let usage { extra["usage"] = usage }
        if let model { extra["model"] = .string(model) }
        if outcome == "insufficient_context" { extra["rule"] = .string(insufficientRule) }
        JevLog.shared.append(
            lane: .secondOpinion,
            summary: ask.purpose,
            answers: nil,
            seconds: Double(latency) / 1000,
            error: failure,
            context: JevLogContext(
                sessionID: LLMCallContext.sessionId,
                turnID: TurnTraceContext.turnId
            ),
            dataRoot: dataRoot,
            extra: extra
        )
        return .object(result)
    }

    /// Race the call against the budget, cancelling the loser. Cancellation is
    /// rethrown: a Stop is not a timeout.
    private static func withBudget(
        _ body: @escaping @Sendable () async throws -> Reply
    ) async throws -> Reply {
        // Where the call's answer lands if it lands at all. The sleeper can win
        // the race by a hair on a call that ALREADY answered, and reporting
        // `timed_out` on an answered question is a claim the agent cannot
        // check: it reads the outcome, not the wire.
        let answered = ReplyBox()
        return try await withThrowingTaskGroup(of: Reply.self) { group in
            group.addTask {
                let reply = try await body()
                answered.store(reply)
                return reply
            }
            group.addTask {
                try await Task.sleep(for: budget)
                return .timedOut
            }
            defer { group.cancelAll() }
            do {
                let first = try await group.next() ?? .timedOut
                if case .timedOut = first, let landed = answered.value { return landed }
                return first
            } catch {
                if JevClient.isCancellation(error) { throw CancellationError() }
                return .transport(String(describing: error).prefix(200).description)
            }
        }
    }

    /// One slot the call's task writes and the racer reads. A lock rather than
    /// an actor so the read costs no suspension on the deciding path.
    private final class ReplyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Reply?
        func store(_ reply: Reply) { lock.lock(); stored = reply; lock.unlock() }
        var value: Reply? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// Throws ONLY on cancellation. Every service-side failure is a `Reply`.
    ///
    /// A Stop reaches this two ways — structured concurrency throws
    /// `CancellationError`, a cancelled `URLSession` task throws
    /// `URLError.cancelled` — and neither is a transport failure. Swallowing
    /// either would let this child win the race and hand the caller an ordinary
    /// result after the turn it belonged to was already stopped.
    private static func send(payload: Data, key: String) async throws -> Reply {
        var request = URLRequest(url: JevCatalog.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = budgetSeconds
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = budgetSeconds
        configuration.timeoutIntervalForResource = budgetSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .status(http.statusCode)
            }
            return .body(data)
        } catch {
            if JevClient.isCancellation(error) { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { return .timedOut }
            return .transport(String(describing: error).prefix(200).description)
        }
    }

    // MARK: Reading the answers

    /// One answer, checked against the type its question asked for.
    ///
    /// Reading a number out of a field the service never sent, or reading a
    /// choice where a score was asked for, is how a wrong answer becomes a
    /// confident one. Each native shape must carry the fields that shape is
    /// defined by, and it must be the shape that was requested.
    struct Checked: Sendable {
        let type: String
        /// The confidence on a choice, the 0..1 reading on a noul. Nil for a
        /// score, which takes no part in the fence rule.
        let reading: Double?
    }

    /// Every answer checked against its own question, or nil if any one of
    /// them fails. Nil means `malformed`; the original JSON is returned
    /// unchanged either way.
    static func validated(
        _ answers: [String: JSONValue], against questions: [String: JSONValue]
    ) -> [Checked]? {
        var checked: [Checked] = []
        for (id, raw) in answers {
            guard case .object(let entry) = raw,
                  case .string(let type)? = entry["type"],
                  case .object(let question)? = questions[id],
                  case .string(let asked)? = question["type"],
                  // The answer must be the type the question asked for. A
                  // service that answers a different one has not answered.
                  type == asked
            else { return nil }
            switch type {
            case "choice":
                guard case .string? = entry["choice"],
                      let confidence = number(entry["confidence"]),
                      case .object? = entry["probabilities"]
                else { return nil }
                checked.append(Checked(type: type, reading: confidence))
            case "noul":
                guard let value = number(entry["noul"]) else { return nil }
                checked.append(Checked(type: type, reading: value))
            case "score":
                guard number(entry["score"]) != nil,
                      entry["legend"] != nil,
                      case .object? = entry["probabilities"]
                else { return nil }
                checked.append(Checked(type: type, reading: nil))
            default:
                return nil
            }
        }
        return checked
    }

    /// `insufficient_context`: the service answered, and every judgment it made
    /// sat on the fence. Choices below the confidence floor AND nouls inside
    /// the undecided band. One decided answer anywhere is enough to call the
    /// whole reply answered.
    ///
    /// Scores do not take part: a score is a level on the caller's own legend,
    /// and a middle level is a real reading, not a shrug. A reply with nothing
    /// but scores is therefore never insufficient.
    ///
    /// Runs only over answers that already passed `validated`, so there is no
    /// missing field to fall through here.
    static func isInsufficient(_ answers: [Checked]) -> Bool {
        var sawJudgment = false
        for answer in answers {
            guard let reading = answer.reading else { continue }
            sawJudgment = true
            switch answer.type {
            case "choice":
                if reading >= choiceConfidenceFloor { return false }
            case "noul":
                if !noulUndecidedRange.contains(reading) { return false }
            default:
                continue
            }
        }
        return sawJudgment
    }

    private static func isString(_ value: JSONValue) -> Bool {
        if case .string = value { return true }
        return false
    }

    private static func isObject(_ value: JSONValue) -> Bool {
        if case .object = value { return true }
        return false
    }

    private static func isNull(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        return false
    }

    private static func number(_ value: JSONValue?) -> Double? {
        switch value {
        case .double(let number): return number
        case .int(let number): return Double(number)
        default: return nil
        }
    }

    private static func stamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }
}
