import Foundation
import Testing
@testable import NativeAgentApp

private func makePublicSafetyRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NativeAgentPublicSafety-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeIsolatedDefaults() throws -> (UserDefaults, String) {
    let suiteName = "NativeAgentOrganismMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

@Test func publicSafeModeCanBeForcedForCleanRoomChecks() {
    #expect(NativeAgentPublicSafety.isPublicSafeMode(environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1"]))
    #expect(!NativeAgentPublicSafety.isPublicSafeMode(environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "0"]))
}

@Test func publicPreOnboardingLaunchForcesNeutralOrganism() throws {
    let root = try makePublicSafetyRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    let config = NativeCognitionRuntime.organismConfigurationForLaunch(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1", "NATIVE_AGENT_ORGANISM_KERNEL_ENABLED": "1"],
        storedEnabled: true
    )

    #expect(config.enabled == false)
}

@Test func publicPostOnboardingLaunchAllowsStoredOrganismToggle() throws {
    let root = try makePublicSafetyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try "completed_at=2026-07-07T00:00:00Z\n".write(
        to: root.appendingPathComponent(".onboarded"),
        atomically: true,
        encoding: .utf8
    )

    let config = NativeCognitionRuntime.organismConfigurationForLaunch(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1"],
        storedEnabled: true
    )

    #expect(config.enabled)
}

@Test func publicSafeOnboardingCompletionAcceptsCompleteLegacyInstall() throws {
    let root = try makePublicSafetyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    let persona = root.appendingPathComponent("persona", isDirectory: true)
    try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
    try #"{"name":"Nova","userName":"User"}"#.write(
        to: memory.appendingPathComponent("profile.json"),
        atomically: true,
        encoding: .utf8
    )
    for name in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"] {
        try "# \(name)\nConfigured.\n".write(
            to: persona.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }

    #expect(NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: root))
    #expect(!NativeAgentPublicSafety.shouldForceNeutralOrganism(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1"]
    ))
}

@Test func profileCommittedBeforeSentinelRemainsPreOnboardingWhileTransactionIsPending() throws {
    let root = try makePublicSafetyRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let memory = root.appendingPathComponent("memory", isDirectory: true)
    let persona = root.appendingPathComponent("persona", isDirectory: true)
    let onboarding = root.appendingPathComponent("onboarding", isDirectory: true)
    for directory in [memory, persona, onboarding] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try #"{"name":"Nova","userName":"User"}"#.write(
        to: memory.appendingPathComponent("profile.json"),
        atomically: true,
        encoding: .utf8
    )
    for name in ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"] {
        try "# \(name)\nConfigured.\n".write(
            to: persona.appendingPathComponent(name),
            atomically: true,
            encoding: .utf8
        )
    }
    try "pending".write(
        to: onboarding.appendingPathComponent("pending-completion.json"),
        atomically: true,
        encoding: .utf8
    )

    #expect(!NativeAgentPublicSafety.hasCompletedOnboarding(dataRoot: root))
    #expect(NativeAgentPublicSafety.shouldForceNeutralOrganism(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1"]
    ))
}

@Test func existingSubconsciousInstallInheritsMissingOrganismPreferenceOnce() throws {
    let root = try makePublicSafetyRoot()
    let (defaults, suiteName) = try makeIsolatedDefaults()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
    defaults.set(true, forKey: "cognitiveSubstrateEnabled")

    let config = NativeCognitionRuntime.reconcileOrganismPreferenceForLaunch(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "0"],
        defaults: defaults
    )

    #expect(config.enabled)
    #expect(defaults.object(forKey: "organismKernelEnabled") as? Bool == true)
}

@Test func explicitOrganismOffWinsOverEnabledSubconsciousMaster() throws {
    let root = try makePublicSafetyRoot()
    let (defaults, suiteName) = try makeIsolatedDefaults()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
    defaults.set(true, forKey: "cognitiveSubstrateEnabled")
    defaults.set(false, forKey: "organismKernelEnabled")

    let config = NativeCognitionRuntime.reconcileOrganismPreferenceForLaunch(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "0"],
        defaults: defaults
    )

    #expect(!config.enabled)
    #expect(defaults.object(forKey: "organismKernelEnabled") as? Bool == false)
}

@Test func publicPreOnboardingSafetyDoesNotSeedOrganismPreference() throws {
    let root = try makePublicSafetyRoot()
    let (defaults, suiteName) = try makeIsolatedDefaults()
    defer {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
    defaults.set(true, forKey: "cognitiveSubstrateEnabled")

    let config = NativeCognitionRuntime.reconcileOrganismPreferenceForLaunch(
        dataRoot: root,
        environment: ["NATIVEAGENT_PUBLIC_SAFE_MODE": "1"],
        defaults: defaults
    )

    #expect(!config.enabled)
    #expect(defaults.object(forKey: "organismKernelEnabled") == nil)
}
