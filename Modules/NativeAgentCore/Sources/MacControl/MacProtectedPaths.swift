import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(UserNotifications)
import UserNotifications
import CryptoKit
import CoreGraphics
import AppKit
import ApplicationServices
import UserNotifications
#endif

// Blueprint: | `MacProtectedPaths.swift` | `MacControlSensitivePathFence`: protected data paths and the shared OS/store mutation floor, including protected parents; reads and copy sources keep their scope |

// MARK: - Sensitive-path fence

/// Returns the first refusal, or nil when allowed. Trust file policy is separate.
///
/// **TOCTOU residual**: the fence resolves the symlink chain once at check
/// time, but Foundation does not expose O_NOFOLLOW open semantics so an
/// attacker who can race a symlink swap BETWEEN the fence's resolution and
/// the FileManager call can still bypass the check. Callers shrink the
/// window by re-resolving + re-fencing immediately before the syscall
/// (see `handleFileRead` / `handleFileList`), but the gap is not closed.
/// Swift owns this fence; the residual race above remains.
public enum MacControlSensitivePathFence {
    /// Protected files relative to the app's data root, never global basenames.
    public static let bannedDataRootFiles: [String] = [
        "config.json",
        "trust_policy.json",
        "trust.json",
        "macctl_bridge.json",
        "browser_ipc_token",
        "browser_ipc.json",
        "auth.json",
        "credentials.json",
        "icloud_pairing_secret.bin",
        "pairing_secret.bin",
        ".manifest_signing_key",
        "config/config.json",
        "telegram/config.json",
        "research/config.json",
        "auto_doctor/config.json",
        "tools/.manifest_signing_key",
        "catalog/.pack_signing_key",
        "mcp/servers.json",
    ]

    /// Directory prefixes (relative to $HOME) that are NEVER touched.
    public static let bannedHomePrefixes: [String] = [
        ".config/claude-bridge",
        InstallPaths.current.bridgeConfigRelativePath + "/claude-bridge",
        ".ssh",
        ".gnupg",
        "Library/Keychains",
        "Library/Accounts",
        "Library/Application Support/AddressBook",
        "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CloudDocs",
        "Library/Application Support/com.apple.TCC",
        "Library/Application Support/Knowledge",
        "Library/Application Support/SyncServices",
        "Library/Messages",
        "Library/Mail",
        "Library/Calendars",
        "Library/Containers/com.apple.Home",
        "Library/Containers/com.apple.reminders",
        "Library/Group Containers/group.com.apple.reminders",
        "Library/Group Containers/group.com.apple.notes",
        "Library/Mobile Documents",
        "Library/Safari",
        "Pictures/Photos Library.photoslibrary",
    ]

    /// Protected paths relative to the resolved NativeAgent data roots.
    public static let bannedDataRootSegments: [[String]] = [
        ["oauth"],
        ["oauth_tokens"],
        ["providers"],
        ["trust"],
        ["pairings"],
        ["secrets"],
        ["security"],
        ["agents", "peers.json"],
        ["agents", "peer-claims"],
        ["workflows", "approvals"],
        ["nextgen", "remote"],
        ["memory", "vault"],
        ["codex_home"],
        ["codex_child_home"],
        ["senses", "ledger"],
        ["senses", "news"],
        // The model key lives beside its own logs, so the fence names the
        // file rather than the directory.
        ["jev", "credential.json"],
    ]

    /// Non-bypassable OS mutation floor. Full Mac grants broad user-space
    /// access, but it must not authorize mutation of the operating system,
    /// launch services, or app bundles.
    public static let protectedSystemMutationPrefixes: [String] = [
        "/System",
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/usr/lib",
        "/usr/libexec",
        "/Applications",
        "/Library/LaunchAgents",
        "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools",
        "/Library/StartupItems",
        "/private/etc",
        "/private/var/db",
        "/private/var/root",
        "/etc",
        "/var/db",
        "/var/root",
    ]

    /// Protected paths use PersistenceCore.defaultDataRoot()'s process-stable selection.
    private static var swiftDataRootPath: String {
        PersistenceCore.defaultDataRoot().path
    }

    /// NATIVE_AGENT_DATA extends protected-path coverage only; it never selects configuration.
    private static var legacyDaemonDataRootPath: String? {
        let raw = ProcessInfo.processInfo.environment["NATIVE_AGENT_DATA"]
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return (raw as NSString).expandingTildeInPath
    }

