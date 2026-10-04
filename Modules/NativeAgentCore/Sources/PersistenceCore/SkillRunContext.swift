import Foundation

/// A skill run's calls (`skill.run`): nothing it does files a card for User,
/// an approval or an inline one, or opens a macOS permission prompt. Each
/// filing point checks this and hands the step back to her instead.
public enum SkillRunContext {
    @TaskLocal public static var handsBack = false

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
        "This step would ask User (\(why)), and a skill never files a card: it was not run "
            + "and nothing was filed. Do it yourself as its own app call if you still want it."
    }
}
