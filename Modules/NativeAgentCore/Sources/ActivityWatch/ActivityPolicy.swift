import Foundation
import PersistenceCore

/// W5 privacy policy for the ambient activity watcher.
///
/// Every field defaults to the SAFE value: the feature is off, titles are off,
/// browser titles are off, and the exclusion list ships non-empty. A fresh
/// install that never touches this file captures nothing.
///
/// This is a value type on purpose. It is read on the capture thread *before*
/// any AX call (W5 layer 1), read again on every query path (W5 layer 2), and
/// handed to the retro-delete path (W5 layer 3). A reference type shared across
/// those three would be a race; a `Sendable` snapshot cannot be.
public struct ActivityPolicy: Sendable, Codable, Equatable {
    /// Master switch. FALSE by default — the whole organ is opt-in.
    public var captureEnabled: Bool
    /// Whether the frontmost window's title is captured at all. FALSE by default.
    /// Even when true, titles pass through `ActivityTitleRedaction` first and
    /// the honest limit stated in the build plan (W5) applies: redaction catches
    /// *shaped secrets*, it does not make a title private-safe.
    public var captureTitles: Bool
    /// Browser titles are their own decision, and their own default-off.
    /// Private-browsing state is not reliably detectable via AX across
    /// Safari/Chrome versions, so we never ship a "private browsing excluded"
    /// claim a browser update can turn into a lie.
    public var browserTitlesEnabled: Bool
    /// Global override: app names only, no titles anywhere, whatever else says.
    public var appNameOnlyMode: Bool
    /// Whether an activity answer may be returned to the selected chat model.
    /// FALSE by default. Capture remains useful as a local record without
    /// silently turning that record into provider input.
    public var allowModelAccess: Bool
    /// User-editable exclusions. Ships with a starter list (see
    /// `defaultExcludedBundleIDs`) rather than empty.
    public var excludedBundleIDs: Set<String>
    /// W10 retention, in days. Spans older than this are pruned + VACUUMed.
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

