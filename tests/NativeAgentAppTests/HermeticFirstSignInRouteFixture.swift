import Foundation

/// The provider files a FIRST SIGN-IN writes — and nothing more.
///
/// User, 2026-09-13: every activity resolves through its Providers group, there
/// are no per-surface seeds, and there is no literal fallback model anywhere.
/// A surface with no choice refuses. So a hermetic root that wants reflection to
/// route has exactly one thing to be: an install with a connected account and a
/// Chat choice. That is what `AppModel.adoptProviderForBlankSurfaces` writes on
/// first adoption (AppModel+ProvidersAuth.swift) — one credential file, one
/// `providers/active.json` chat assignment, one `providers/surfaces.json` chat
/// pick. Memory and mind inherits it ("Same as Chat"), so
/// `cognition_reflection` resolves without anything being written for it.
///
/// Seeding `cognition_reflection` directly would NOT be a substitute: a group's
/// tuple routes only when it is unanimous across every member, so one pinned
/// member alone still falls back to Chat. It would also be exactly the
/// per-surface seed the rework deleted.
enum HermeticFirstSignInRoute {
    /// A real route id and a real row it offers, so the saved pick is live
    /// catalog data rather than a retired id (which would unset the surface).
    static let providerID = "anthropic"
    static let model = "claude-opus-4-8"

    /// Writes the first-sign-in provider files into `root`.
    static func write(into root: URL) throws {
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        try Data(#"{"api_key":"fixture-not-a-real-key"}"#.utf8)
            .write(to: providers.appendingPathComponent("\(providerID).json"), options: .atomic)
        try Data(#"{"chat":"\#(providerID)"}"#.utf8)
            .write(to: providers.appendingPathComponent("active.json"), options: .atomic)
        try Data(#"{"chat":{"model":"\#(model)","reasoningEffort":"high"}}"#.utf8)
            .write(to: providers.appendingPathComponent("surfaces.json"), options: .atomic)
    }
}
