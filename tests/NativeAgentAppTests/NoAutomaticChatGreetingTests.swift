import Foundation
import Testing

// Mac chat stays user-initiated on dev installs. The ONE sanctioned exception is
// the public-release first-run welcome (User, 2026-07-11): a fresh download of
// the distributed app greets its new user once, gated on
// NativeAgentPaths.isPublicReleaseBundle. This suite pins that boundary:
// hidden-turn machinery may exist only in the allowlisted welcome/send files,
// and the welcome must carry the public-release gate at both the marker write
// and the fire path.
@Suite("Mac chat greetings are public-release first-run only")
struct NoAutomaticChatGreetingTests {

    /// Files allowed to reference the hidden-turn machinery:
    /// - AppModel+FirstRunWelcome.swift owns the feature (marker + kickoff).
    /// - AppModel+ChatActions.swift defines the hideUserBubble send plumbing.
    /// - ContentView/ChatView/OnboardingWizard only call the self-gating
    ///   trigger/marker methods; they must not touch hideUserBubble directly.
    @Test func hiddenTurnMachineryStaysConfinedToTheWelcomePath() throws {
        let root = try AppSourceScraping.appSourcesRoot()
        let hideUserBubbleAllowlist: Set<String> = [
            "AppModel+FirstRunWelcome.swift",
            "AppModel+ChatActions.swift",
        ]
        let triggerAllowlist: Set<String> = hideUserBubbleAllowlist.union([
            "AppModel.swift", // firstRunGreetingInFlight state
            "ContentView.swift",
            "ChatView.swift",
            "OnboardingWizard.swift",
        ])

        var violations: [String] = []
        for (file, source) in try AppSourceScraping.swiftSourceContents(under: root) {
            if source.contains("hideUserBubble"), !hideUserBubbleAllowlist.contains(file) {
                violations.append("\(file): hideUserBubble outside the welcome send path")
            }
            if source.contains("maybeSendFirstRunGreeting")
                || source.contains("markFirstRunWelcomePending")
                || source.contains(".needs_welcome") {
                if !triggerAllowlist.contains(file) {
                    violations.append("\(file): first-run welcome trigger outside sanctioned surfaces")
                }
            }
        }

        #expect(
            violations.isEmpty,
            "Hidden welcome turns must stay confined to the public-release first-run path: \(violations.sorted())"
        )
    }

    /// The welcome feature must gate on the public-release bundle check at BOTH
    /// seams — the marker write (dev onboarding never arms it) and the fire path
    /// (a stray marker on a dev data root never fires it). Each gate is asserted
    /// inside its own function body with comment lines stripped, so a guard in a
    /// comment — or both guards in one function — cannot satisfy this.
    @Test func welcomeIsGatedOnPublicReleaseBundleAtBothSeams() throws {
        let root = try AppSourceScraping.appSourcesRoot()
        let welcome = root.appendingPathComponent("AppModel+FirstRunWelcome.swift")
        let source = try String(contentsOf: welcome, encoding: .utf8)
        let gate = "guard NativeAgentPaths.isPublicReleaseBundle else { return }"

        for function in ["markFirstRunWelcomePending", "maybeSendFirstRunGreeting"] {
            let body = try #require(
                AppSourceScraping.looseFunctionBody(named: function, in: source),
                "AppModel+FirstRunWelcome.swift must define \(function)()"
            )
            let code = body
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            #expect(
                code.contains(gate),
                "\(function)() must guard on isPublicReleaseBundle in executable code"
            )
        }
    }

    /// A2.5 (W1#9): the welcome kickoff must NOT force "greet by name"
    /// unconditionally — a no-name install would otherwise parrot the "User"
    /// placeholder. Pin that the prompt gates the name on genuinely knowing it
    /// and forbids inventing/placeholder names, so the no-name path reads warmly.
    @Test func welcomeKickoffHandlesTheNoNamePathGracefully() throws {
        let root = try AppSourceScraping.appSourcesRoot()
        let welcome = root.appendingPathComponent("AppModel+FirstRunWelcome.swift")
        let source = try String(contentsOf: welcome, encoding: .utf8)
        let body = try #require(
            AppSourceScraping.looseFunctionBody(named: "maybeSendFirstRunGreeting", in: source),
            "AppModel+FirstRunWelcome.swift must define maybeSendFirstRunGreeting()"
        )
        // The old unconditional instruction is gone.
        #expect(
            !body.contains("Greet them warmly by name,"),
            "kickoff must not force a name unconditionally (no-name installs parrot the placeholder)"
        )
        // The graceful guard is present.
        #expect(body.contains("ONLY if you genuinely know it"))
        #expect(body.contains("never guess, invent, or use a placeholder"))
    }

    // Source-scraping helpers (appSourcesRoot / swiftSourceContents /
    // looseFunctionBody / repositoryRoot) live in the shared AppSourceScraping
    // enum.
}
