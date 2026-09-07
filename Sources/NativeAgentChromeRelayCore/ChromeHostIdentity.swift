import Darwin
import Foundation
import Security

/// 2026-09-06: who is allowed to be on either end of the Chrome control link.
///
/// The relay is a native messaging host: Chrome launches it and speaks to it
/// over the launched process's own pipes. Nothing about that arrangement was
/// checked. The app authenticated its peer by executable path — it had to be
/// the bundled relay — and the relay authenticated the app with a secret it
/// read off disk itself. Both tests pass for a same-user process that simply
/// LAUNCHES the bundled relay with pipes of its own: it is the right
/// executable, and the token is a file it can read. It then owns the channel,
/// leases and all, and displaces the one Chrome was using.
///
/// The missing fact on both sides is the relay's PARENT. Chrome launches the
/// host itself, so a relay whose parent is not a browser was not launched by
/// a browser — and Chrome names the calling extension in argv, which an
/// arbitrary launcher has no reason to reproduce and which pins the link to
/// the one extension the native-host manifest allows.
///
/// "Is a browser" is a code-signature question, not a filesystem one: the
/// parent's signing identifier, sealed and chained to Apple, decides it. An
/// Info.plist is a file the impersonator writes.
///
/// Shared here because both halves must agree on it: the relay refuses to
/// start, and the app refuses the connection.
public enum ChromeHostIdentity {
    /// The extension the native-host manifest registers this relay for. The
    /// manifest's `allowed_origins` is the same value.
    public static let extensionID = "egdbijiogeeggnmjheomgnnkhmlepfcn"

    /// The origin Chrome passes in argv when it launches the host.
    public static var allowedOrigin: String { "chrome-extension://\(extensionID)/" }

    /// 2026-09-06: the CODE-SIGNING identifiers of the Chromium-family browsers
    /// that legitimately launch a native messaging host.
    ///
    /// This used to be a list of prefixes matched against `CFBundleIdentifier`
    /// read out of the enclosing `.app`'s Info.plist. Both halves of that were
    /// forgeable by anyone who can write a directory: the Info.plist is a file
    /// the impersonator authors, and a dotted extension of a known identifier
    /// (`com.google.Chrome.anything`) passed the prefix rule. The identifier is
    /// now taken from the signature — where it is sealed — and matched exactly,
    /// so each channel is listed on its own line. A browser missing here, or an
    /// unsigned build (a self-built Chromium), is refused rather than trusted.
    private static let browserSigningTeams: [String: String] = [
        // 2026-09-06: Google team verified with codesign -dv --verbose=2 on installed Chrome.
        "com.google.Chrome": "EQHXZ8M8AV",
        "com.google.Chrome.beta": "EQHXZ8M8AV",
        "com.google.Chrome.dev": "EQHXZ8M8AV",
        "com.google.Chrome.canary": "EQHXZ8M8AV",
        // 2026-09-06: not installed; well-known vendor teams for these browsers/channels.
        // Unsigned Chromium has no trusted vendor identity and is refused.
        "com.microsoft.edgemac": "UBF8T346G9",
        "com.microsoft.edgemac.Beta": "UBF8T346G9",
        "com.microsoft.edgemac.Dev": "UBF8T346G9",
        "com.microsoft.edgemac.Canary": "UBF8T346G9",
        "com.brave.Browser": "KL8N8XSYF4",
        "com.brave.Browser.beta": "KL8N8XSYF4",
        "com.brave.Browser.nightly": "KL8N8XSYF4",
        "com.vivaldi.Vivaldi": "4XF3XNRN6Y",
        "com.operasoftware.Opera": "A2P9LX4JPN",
        "company.thebrowser.Browser": "HQ6RZL8FMF",
    ]

    public static var browserSigningIdentifiers: [String] { browserSigningTeams.keys.sorted() }

    /// The designated requirement a browser process must satisfy: an intact
    /// signature chaining to Apple (so the vendor's Developer ID, not a local
    /// re-sign) AND one of the identifiers above.
    public static var browserCodeRequirement: String {
        let identifiers = browserSigningIdentifiers
            .map { "(identifier \"\($0)\" and certificate leaf[subject.OU] = \"\(browserSigningTeams[$0]!)\")" }
            .joined(separator: " or ")
        return "anchor apple generic and (\(identifiers))"
    }

