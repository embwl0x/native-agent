import Foundation
import PersistenceCore

// Blueprint: | `ActivityPolicy.swift` | `ActivityPolicy`, `ActivityPolicyStore`: capture consent, exclusions, title gates and persistence |

/// Opt-in activity recording: capture, titles, browser titles and model access
/// default off; exclusions start non-empty. Sendable policy snapshots gate AX
/// reads, history queries and retroactive deletion without shared mutable state.
public struct ActivityPolicy: Sendable, Codable, Equatable {
    /// The whole organ requires explicit opt-in.
    public var captureEnabled: Bool
    /// Title redaction catches shaped secrets, not all private content; title capture defaults off.
    public var captureTitles: Bool
    /// Browser titles need separate opt-in because AX cannot reliably identify private browsing.
    public var browserTitlesEnabled: Bool
    public var appNameOnlyMode: Bool
    /// Local capture does not imply consent to send activity history to a model.
    public var allowModelAccess: Bool
    public var excludedBundleIDs: Set<String>
    public var retentionDays: Int

    public init(
        captureEnabled: Bool = false,
        captureTitles: Bool = false,
        browserTitlesEnabled: Bool = false,
        appNameOnlyMode: Bool = false,
        allowModelAccess: Bool = false,
        excludedBundleIDs: Set<String> = ActivityPolicy.defaultExcludedBundleIDs,
        retentionDays: Int = ActivityPolicy.defaultRetentionDays
    ) {
        self.captureEnabled = captureEnabled
        self.captureTitles = captureTitles
        self.browserTitlesEnabled = browserTitlesEnabled
        self.appNameOnlyMode = appNameOnlyMode
        self.allowModelAccess = allowModelAccess
        self.excludedBundleIDs = excludedBundleIDs
        self.retentionDays = retentionDays
    }

    // MARK: - Constants

    public static let defaultRetentionDays = 30

    /// Non-overridable exclusions join every check independently of user choices.
    /// Resolve the host identity at runtime so every build excludes itself.
    public static var alwaysExcludedBundleIDs: Set<String> {
        var ids: Set<String> = [
            "com.apple.loginwindow",             // a lock signal, never a span
            ActivityPolicy.selfProcessBundleID,
        ]
        if let host = Bundle.main.bundleIdentifier, !host.isEmpty {
            ids.insert(host)
        }
        return ids
    }

    /// Refused identities use this always-excluded sentinel to close the prior
    /// span without opening another or reading AX content.
    public static let selfProcessBundleID = "nativeagent.activity-watch.self"

    /// Use bundle ids: app names can be spoofed to bypass the browser-title gate.
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
    ]

    /// Credential, health and finance defaults exclude the whole app: no title,
    /// app name or row. Title redaction alone cannot protect private content.
    public static let defaultExcludedBundleIDs: Set<String> = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.lastpass.lastpassmacdesktop",
        "com.dashlane.Dashlane",
        "in.sinew.Enpass-Desktop",
        "org.keepassxc.keepassxc",
        "com.apple.systempreferences", // Account panes contain private content.
        "com.apple.Health",
        "com.apple.MobileSMS", // Two-factor codes arrive here.
        "com.apple.stocks",
        "com.apple.Wallet",
        "com.intuit.identity.mint",
        "com.quicken.Quicken",
        "com.ynab.YNAB",
        "com.coinbase.Coinbase",
    ]

    // MARK: - Decisions

    public var effectiveExcludedBundleIDs: Set<String> {
        excludedBundleIDs.union(ActivityPolicy.alwaysExcludedBundleIDs)
    }

    /// Gate before AX: even a discarded read exposes excluded content.
    public func isExcluded(bundleID: String) -> Bool {
        effectiveExcludedBundleIDs.contains(bundleID)
    }

    public func allowsCapture(bundleID: String) -> Bool {
        captureEnabled && !isExcluded(bundleID: bundleID)
    }

    /// Browser titles require both switches; app-name-only mode and exclusions override them.
    public func allowsTitleCapture(bundleID: String) -> Bool {
        guard allowsCapture(bundleID: bundleID) else { return false }
        guard !appNameOnlyMode, captureTitles else { return false }
        if ActivityPolicy.browserBundleIDs.contains(bundleID) {
            return browserTitlesEnabled
        }
        return true
    }
}

// MARK: - Persistence

/// Keep policy beside the span DB so wiping the activity-watch directory removes both.
public struct ActivityPolicyStore: Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return """
                    The saved activity policy is unavailable: \(detail). Its bytes were preserved and activity settings cannot be changed \
                    until it is repaired.
                    """
            }
        }
    }

    public let fileURL: URL

    public init(dataRoot: URL) {
        self.fileURL = ActivityWatchPaths.policyURL(dataRoot: dataRoot)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Missing is the documented safe bootstrap. An existing unreadable,
    /// non-regular, or malformed authority file is unavailable, not "missing".
    public func loadChecked() throws -> ActivityPolicy {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        } catch CocoaError.fileReadNoSuchFile {
            return ActivityPolicy()
        } catch CocoaError.fileNoSuchFile {
            return ActivityPolicy()
        } catch {
            throw StoreError.unavailable(error.localizedDescription)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw StoreError.unavailable("the path is not a regular file")
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw StoreError.unavailable(error.localizedDescription)
        }
        do {
            return try JSONDecoder().decode(ActivityPolicy.self, from: data)
        } catch {
            throw StoreError.unavailable("the file is malformed")
        }
    }

    public func save(_ policy: ActivityPolicy) throws {
        // A settings mutation may bootstrap a missing file, but it must never
        // overwrite existing bytes that the owner cannot validate.
        _ = try loadChecked()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(policy)
        try SwiftNativePersistenceCore.writeDataAtomicDurable(data, to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}

extension ActivityPolicy {
    public enum TitleCapture: Hashable, CaseIterable {
        case appNamesOnly, windowTitles, windowAndBrowserTitles

        public init(policy: ActivityPolicy) {
            if policy.appNameOnlyMode || !policy.captureTitles {
                self = .appNamesOnly
            } else {
                self = policy.browserTitlesEnabled ? .windowAndBrowserTitles : .windowTitles
            }
        }

        public func applied(to policy: ActivityPolicy) -> ActivityPolicy {
            var next = policy
            next.appNameOnlyMode = self == .appNamesOnly
            next.captureTitles = self != .appNamesOnly
            next.browserTitlesEnabled = self == .windowAndBrowserTitles
            return next
        }

    }
}
