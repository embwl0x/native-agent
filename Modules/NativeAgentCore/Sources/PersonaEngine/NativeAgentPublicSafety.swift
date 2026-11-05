import Foundation

// Blueprint: | `NativeAgentPublicSafety.swift` | `NativeAgentPublicSafety`. |

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
        // Finish pending setup or reset before cognition wakes; reset may still retain the previous completion sentinel.
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

        return false
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
