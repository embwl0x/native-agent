import Foundation
import NativeAgentCore
import NativeAgentShared
// Blueprint: | `CallBound.swift` | `CallBound`: a call ends when what it waits on is found dead, or at its own declared time; never by the app's clock |

/// No agent is ever stuck, and no call is ended by a number while it is alive. A call is ended when the thing it waits on is seen to be dead
/// or not answering, exactly as Stop ends it, and the agent reads what was found dead. The turn goes on.
///
/// Each call has a watch (`TurnDeadline`, one tree per outermost call). Life anywhere in the tree renews it: a call in it completing, a
/// turn under it producing output, and each sign of life an owner reports (`CallLife`). A person's wait pauses it; a call running inside
/// another holds the other's watch. When the innermost running call has been quiet for `quietSeconds`, the turn's status starts saying what
/// it is waiting on, and what it waits on is asked whether it is alive: alive keeps it waiting however long; dead, gone or not answering
/// ends it; when nothing can answer, the call is not ended but shown, so the person can press Stop.
///
/// A call that itself declares a time (`timeout_seconds`, `timeout`, `wait_seconds`) ends at that time plus `settlementSeconds`: the
/// caller's own word, not the app's number.
public enum CallBound {
    /// Added to a declared execution time or wait, so the work ends on its own terms and reports before the call's own word ends it.
    public static let settlementSeconds: TimeInterval = 30
    /// How long a call may be quiet before what it waits on is asked whether it is alive. Never an end: an answer ends a call, time does not.
    public static let quietSeconds: TimeInterval = 60
    /// How long an owner has to answer "is it alive?" before it counts as not answering.
    public static let pingSeconds: Double = 10

    /// The time the call itself declares, plus settlement; nil when it declares none. Declared times are seconds: `timeout_seconds` on tools,
    /// `timeout` on Mac acts and watch frames, `wait_seconds` on reply observations.
    public static func declaredSeconds(input: [String: JSONValue]) -> TimeInterval? {
        if let declared = number(input["timeout_seconds"]) ?? number(input["timeout"]) { return max(30, min(3600, declared)) + settlementSeconds }
        // A contact reply observation ends at its wait and returns while separately admitted work goes on; its call's end comes after it.
        if let wait = number(input["wait_seconds"]) { return max(0, min(3600, wait)) + settlementSeconds }
        return nil
    }

    private static func number(_ value: JSONValue?) -> TimeInterval? {
        switch value {
        case .int(let whole)?: TimeInterval(whole)
        case .double(let real)? where real.isFinite: real
        default: nil
        }
    }

    /// The call's own declared time passed; `seconds` is that time with its settlement.
    public struct RanOut: Error, LocalizedError, Sendable {
        public let seconds: TimeInterval
        public var errorDescription: String? { "The call used up the time it was given (\(CallBound.said(seconds)))." }
    }

    /// What the call waits on was asked and found dead or not answering.
    public struct FoundDead: Error, LocalizedError, Sendable {
        public let what: String
        public var errorDescription: String? { what }
    }

    /// Run one call under its watch, inside `enclosing` (the turn's enclosing call) else the chain's innermost call, holding that call's watch
    /// while it runs. Ending (found dead, its own declared time) cancels the work as Stop does and releases the caller at once with `FoundDead`
    /// or `RanOut`; the work keeps its own settlement. The work receives the chain its nested calls refine and this call's own watch, to set as
    /// its turn's `enclosingCall`. A call that ends any other way is its caller's life.
    public static func run<T: Sendable>(name: String, declared: TimeInterval?, deadlines: OperationDeadlines, enclosing: TurnDeadline?,
        notice: (@Sendable (String) async -> Void)? = nil,
        _ work: @escaping @Sendable (OperationDeadlines, TurnDeadline?) async throws -> T) async throws -> T {
        let parent = enclosing ?? deadlines.innermostCall
        @Sendable func watched(_ deadlines: OperationDeadlines) async throws -> T {
            try await TurnDeadline.withThrowingDeadline(seconds: quietSeconds, deadlines: deadlines,
                call: CallMark(name: name, notice: notice), parent: parent, onSilence: { await silence($0) }) { nested in
                try await work(nested, nested.innermostCall)
            }
        }
        func bounded() async throws -> T {
            guard let declared else { return try await watched(deadlines) }
            do {
                return try await TurnDeadline.withThrowingDeadline(seconds: declared, clock: .wallClock, deadlines: deadlines) {
                    try await watched($0)
                }
            } catch is TurnDeadline.DeadlineExceeded { throw RanOut(seconds: declared) }
        }
        do {
            let value: T
            if let parent { value = try await parent.holding { try await bounded() } } else { value = try await bounded() }
            parent?.moved()
            return value
        } catch let ended where ended is RanOut || ended is FoundDead {
            throw ended
        } catch {
            parent?.moved()
            throw error
        }
    }

    /// A quiet call asks what it waits on. Any answer of life keeps it waiting; a death with no life ends it; no answer at all shows it: an
    /// owner slow to answer is not seen dead, so it never ends the call.
    static func silence(_ call: TurnDeadline) async -> CallSilence {
        var dead: [String] = []
        var alive: [String] = []
        var person: String?
        for life in call.livesBelow() {
            let answer = (try? await OperationWaitBudget.withDeadline(seconds: pingSeconds) { _ in await life.alive() })
                ?? .unknown
            switch answer {
            case .alive: alive.append(life.what)
            case .dead(let why): dead.append(why)
            case .unknown: continue
            case .waitingOnPerson(let words): person = words
            }
        }
        let minutes = max(1, Int((call.quietFor / 60).rounded()))
        let waited = minutes == 1 ? "a minute" : "\(minutes) minutes"
        if let person {
            await call.notice(person)
            return .keepWaiting
        }
        // Quiet and alive: the turn's status says what it is waiting on; nothing ends it.
        if !alive.isEmpty {
            await call.notice("\(call.name ?? "A call") has been waiting \(waited) on \(alive.joined(separator: ", ")), still running.")
            return .keepWaiting
        }
        if !dead.isEmpty { return .end(FoundDead(what: dead.joined(separator: "; "))) }
        await call.notice("""
            \(call.name ?? "A call") has been waiting \(waited) with nothing that can say whether \
            what it waits on is still alive. Stop ends it.
            """)
        return .keepWaiting
    }

    /// The receipt for a call ended by its own time or by what it waits on being found dead, in the shape of Stop's
    /// `interrupted_after_start`; nil for any other error.
    public static func ended(_ error: any Error, name: String, nextCall: JSONValue = .null) -> JSONValue? {
        let ending: (words: String, reason: String, status: String)
        if let ranOut = error as? RanOut {
            ending = ("\(name) used up the time it was given (\(said(ranOut.seconds))) and was stopped", "ran_out_of_time", "timed_out")
        } else if let dead = error as? FoundDead {
            ending = ("\(name) was stopped because \(dead.what)", "found_dead", "failed")
        } else { return nil }
        let (words, reason, status) = ending
        return .object([
            "status": .string(status),
            "execution": .string("attempted"),
            "error": .string(words + ", so whether it took effect is unknown; check before repeating it."),
            "reason": .string(reason),
            "effects": .string("unknown"),
            "remedy": Repair.reconcile(
                instruction: "Inspect the affected state for any unconfirmed effect before repeating the call or choosing another way.",
                nextCall: nextCall),
        ])
    }

    static func said(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }
}
