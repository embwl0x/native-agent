import AuthoredCapabilities
import Foundation
import NativeAgentCore
import PersistenceCore
import PersonaEngine
// Blueprint: | `IdentityAbilityChecks.swift` | PersonaEngineCheck compiles canonical identity documents and the saved onboarded profile without seeding identity; AbilityFilesCheck reports file and seed-install failures |

/// Reads persona health through its canonical engine; Doctor never seeds identity.
public struct PersonaEngineCheck: DoctorCheck {
    public let id: String = "persona_engine"
    public let title: String = "Persona Engine 2.0"
    private let engineProvider: @Sendable () -> SwiftNativePersonaEngine

    public init(root: URL? = nil, engineProvider: (@Sendable () -> SwiftNativePersonaEngine)? = nil) {
        self.engineProvider = engineProvider ?? { root.map { SwiftNativePersonaEngine.isolated(dataRoot: $0) } ?? SwiftNativePersonaEngine() }
    }

    public func run() async -> CheckResult {
        let engine = engineProvider()
        let rootPath = await engine.personaRoot.path
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
                    harm: "Her identity is missing from the conversation.",
                    repair: nil
                )
            }
            // After onboarding, require the saved profile to compile; Doctor never invents missing identity.
            let dataRoot = await engine.dataRootURL
            if FileManager.default.fileExists(
                atPath: dataRoot.appendingPathComponent(".onboarded").path
            ) {
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
                        detail: "Onboarding completed on this Mac but the saved personality profile at \(profileURL.path) is unavailable: \(error.localizedDescription)",
                        harm: "Her configured identity cannot be loaded reliably.",
                        human_action: "Open Trust → Advanced → Backups, select a verified backup containing memory/profile.json, then choose Restore → Restore backup to recover the configured names.",
                        ask: .permission
                    )
                }
            }
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "ok",
                detail: "Persona docs loaded (\(docs.count) entries) from \(rootPath).",
                repair: nil
            )
        } catch {
            return CheckResult(source: rootPath,
                id: id,
                title: title,
                status: "fail",
                detail: "Persona compiler failed: \(error.localizedDescription)",
                harm: "Her identity documents cannot be loaded.",
                repair: nil
            )
        }
    }

}

public struct AbilityFilesCheck: DoctorCheck {
    public let id = "ability_files"
    public let title = "Ability Files"
    private let root: URL
    nonisolated(unsafe) private static var seedFailures: [String: [String]] = [:]

    package static func recordSeedFailures(_ failures: [String], root: URL) {
        AbilityStore.withLock { seedFailures[root.standardizedFileURL.path] = failures }
    }

    public init(root: URL = defaultDataRoot()) { self.root = root }

    public func run() async -> CheckResult {
        let failures = AbilityStore.withLock { Self.seedFailures[root.standardizedFileURL.path] ?? [] }
        if !failures.isEmpty {
            // Launch records "filename: error"; name each failed seed without turning an arbitrary error body into the check's
            // prose.
            let seeds = failures.compactMap { failure in
                failure.range(of: ": ").map { String(failure[..<$0.lowerBound]) }
            }
            return CheckResult(source: "abilities/", id: id, title: title, status: "fail",
                detail: "Bundled seed installation has \(failures.count) failure(s): "
                    + (seeds.isEmpty ? "the bundled ability directory could not be read" : seeds.joined(separator: ", ")) + ".",
                harm: "Bundled parts could not be installed; their capabilities are unavailable.",
                human_action: "Tell the person: NativeAgent could not install the named bundled parts; preserve existing parts and the reported installation errors.", owner: .builder)
        }
        do {
            let files = try AbilityStore(dataRoot: root).files()
            return CheckResult(source: "abilities/", id: id, title: title, status: "ok", detail: "\(files.count) ability files read successfully.")
        } catch {
            // AbilityStore's own no names its file and lever; an unattributed one is the store's.
            let failure = (error as? ToolFailureError).flatMap { $0.owner == nil ? nil : $0 }
                ?? AbilityStore(dataRoot: root).repairFailure(source: root.appendingPathComponent("abilities"), detail: error.localizedDescription)
            return CheckResult(source: failure.owner, nextCall: failure.nextCall,
                id: id, title: title, status: "fail", detail: error.localizedDescription,
                harm: "The affected ability cannot load. A failed migration leaves all original stores untouched.",
                human_action: failure.tap ?? failure.instruction, ask: failure.personDecides ? .permission : nil)
        }
    }
}
