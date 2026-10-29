import Foundation
import NativeAgentShared
// Blueprint: | `NativeAgentBuildIdentity.swift` | process-cached current identity, injectable `from`, `writeLaunchStamp` |

/// Exact identity of the bytes currently running inside the app bundle.
///
/// Development and release builders stamp these values before signing. The
/// source revision is useful only together with `sourceDirty`: a dirty build is
/// intentionally never presented as exact proof of the named commit.
/// `sourceContentID` identifies the source snapshot, including dirty edits.
///
/// All surfaces read the same process-cached running-binary identity.
public struct NativeAgentBuildIdentity: Sendable, Equatable {
    public let version: String
    public let build: String
    public let sourceRevision: String?
    public let sourceDirty: Bool
    public let sourceContentID: String?

    public init(version: String, build: String, sourceRevision: String?, sourceDirty: Bool, sourceContentID: String? = nil) {
        self.version = version
        self.build = build
        self.sourceRevision = sourceRevision
        self.sourceDirty = sourceDirty
        self.sourceContentID = sourceContentID
    }

    public static let current: NativeAgentBuildIdentity = {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:], resourcesURL: Bundle.main.resourceURL)
    }()

    public static func from(
        infoDictionary: [String: Any],
        resourcesURL: URL?
    ) -> NativeAgentBuildIdentity {
        let version = nonempty(infoDictionary["CFBundleShortVersionString"] as? String) ?? "dev"
        let build = nonempty(infoDictionary["CFBundleVersion"] as? String) ?? version
        let plistRevision = nonempty(infoDictionary["NativeAgentSourceRevision"] as? String)
        let resourceRevision: String? = resourcesURL.flatMap { root in
            try? String(contentsOf: root.appendingPathComponent("VERSION_SHA"), encoding: .utf8)
        }.flatMap(nonempty)
        let revisionStampsAgree = plistRevision == nil
            || resourceRevision == nil
            || plistRevision?.lowercased() == resourceRevision?.lowercased()
        let stampedDirty = infoDictionary["NativeAgentSourceDirty"] as? Bool ?? true
        return NativeAgentBuildIdentity(
            version: version,
            build: build,
            sourceRevision: plistRevision ?? resourceRevision,
            // Older bundles did not stamp dirty-source truth. Treat that
            // absence as unknown/dirty so a full-looking resource SHA cannot
            // be promoted into exact byte identity accidentally. Likewise,
            // both builder stamps must agree when both are present; a copied
            // or partially restamped bundle is never exact proof.
            sourceDirty: stampedDirty || !revisionStampsAgree,
            sourceContentID: nonempty(infoDictionary["NativeAgentSourceContentID"] as? String).flatMap {
                Self.isFullGitObjectID($0) ? $0.lowercased() : nil
            }
        )
    }

    public var exactSourceRevision: String? {
        guard !sourceDirty,
              let sourceRevision,
              Self.isFullGitObjectID(sourceRevision) else {
            return nil
        }
        return sourceRevision.lowercased()
    }

    public var bridgePayload: [String: Any] {
        [
            "version": version,
            "build": build,
            "sourceRevision": sourceRevision ?? NSNull(),
            "sourceDirty": sourceDirty,
            "sourceContentID": sourceContentID ?? NSNull(),
            "exactSourceRevision": exactSourceRevision ?? NSNull(),
        ]
    }

    public static let launchStampFilename = "build_launch.json"

    /// Public build metadata only; independent of optional control bridges.
    public func writeLaunchStamp(root: URL, at: Date = Date()) throws {
        let payload: [String: Any] = [
            "version": version,
            "build": build,
            "sourceRevision": sourceRevision ?? NSNull(),
            "sourceDirty": sourceDirty,
            "sourceContentID": sourceContentID ?? NSNull(),
            "writtenAt": NativeTimestampFormat.plainZulu(at),
            // Which process this launch is: the same build relaunched is a new window.
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: root.appendingPathComponent(Self.launchStampFilename), options: .atomic)
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func isFullGitObjectID(_ value: String) -> Bool {
        guard value.count == 40 || value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...70).contains($0.value)
                || (97...102).contains($0.value)
        }
    }
}