    /// Decoding tolerates a policy file written by an older build: a missing key
    /// falls back to the SAFE default, never to "on".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        captureEnabled = try container.decodeIfPresent(Bool.self, forKey: .captureEnabled) ?? false
        captureTitles = try container.decodeIfPresent(Bool.self, forKey: .captureTitles) ?? false
        browserTitlesEnabled = try container.decodeIfPresent(Bool.self, forKey: .browserTitlesEnabled) ?? false
        appNameOnlyMode = try container.decodeIfPresent(Bool.self, forKey: .appNameOnlyMode) ?? false
        allowModelAccess = try container.decodeIfPresent(Bool.self, forKey: .allowModelAccess) ?? false
        excludedBundleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIDs)
            ?? ActivityPolicy.defaultExcludedBundleIDs
        retentionDays = try container.decodeIfPresent(Int.self, forKey: .retentionDays)
            ?? ActivityPolicy.defaultRetentionDays
    }

    // MARK: - Constants

    public static let defaultRetentionDays = 30

    /// NON-OVERRIDABLE exclusions. These are unioned into every check and are
    /// deliberately NOT part of `excludedBundleIDs` — a user (or a corrupt
    /// policy file, or a future settings UI bug) must not be able to remove
    /// them. The P0 spike caught NativeAgent's own window titled "Chat"; an
    /// agent recording its own chat window is a feedback loop, not telemetry.
    /// Self-exclusion resolves the HOST app's identity at runtime rather than
    /// matching a hardcoded bundle id. The first draft hardcoded the developer's
    /// personal id, which the repo's leak scanner caught — and which was a real
    /// defect, not just a naming one: the public build ships under a different
    /// identifier, so a hardcoded list would have silently failed to exclude
    /// NativeAgent from its own recording for every public user.
    public static var alwaysExcludedBundleIDs: Set<String> {
        var ids: Set<String> = [
            "com.apple.loginwindow",             // a lock signal, never a span
            ActivityPolicy.selfProcessBundleID,  // the watcher's own process
        ]
        // Whatever this binary actually is, it never records itself.
        if let host = Bundle.main.bundleIdentifier, !host.isEmpty {
            ids.insert(host)
        }
        return ids
    }

    /// Stand-in bundle id for "this is us". The capture layer knows its own PID
    /// but a command-line probe has no bundle id at all, so the PID check feeds
    /// this sentinel into the engine — which then takes the ordinary excluded
    /// path (close what is open, open nothing) instead of needing a second,
    /// separately-testable code path for self-exclusion.
    public static let selfProcessBundleID = "nativeagent.activity-watch.self"

    /// Browsers, for the `browserTitlesEnabled` gate. Bundle ids only — we never
    /// sniff a browser by name, because a name match would be trivially spoofed
    /// into title capture by any app calling itself "Safari".
    public static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.canary",
        "company.thebrowser.Browser",            // Arc
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "com.brave.Browser",
        "com.brave.Browser.beta",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
    ]

    /// The starter exclusion list (W5 review finding I13). Redaction catches
    /// *shaped* secrets; it does not make "Re: Q3 layoffs — Mail" private. So
    /// v1 ships the obvious credential / health / finance surfaces excluded
    /// outright — no title, no app name, no row at all.
    public static let defaultExcludedBundleIDs: Set<String> = [
        // --- password managers / credential stores ---
        "com.1password.1password",               // 1Password 8
        "com.agilebits.onepassword7",            // 1Password 7
        "com.agilebits.onepassword-osx",         // 1Password 6 and earlier
        "com.apple.keychainaccess",              // Keychain Access
        "com.apple.Passwords",                   // macOS Passwords.app
        "com.bitwarden.desktop",                 // Bitwarden
        "com.lastpass.LastPass",                 // LastPass
        "com.lastpass.lastpassmacdesktop",       // LastPass (MAS build)
        "com.dashlane.Dashlane",                 // Dashlane
        "in.sinew.Enpass-Desktop",               // Enpass
        "org.keepassxc.keepassxc",               // KeePassXC
        "com.apple.systempreferences",           // Settings — shows account panes
        // --- health ---
        "com.apple.Health",                      // Health
        "com.apple.MobileSMS",                   // Messages: 2FA codes land here
        // --- finance / banking ---
        "com.apple.stocks",                      // Stocks
        "com.apple.Wallet",                      // Wallet
        "com.intuit.identity.mint",              // Mint
        "com.quicken.Quicken",                   // Quicken
        "com.ynab.YNAB",                         // YNAB
        "com.coinbase.Coinbase",                 // Coinbase
    ]

    // MARK: - Decisions

    /// The complete exclusion set actually enforced: the user's list plus the
    /// non-overridable one.
    public var effectiveExcludedBundleIDs: Set<String> {
        excludedBundleIDs.union(ActivityPolicy.alwaysExcludedBundleIDs)
    }

    /// CAPTURE-TIME gate. Called BEFORE any AX read for that app — we do not
    /// read an excluded app's title and then discard it, because a discarded
    /// read is still a read and a later refactor turns it into a stored one.
    public func isExcluded(bundleID: String) -> Bool {
        effectiveExcludedBundleIDs.contains(bundleID)
    }

    /// Whether ANY row may be written for this app.
    public func allowsCapture(bundleID: String) -> Bool {
        captureEnabled && !isExcluded(bundleID: bundleID)
    }

    /// Whether the frontmost window's title may even be READ for this app.
    ///
    /// Browser titles require BOTH switches. `appNameOnlyMode` overrides
    /// everything, and an excluded app never gets here at all.
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

/// JSON-on-disk home for `ActivityPolicy`, in the same `activity_watch/`
/// directory as the span DB so a wipe of that directory takes the policy with
/// it. See `ActivityWatchPaths` for why that directory is not `activity/`.
public struct ActivityPolicyStore: Sendable {
    public enum StoreError: Error, LocalizedError, Equatable {
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail):
                return "The saved activity policy is unavailable: \(detail). Its bytes were preserved and activity settings cannot be changed until it is repaired."
            }
        }
    }

    public let fileURL: URL
    private let persistence: any PersistenceCoreProtocol

    public init(dataRoot: URL) {
        self.fileURL = ActivityWatchPaths.policyURL(dataRoot: dataRoot)
        self.persistence = makePersistenceCore()
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.persistence = makePersistenceCore()
    }

    /// Missing file, unreadable file, or garbage → the SAFE default. A policy
    /// we cannot read must never fail open into capturing.
    public func load() -> ActivityPolicy {
        (try? loadChecked()) ?? ActivityPolicy()
    }

    /// Missing is the documented safe bootstrap. An existing unreadable,
    /// non-regular, or malformed authority file is unavailable, not "missing".
    public func loadChecked() throws -> ActivityPolicy {
        let manager = FileManager.default
        if (try? manager.destinationOfSymbolicLink(atPath: fileURL.path)) != nil {
            throw StoreError.unavailable("the path is a symbolic link")
        }
        guard manager.fileExists(atPath: fileURL.path) else { return ActivityPolicy() }
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw StoreError.unavailable(error.localizedDescription)
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
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
