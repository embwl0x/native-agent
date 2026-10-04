import Foundation

public enum NativeAgentPublicSafety {
    public static let publicSafeModeEnvironmentKey = "NATIVEAGENT_PUBLIC_SAFE_MODE"

    public static func isPublicSafeMode(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcesURL: URL? = Bundle.main.resourceURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        if let raw = environment[publicSafeModeEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !raw.isEmpty {
            return ["1", "true", "yes", "on"].contains(raw)
        }

        guard let resourcesURL else { return false }
        let fm = FileManager.default
        if fm.fileExists(atPath: resourcesURL.appendingPathComponent("REPO_PATH").path) {
            return false
        }
        guard bundleURL.pathExtension == "app" else { return false }
        return fm.fileExists(atPath: resourcesURL.appendingPathComponent("VERSION").path)
    }

    public static func hasCompletedOnboarding(dataRoot: URL) -> Bool {
        let fm = FileManager.default
        // Pending completion or reset must finish before resident cognition
        // wakes. Reset can still carry the previous completion sentinel.
        for pending in ["pending-completion.json", "pending-reset.json"] {
            if fm.fileExists(atPath: dataRoot
                .appendingPathComponent("onboarding", isDirectory: true)
                .appendingPathComponent(pending).path) {
                return false
            }
        }

        if fm.fileExists(atPath: dataRoot.appendingPathComponent(".onboarded").path) {
            return true
        }

        // Legacy public installs may predate the sentinel. Accept them only as
        // a complete bundle: a valid named profile plus every required persona
        // document inside this exact data root. This is a compatibility read,
        // not a second onboarding owner or a write-side migration.
        let profileURL = dataRoot
            .appendingPathComponent("memory", isDirectory: true)
            .appendingPathComponent("profile.json")
        return hasLegacyCompletionAnchor(
            personaRoot: PersonaRootResolver.resolveIsolated(dataRoot: dataRoot),
            profileURL: profileURL
        )
    }

    /// Missing profiles may be repaired only when the legacy documents are complete.
    public static func hasLegacyCompletionAnchor(
        personaRoot: URL, profileURL: URL, allowMissingProfile: Bool = false
    ) -> Bool {
        let fm = FileManager.default
        guard ["SOUL.md", "VOICE.md", "USER.md", "GROWTH.md"].allSatisfy({ fileName in
            let url = personaRoot.appendingPathComponent(fileName)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber else { return false }
            return size.intValue > 0
        }) else { return false }
        if allowMissingProfile, !fm.fileExists(atPath: profileURL.path) { return true }
        guard let profileData = try? Data(contentsOf: profileURL),
              let profile = try? JSONSerialization.jsonObject(with: profileData) as? [String: Any],
              let name = profile["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    public static func shouldForceNeutralOrganism(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resourcesURL: URL? = Bundle.main.resourceURL,
        bundleURL: URL = Bundle.main.bundleURL
    ) -> Bool {
        isPublicSafeMode(environment: environment, resourcesURL: resourcesURL, bundleURL: bundleURL)
            && !hasCompletedOnboarding(dataRoot: dataRoot)
    }
}
