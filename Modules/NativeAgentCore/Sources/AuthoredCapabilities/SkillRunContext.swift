import Foundation
import PersistenceCore
// Blueprint: | `SkillRunContext.swift` | Singular authored-run TaskLocals, part identity, file-write notifications, a wake's model admitted at its first thought, and hand-back refusal contract |

/// Authored calls carry their part's identity. Validation hands requests back
/// without filing a card or opening a macOS permission prompt.
public enum SkillRunContext {
    @TaskLocal public static var handsBack = false
    @TaskLocal public static var partID: String?
    /// The authored ability whose own code made this call (an ability, tool or
    /// skill), never a script, sense or turn: what may act as that ability.
    @TaskLocal public static var ability: String?
    @TaskLocal public static var input: JSONValue?
    @TaskLocal public static var requester: String?
    @TaskLocal public static var hostCallID: UUID?
    /// Told each file the running part itself wrote, right after the write,
    /// so its watch can tell that write from anyone else's.
    @TaskLocal public static var wrote: (@Sendable (URL) -> Void)?
    /// Admits the run's model around its `model.call`, when it first thinks,
    /// so a run that never thinks needs no model.
    @TaskLocal public static var admitModel: (@Sendable (@Sendable () async throws -> JSONValue) async throws -> JSONValue)?

    /// What a filing point that can only throw throws inside a skill run.
    public struct HandBack: Error, LocalizedError {
        public let why: String
        public init(_ why: String) { self.why = why }
        public var errorDescription: String? { SkillRunContext.detail(why) }
    }

    /// The step handed back: not run, nothing filed, and why it would have carded.
    public static func handBack(_ why: String) -> JSONValue {
        .object(["status": .string("not_run"), "reason": .string("would_card"), "not_run_status": .string("would_card"),
                 "effects": .string("none"), "detail": .string(detail(why))])
    }

    static func detail(_ why: String) -> String {
        "This step would ask the owner (\(why)), and a skill never files a card: it was not run "
            + "and nothing was filed. Do it yourself as its own app call if you still want it."
    }
}
