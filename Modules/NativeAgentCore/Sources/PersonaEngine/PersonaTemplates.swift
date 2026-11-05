import Foundation
import NativeAgentShared
import NativeAgentCore
// Blueprint: | `PersonaTemplates.swift` | One genesis template owner shared by onboarding and compilation's named missing-only document creation |

// MARK: - Persona template generator

/// Share creation seeds while leaving writes with onboarding and PersonaEngine.
package enum PersonaTemplates {
    package static let validTypes: Set<String> = ["female", "male", "ai"]

    package struct Docs: Sendable, Equatable {
        package let soul: String
        package let voice: String
        package let user: String
        package let growth: String
        package let agents: String
    }

    package static func generate(name: String, personaType: String, userName: String?) throws -> Docs {
        let ptype = personaType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard validTypes.contains(ptype) || ptype == "custom" else {
            throw PersonaWriteError.invalidInput("Unknown persona_type '\(personaType)'. Valid: ai, female, male, custom")
        }
        let ts = NativeTimestampFormat.fractionalZulu(Date())

        func sub(_ tmpl: String) -> String {
            var text = tmpl
                .replacingOccurrences(of: "{{NAME}}", with: name)
                .replacingOccurrences(of: "{{TIMESTAMP}}", with: ts)
                .replacingOccurrences(of: "{{PERSONA_TYPE}}", with: ptype)
            if let userName { text = text.replacingOccurrences(of: "{{USER_NAME}}", with: userName) }
            return text
        }

        return Docs(
            soul: sub(soulTemplate),
            voice: sub(voiceTemplate),
            user: userName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? sub(userTemplate) : "# User\n",
            growth: sub(growthTemplate),
            agents: SwiftNativePersonaEngine.operatingManualGenesis(name: name)
        )
    }

    // MARK: SOUL / VOICE seeds.
    // Seed only the name header so the person's first conversation shapes identity without imposed stance or instructions.

    package static let soulTemplate: String = """
# {{NAME}} Soul

"""

    package static let voiceTemplate: String = """
# {{NAME}} Voice

"""

    package static let userTemplate: String = """
# User

## Working Relationship
- {{NAME}} is working with {{USER_NAME}}.
- {{USER_NAME}}'s preferences, habits, and corrections will be recorded here as the relationship develops.

## Known Preferences
- (Fill in as {{NAME}} learns what {{USER_NAME}} values, how they work, what to watch out for.)

## Corrections to Remember
- (Populated over time from conversation feedback.)

"""

    package static let growthTemplate: String = """
# {{NAME}} Growth

This is the living journal for personality corrections, drift notes, and voice improvements.

## Entries
- {{TIMESTAMP}} · baseline · Soul layer initialized for {{PERSONA_TYPE}} persona.

"""
}
