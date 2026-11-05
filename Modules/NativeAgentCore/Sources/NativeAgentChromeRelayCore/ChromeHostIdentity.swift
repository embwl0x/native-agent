import Darwin
import Foundation
import Security

// Blueprint: | `ChromeHostIdentity.swift` | `ChromeHostIdentity`; Browser/relay identity, allowed origins and private refusal evidence. |

/// Both ends require a browser-launched relay for the registered extension.
public enum ChromeHostIdentity {
    public static func tokenPath(forSocketPath socketPath: String) -> String {
        URL(fileURLWithPath: socketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-control.token")
            .path
    }

    /// Device and inode identify a file even when another app replaces its path.
    public struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t

        public init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Relay admission and manifest allowed_origins must share the same extension identity.
    public static let extensionID = "egdbijiogeeggnmjheomgnnkhmlepfcn"

    public static var allowedOrigin: String { "chrome-extension://\(extensionID)/" }

    /// Only listed signing identifiers with their vendor teams are admitted.
    private static let browserSigningTeams: [String: String] = [
        "com.google.Chrome": "EQHXZ8M8AV",
        "com.google.Chrome.beta": "EQHXZ8M8AV",
        "com.google.Chrome.dev": "EQHXZ8M8AV",
        "com.google.Chrome.canary": "EQHXZ8M8AV",
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

    /// Validate running code without hashing browser resources; macOS 27 rejects kSecCSBasicValidateOnly for live guests (-67070).
    private static var validationFlags: SecCSFlags { [] }

    public struct SigningFailure: Error, LocalizedError, Sendable {
        public let check: String
        public let status: OSStatus
        public var errorDescription: String? {
            "\(check) failed (OSStatus \(status)): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error")."
        }
    }

    /// Preflight and relay checks must preserve the same failed Security API and status.
    public static func checkedBrowserSigningIdentifier(forProcess pid: pid_t) throws -> String {
        func requireSuccess(_ status: OSStatus, _ check: String) throws {
            guard status == errSecSuccess else { throw SigningFailure(check: check, status: status) }
        }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        try requireSuccess(SecCodeCopyGuestWithAttributes(nil, attributes, [], &code), "SecCodeCopyGuestWithAttributes")
        guard let code else { throw SigningFailure(check: "running code identity", status: errSecCSNoSuchCode) }
        try requireSuccess(SecCodeCheckValidity(code, validationFlags, nil), "SecCodeCheckValidity (running browser)")
        var staticCode: SecStaticCode?
        try requireSuccess(SecCodeCopyStaticCode(code, [], &staticCode), "SecCodeCopyStaticCode (running browser)")
        guard let staticCode else { throw SigningFailure(check: "running browser signing information", status: errSecCSNoSuchCode) }
        var information: CFDictionary?
        try requireSuccess(SecCodeCopySigningInformation(staticCode, [], &information), "SecCodeCopySigningInformation")
        guard let identifier = (information as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String,
              let team = browserSigningTeams[identifier] else {
            throw SigningFailure(check: "browser signing identifier admission", status: errSecCSReqFailed)
        }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        try requireSuccess(SecRequirementCreateWithString(text as CFString, [], &requirement), "SecRequirementCreateWithString (browser vendor)")
        try requireSuccess(SecCodeCheckValidity(code, validationFlags, requirement), "SecCodeCheckValidity (browser vendor \(identifier))")
        return identifier
    }

    /// Kernel process birth stamp prevents a reused PID reviving an old refusal.
    public static func processBirthStamp(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = withUnsafeMutablePointer(to: &info) { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, expected) }
        guard read == expected else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }

    /// Chrome may add --parent-window= and a trailing slash; only the registered extension's origin is admitted.
    public static func argumentsCarryAllowedOrigin(_ arguments: [String]) -> Bool {
        let origin = allowedOrigin
        let withoutSlash = String(origin.dropLast())
        return arguments.dropFirst().contains { $0 == origin || $0 == withoutSlash }
    }

    /// Only the authenticated bundled relay may attest its launch-time browser parent.
    public struct ParentEvidence: Sendable {
        public static let bundleIDField = "parent_bundle_id"
        public static let processIDField = "parent_pid"
        public static let validatedAtField = "parent_validated_at"
        /// Dial follows launch validation immediately; older stamps cannot prove this launch's parent.
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

        public var helloFields: [String: Any] {
            [
                Self.bundleIDField: bundleIdentifier,
                Self.processIDField: Int(processID),
                Self.validatedAtField: validatedAt.timeIntervalSince1970,
            ]
        }

        /// Require an admitted browser, real PID and stamp within the relay's own lifetime so stale or future evidence cannot pass.
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

/// Refusal evidence is current only for the same living browser process, until a newer relay greeting succeeds.
public struct ChromeRelayRefusal: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case browser, listener }
    public let scope: Scope
    public let check: String
    public let osStatus: Int32?
    public let reason: String
    public let browserPID: pid_t
    public let browserBirthStamp: UInt64?
    public let recordedAt: Date

    public init(scope: Scope, check: String, osStatus: Int32?, reason: String, browserPID: pid_t) {
        self.scope = scope
        self.check = check
        self.osStatus = osStatus
        self.reason = reason
        self.browserPID = browserPID
        self.browserBirthStamp = ChromeHostIdentity.processBirthStamp(browserPID)
        self.recordedAt = Date()
    }

    public static func path(socketPath: String) -> String { socketPath + ".relay-refusal.json" }

    public static func read(socketPath: String) throws -> Self? {
        let path = Self.path(socketPath: socketPath)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              info.st_size <= 16_384 else {
            throw NSError(domain: "ChromeRelayRefusal", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Chrome relay refusal record is not an owned 0600 regular file of bounded size."])
        }
        return try JSONDecoder().decode(Self.self, from: FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
    }

}