    public static func executablePath(ofProcess pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    public static func parentProcessID(of pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expected)
        }
        guard read == expected, info.pbi_ppid > 0 else { return nil }
        return pid_t(info.pbi_ppid)
    }

    /// Basic validation only: the code directory, its seal over the executable
    /// and the signature chain — not every resource inside a browser's several
    /// hundred megabytes. The identifier and the anchor both live in the code
    /// directory, which is what the requirement reads.
    private static var validationFlags: SecCSFlags {
        SecCSFlags(rawValue: kSecCSBasicValidateOnly)
    }

    /// The signing identifier of the Chromium-family browser at `path`, or nil
    /// when the executable is not one: unsigned, re-signed by somebody who is
    /// not the vendor, tampered with since it was signed, an identifier this
    /// build does not list, or simply a different program.
    public static func browserSigningIdentifier(forExecutablePath path: String) -> String? {
        guard !path.isEmpty else { return nil }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code)
                == errSecSuccess, let code else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(browserCodeRequirement as CFString, [], &requirement)
                == errSecSuccess, let requirement else { return nil }
        guard SecStaticCodeCheckValidity(code, validationFlags, requirement) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        return identifier
    }

    public static func isBrowserExecutable(path: String) -> Bool {
        browserSigningIdentifier(forExecutablePath: path) != nil
    }

    public static func isBrowserProcess(_ pid: pid_t) -> Bool {
        guard let path = executablePath(ofProcess: pid) else { return false }
        return isBrowserExecutable(path: path)
    }

    /// Chrome passes the calling extension's origin as an argument (alongside
    /// `--parent-window=`). Accept it with or without the trailing slash; the
    /// value must be OUR extension's, so a second native host's origin or a
    /// foreign extension's does not pass.
    public static func argumentsCarryAllowedOrigin(_ arguments: [String]) -> Bool {
        let origin = allowedOrigin
        let withoutSlash = String(origin.dropLast())
        return arguments.dropFirst().contains { $0 == origin || $0 == withoutSlash }
    }

    /// True for the relay that ships INSIDE an app bundle — the only relay the
    /// app ever accepts as a peer, and therefore the only one an impersonator
    /// has any reason to launch. A bare build-products binary (the hermetic
    /// lane, and the relay test harness) is not this, and is left alone: the
    /// app does not accept it either.
    /// 2026-09-06: what the relay proved about its own parent at launch,
    /// carried in the hello.
    ///
    /// The app checks the peer's parent live, which is right while the browser
    /// is still there — and wrong the moment it is not. Chrome can exit, or be
    /// restarted, while the host it launched is still pumping; the relay is
    /// then reparented to launchd and a live check refuses a connection that
    /// was legitimate all along. The evidence covers exactly that gap: the
    /// relay validated its parent when only it could, and says so.
    ///
    /// The evidence is self-reported and proves nothing on its own. It is
    /// admitted only for a peer that is already the relay executable this app
    /// registered, whose signature still matches its bytes — a relay that
    /// refuses to start unless a signed browser launched it.
    public struct ParentEvidence: Sendable {
        public static let bundleIDField = "parent_bundle_id"
        public static let processIDField = "parent_pid"
        public static let validatedAtField = "parent_validated_at"
        /// A relay dials the app immediately after it validates its parent, so
        /// a stamp older than this is not evidence from this launch.
        public static let maximumAgeSeconds: TimeInterval = 300
        /// Tolerance for a clock that moved between the two stamps.
        public static let clockSkewSeconds: TimeInterval = 60

        public let bundleIdentifier: String
        public let processID: pid_t
        public let validatedAt: Date

        public init(bundleIdentifier: String, processID: pid_t, validatedAt: Date) {
            self.bundleIdentifier = bundleIdentifier
            self.processID = processID
            self.validatedAt = validatedAt
        }

        /// The fields the relay adds to its hello frame.
        public var helloFields: [String: Any] {
            [
                Self.bundleIDField: bundleIdentifier,
                Self.processIDField: Int(processID),
                Self.validatedAtField: validatedAt.timeIntervalSince1970,
            ]
        }

        /// Accepts a hello's evidence when it is internally consistent: a
        /// browser identifier THIS build accepts, a real pid, and a stamp from
        /// the relay's own lifetime rather than the distant past or the future.
        public static func isWellFormed(
            bundleIdentifier: String?,
            processID: Int?,
            validatedAt: Double?,
            now: Date = Date()
        ) -> Bool {
            guard let bundleIdentifier,
                  ChromeHostIdentity.browserSigningIdentifiers.contains(bundleIdentifier),
                  let processID, processID > 0,
                  let validatedAt else { return false }
            let age = now.timeIntervalSince1970 - validatedAt
            return age >= -clockSkewSeconds && age <= maximumAgeSeconds
        }
    }

    public static func isBundledRelay(executablePath path: String) -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        guard url.lastPathComponent == "NativeAgentChromeRelay" else { return false }
        let macOSDirectory = url.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS" else { return false }
        let contents = macOSDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return false }
        return contents.deletingLastPathComponent().pathExtension == "app"
    }
}