    /// Returns nil when path is allowed, or a rejection reason string.
    public static func reason(forPath rawPath: String) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return checkSingle(path: expanded)
    }

    /// Moving or trashing a parent also mutates every protected path beneath it.
    public static func mutationReason(forPath rawPath: String) -> String? {
        if let reason = reason(forPath: rawPath) { return reason }
        let expanded = (rawPath as NSString).expandingTildeInPath
        return checkSingle(path: expanded, includingProtectedDescendants: true)
    }

    /// Copy sources keep the OS floor; writes also preserve dedicated store ownership.
    public static func protectedSystemMutationReason(forPath rawPath: String, write: Bool = true) -> String? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "protected_system_path_denied: empty path" }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let path = normalizedPath(expanded)
        // Both raw file routes leave these bytes to their dedicated owners.
        let ownedStores = ["mac_control", "her_screen", "activity_watch", "experiences",
                           "mac_control_audit.jsonl", "mac_control_audit.jsonl.lock"]
        let roots = [swiftDataRootPath, NSHomeDirectory() + "/Library/Application Support/NativeAgent"]
            + (legacyDaemonDataRootPath.map { [$0] } ?? [])
        let prefixes = (protectedSystemMutationPrefixes + (write ? roots.flatMap { root in
            ownedStores.map { (root as NSString).appendingPathComponent($0) }
        } : [])).map { (raw: $0, normalized: normalizedPath($0)) }
        if let prefix = prefixes.first(where: {
            NativeAgentWorkspaceRoot.relativePath(path, under: $0.normalized) != nil
                || NativeAgentWorkspaceRoot.relativePath($0.normalized, under: path) != nil
        }) {
            return "protected_system_path_denied: \(prefix.raw)"
        }
        return nil
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
    }

    private static func checkSingle(path: String, includingProtectedDescendants: Bool = false) -> String? {
        let target = normalizedPath(path)
        func protected(_ full: String) -> Bool {
            let root = normalizedPath(full)
            return NativeAgentWorkspaceRoot.relativePath(target, under: root) != nil
                || (includingProtectedDescendants && NativeAgentWorkspaceRoot.relativePath(root, under: target) != nil)
        }
        let home = (NSHomeDirectory() as NSString).expandingTildeInPath
        for prefix in bannedHomePrefixes {
            let fullPrefix = (home as NSString).appendingPathComponent(prefix)
            if protected(fullPrefix) {
                return "sensitive_path_denied: \(prefix)"
            }
        }

        // Relocated, default and legacy data roots receive the same fence.
        var dataRootCandidates: [String] = [
            swiftDataRootPath,
            (home as NSString).appendingPathComponent("Library/Application Support/NativeAgent"),
        ]
        if let legacy = legacyDaemonDataRootPath {
            dataRootCandidates.append(legacy)
        }
        for rootRaw in dataRootCandidates {
            for file in bannedDataRootFiles {
                let full = normalizedPath((rootRaw as NSString).appendingPathComponent(file))
                if target == full
                    || (includingProtectedDescendants && NativeAgentWorkspaceRoot.relativePath(full, under: target) != nil) {
                    return "sensitive_path_denied: data/\(file)"
                }
            }
            let root = normalizedPath(rootRaw)
            if let relative = NativeAgentWorkspaceRoot.relativePath(target, under: root), !relative.isEmpty {
                // A local backup's payload (backups/<id>/data/…) is the data root again: what is fenced there is fenced in it.
                if let payload = relative.range(of: "^backups/[^/]+/data/", options: .regularExpression),
                   let reason = checkSingle(path: root + "/" + relative[payload.upperBound...], includingProtectedDescendants: includingProtectedDescendants) {
                    return reason
                }
                let parts = relative.split(separator: "/")
                if isConnectorCredential(relative)
                    || (includingProtectedDescendants && parts.first == "connectors" && parts.count <= 2) {
                    return "sensitive_path_denied: data/\(relative)"
                }
            }
            for segs in bannedDataRootSegments {
                let full = (rootRaw as NSString).appendingPathComponent(segs.joined(separator: "/"))
                if protected(full) {
                    return "sensitive_path_denied: data/\(segs.joined(separator: "/"))"
                }
            }
        }

        return nil
    }

    private static func isConnectorCredential(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/")
        return parts.count == 3 && parts[0] == "connectors"
            && ["auth.json", "credential.json", "credentials.json"].contains(String(parts[2]))
    }
}
