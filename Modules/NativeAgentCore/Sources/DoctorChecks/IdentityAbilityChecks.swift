import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `IdentityAbilityChecks.swift` | Canonical persona compilation and checked genesis; named profile/ability/seed failures |

/// Use the turn/context compile owner so Doctor cannot invent a different persona-health verdict.
public struct PersonaEngineCheck: RepairingDoctorCheck {
    public let id: String = "persona_engine"
    public let title: String = "Persona Engine 2.0"
    private let engineProvider: @Sendable () -> SwiftNativePersonaEngine

    public init(root: URL? = nil, engineProvider: (@Sendable () -> SwiftNativePersonaEngine)? = nil) {
        self.engineProvider = engineProvider ?? { root.map { SwiftNativePersonaEngine.isolated(dataRoot: $0) } ?? SwiftNativePersonaEngine() }
    }

    public func run(repair: Bool) async -> CheckResult {
        let engine = engineProvider()
        let rootPath = await engine.personaRoot.path
        let dataRoot = await engine.dataRootURL
        // Before setup finishes there is no agent and so no persona: its absence is not a fault, and setup writes it.
        guard NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: dataRoot) else {
            return CheckResult(source: rootPath, id: id, title: title, status: "not needed",
                detail: "Waiting for setup to finish; it writes the agent's persona.")
        }
        do {
            let docs = try await PersonaCompiler(engine: engine).compile(
                surface: "chat", personaOverride: PersonaSelection.current()
            ).activeDocs
            let hasSoul = docs["SOUL"] != nil
            if !hasSoul {
                return CheckResult(source: rootPath + "/SOUL.md",
                    id: id,
                    title: title,
                    status: "fail",
                    detail: "Persona compiler failed: SOUL.md is absent from \(rootPath)",
                    harm: "The agent's identity is missing from the conversation.",
                    repair: nil
                )
            }
            // Setup finished: require the saved profile to compile; Doctor never invents missing identity.
            let profileURL = dataRoot
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("profile.json")
            do {
                guard try profileURL.checkResourceIsReachable() else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                _ = try PersonaCompiler.compileProfile(dataRoot: dataRoot)
            } catch {
                return CheckResult(source: profileURL.path,
                    id: id,
                    title: title,
                    status: "fail",
                    detail: """
                        Onboarding completed on this Mac but the saved personality profile at \(profileURL.path) is unavailable: \
                        \(error.localizedDescription)
                        """,
                    harm: "The agent's configured identity cannot be loaded reliably.",
                    human_action: """
                        Open Trust → Advanced → Backups, select a verified backup containing memory/profile.json, then choose Restore → Restore \
                        backup to recover the configured names.
                        """,
                    ask: .permission
                )
            }
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "ok",
                detail: "Persona docs loaded (\(docs.count) entries) from \(rootPath)."
            )
        } catch {
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "fail",
                detail: "Persona compiler failed: \(error.localizedDescription)",
                harm: "The agent's identity documents cannot be loaded.",
                repair: nil,
                human_action: """
                    Preserve existing persona bytes and restore or repair the named unreadable document. Compilation creates checked-missing \
                    SOUL, VOICE, USER, GROWTH or AGENTS from their shared onboarding templates only after completed onboarding and a checked \
                    profile.
                    """
            )
        }
    }

}

public struct AbilityFilesCheck: DoctorCheck {
    public let id = "ability_files"
    public let title = "Ability Files"
    private let root: URL
    private struct SeedInstallation: Sendable {
        let failures: [String]
        let current: Int
        let prepared: Int
    }
    nonisolated(unsafe) private static var seedInstallations: [String: SeedInstallation] = [:]

    package static func recordSeedInstallation(failures: [String], current: Int, prepared: Int, root: URL) {
        AbilityStore.withLock {
            seedInstallations[root.standardizedFileURL.path] = SeedInstallation(failures: failures, current: current, prepared: prepared)
        }
    }

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run() async -> CheckResult {
        let installation = AbilityStore.withLock { Self.seedInstallations[root.standardizedFileURL.path] }
        if let failures = installation?.failures, !failures.isEmpty {
            // Name each failed seed from filename: error; arbitrary error bodies cannot become Doctor prose.
            let seeds = failures.compactMap { failure in
                failure.range(of: ": ").map { String(failure[..<$0.lowerBound]) }
            }
            return CheckResult(source: "abilities/", id: id, title: title, status: "fail",
                detail: "Bundled seed installation has \(failures.count) failure(s): "
                    + (seeds.isEmpty ? "the bundled ability directory could not be read" : seeds.joined(separator: ", ")) + ".",
                harm: "Bundled parts could not be installed; their capabilities are unavailable.",
                human_action: """
                    Tell the person: NativeAgent could not install the named bundled parts; preserve existing parts and the reported \
                    installation errors.
                    """, owner: .builder)
        }
        do {
            let inventory = try AbilityStore(dataRoot: root).inventory()
            // Each damaged file is its own failure, named with its own lever; the rest still load.
            if let first = inventory.damaged.first?.failure {
                return CheckResult(source: first.owner, nextCall: first.nextCall, id: id, title: title, status: "fail",
                    detail: inventory.damaged.map { $0.failure.localizedDescription }.joined(separator: " ")
                        + " \(inventory.files.count) other ability files read successfully.",
                    harm: "The named abilities cannot load; every other ability is unaffected.",
                    human_action: first.tap ?? first.instruction, ask: first.personDecides ? .permission : nil)
            }
            let files = inventory.files
            let seeds = installation.map {
                " Bundled seeds this launch: \($0.current) current (admission skipped), \($0.prepared) admissions prepared."
            } ?? " Bundled seed installation has not been observed this launch."
            return CheckResult(source: "abilities/", id: id, title: title, status: "ok", detail: "\(files.count) ability files read successfully." + seeds)
        } catch {
            // Preserve the store owner's attributed file and remedy; unattributed failure belongs to the store.
            let failure = (error as? ToolFailureError).flatMap { $0.owner == nil ? nil : $0 }
                ?? AbilityStore(dataRoot: root).repairFailure(source: root.appendingPathComponent("abilities"), detail: error.localizedDescription)
            return CheckResult(source: failure.owner, nextCall: failure.nextCall,
                id: id, title: title, status: "fail", detail: error.localizedDescription,
                harm: "The affected ability cannot load. A failed migration leaves all original stores untouched.",
                human_action: failure.tap ?? failure.instruction, ask: failure.personDecides ? .permission : nil)
        }
    }
}
