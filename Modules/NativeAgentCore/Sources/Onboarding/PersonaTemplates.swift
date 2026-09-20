import Foundation

// MARK: - Persona template generator

/// Baseline document values for onboarding; the client owns canonical writes.
enum PersonaTemplates {
    static let validTypes: Set<String> = ["female", "male", "ai"]

    /// Mirrors Python `_now_iso` — `datetime.now(timezone.utc).isoformat()`.
    /// Python emits e.g. `2026-06-01T12:34:56.789012+00:00` (microseconds + `+00:00`).
    /// Swift's `ISO8601DateFormatter` emits e.g. `2026-06-01T12:34:56.789Z` —
    /// the only consumer is GROWTH.md's first journal line, which is a
    /// human-readable timestamp. The two formats are not byte-identical but
    /// they are semantically equivalent ISO-8601 UTC strings; tests that pin
    /// the timestamp use the value the generator emits, so the divergence is
    /// captured at the wire boundary, not compared against the Python output.
    static func nowISO() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: Date())
    }

    struct Docs: Sendable, Equatable {
        let soul: String
        let voice: String
        let user: String
        let growth: String
    }

    static func generate(name: String, personaType: String, userName: String) throws -> Docs {
        let ptype = personaType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard validTypes.contains(ptype) else {
            throw OnboardingError.ioFailure("Unknown persona_type '\(personaType)'. Valid: ai, female, male")
        }
        let ts = nowISO()

        func sub(_ tmpl: String) -> String {
            tmpl
                .replacingOccurrences(of: "{{NAME}}", with: name)
                .replacingOccurrences(of: "{{USER_NAME}}", with: userName)
                .replacingOccurrences(of: "{{TIMESTAMP}}", with: ts)
                .replacingOccurrences(of: "{{PERSONA_TYPE}}", with: ptype)
        }

        return Docs(
            soul: sub(soulTemplate),
            voice: sub(voiceTemplate),
            user: sub(userTemplate),
            growth: sub(growthTemplate)
        )
    }

    // MARK: SOUL / VOICE seeds.
    //
    // A fresh install starts blank on purpose: the name header and nothing
    // else. What the person says they want the agent to be is the first thing
    // written under it, by the first conversation. No stance, no instincts,
    // no dos and don'ts seeded on their behalf.

    static let soulTemplate: String = """
# {{NAME}} Soul

"""

    static let voiceTemplate: String = """
# {{NAME}} Voice

"""

    static let userTemplate: String = """
# User

## Working Relationship
- {{NAME}} is working with {{USER_NAME}}.
- {{USER_NAME}}'s preferences, habits, and corrections will be recorded here as the relationship develops.

## Known Preferences
- (Fill in as {{NAME}} learns what {{USER_NAME}} values, how they work, what to watch out for.)

## Corrections to Remember
- (Populated over time from conversation feedback.)

"""

    static let growthTemplate: String = """
# {{NAME}} Growth

This is the living journal for personality corrections, drift notes, and voice improvements.

## Entries
- {{TIMESTAMP}} · baseline · Soul layer initialized for {{PERSONA_TYPE}} persona.

"""
}
