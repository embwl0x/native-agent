import Foundation
import PersistenceCore
// Blueprint: | `SkillRunContext.swift` | Explicit authored run options and hand-back refusal |

/// One authored operation's posture, passed through its gated host calls.
public struct OwnedProgramRunOptions: Sendable {
    public var handsBack: Bool
    public init(handsBack: Bool = false) { self.handsBack = handsBack }
}

/// Validation hands requests back without filing a card or opening a macOS permission prompt.
public enum SkillRunContext {
    /// Throwing-only filing points hand requests back instead of filing cards.
    public struct HandBack: Error, LocalizedError {
        public let why: String
        public init(_ why: String) { self.why = why }
        public var errorDescription: String? { SkillRunContext.detail(why) }
    }

    /// Hand-back refusal records why a step would card without running or filing it.
    public static func handBack(_ why: String) -> JSONValue {
        .object(["status": .string("not_run"), "reason": .string("would_card"), "not_run_status": .string("would_card"),
                 "effects": .string("none"), "detail": .string(detail(why))])
    }

    static func detail(_ why: String) -> String {
        "This step would ask the owner (\(why)), and a skill never files a card: it was not run "
            + "and nothing was filed. Do it yourself as its own app call if you still want it."
    }
}
