import Foundation
import CoreFoundation
import NativeAgentShared
// Blueprint: | `NativeAgentBuildIdentity.swift` | checked process-cached current app stamps; incomplete identity unavailable; `writeLaunchStamp` refuses it |

/// Build identity belongs to the running binary, shared across surfaces. A revision is exact proof only with sourceDirty; sourceContentID also binds dirty
/// edits.
public struct NativeAgentBuildIdentity: Sendable, Equatable {
    /// Display labels. Unavailable processes say so explicitly; the payload and launch writer never present these labels as stamped metadata.
    public let version: String
    public let build: String
    public let sourceRevision: String?
    public let sourceDirty: Bool?
    public let sourceContentID: String?
    public let unavailableReason: String?

    private init(version: String, build: String, sourceRevision: String, sourceDirty: Bool, sourceContentID: String) {
        self.version = version
        self.build = build
        self.sourceRevision = sourceRevision
        self.sourceDirty = sourceDirty
        self.sourceContentID = sourceContentID
        self.unavailableReason = nil
    }

    private init(unavailable reason: String) {
        version = "unavailable"
        build = "unavailable"
        sourceRevision = nil
        sourceDirty = nil
        sourceContentID = nil
        unavailableReason = reason
    }

    /// Presentation only; never reconstructs an identity from incomplete stamps.
    public var description: String {
        if let unavailableReason { return "Build identity unavailable: \(unavailableReason)" }
        return "\(version) (\(build))"
    }

    public static let current: NativeAgentBuildIdentity = {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:], resourcesURL: Bundle.main.resourceURL)
    }()

    public static func from(
        infoDictionary: [String: Any],
        resourcesURL: URL?
    ) -> NativeAgentBuildIdentity {
        guard let version = (infoDictionary["CFBundleShortVersionString"] as? String).trimmedNonEmpty,
              let build = (infoDictionary["CFBundleVersion"] as? String).trimmedNonEmpty,
              let revision = (infoDictionary["NativeAgentSourceRevision"] as? String).trimmedNonEmpty,
              Self.isFullGitObjectID(revision),
              let dirty = infoDictionary["NativeAgentSourceDirty"] as? NSNumber,
              CFGetTypeID(dirty) == CFBooleanGetTypeID(),
              let contentID = (infoDictionary["NativeAgentSourceContentID"] as? String).trimmedNonEmpty,
              Self.isFullGitObjectID(contentID),
              let resourcesURL else {
            return Self(unavailable: """
                This process has no complete current app stamp. Rebuild and install the app; command-line processes have no app identity.
                """)
        }
        do {
            let resourceRevision = try String(contentsOf: resourcesURL.appendingPathComponent("VERSION_SHA"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard resourceRevision.lowercased() == revision.lowercased() else {
                return Self(unavailable: "Info.plist and VERSION_SHA disagree. Rebuild and install the app.")
            }
        } catch {
            return Self(unavailable: "VERSION_SHA could not be read: \(error.localizedDescription). Rebuild and install the app.")
        }
        return Self(version: version, build: build, sourceRevision: revision.lowercased(),
                    sourceDirty: dirty.boolValue, sourceContentID: contentID.lowercased())
    }

    public var exactSourceRevision: String? {
        guard sourceDirty == false,
              let sourceRevision,
              Self.isFullGitObjectID(sourceRevision) else {
            return nil
        }
        return sourceRevision.lowercased()
    }

    public var bridgePayload: [String: Any] {
        [
            "version": unavailableReason == nil ? version as Any : NSNull(),
            "build": unavailableReason == nil ? build as Any : NSNull(),
            "sourceRevision": sourceRevision ?? NSNull(),
            "sourceDirty": sourceDirty.map { $0 as Any } ?? NSNull(),
            "sourceContentID": sourceContentID ?? NSNull(),
            "exactSourceRevision": exactSourceRevision ?? NSNull(),
            "unavailableReason": unavailableReason ?? NSNull(),
        ]
    }

    public static let launchStampFilename = "build_launch.json"

    /// Public build metadata only; independent of optional control bridges.
    public func writeLaunchStamp(root: URL, at: Date = Date()) throws {
        if let unavailableReason {
            throw NSError(domain: "NativeAgentBuildIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: unavailableReason])
        }
        let path = root.appendingPathComponent(Self.launchStampFilename)
        // A relaunch of the same build keeps the moment that build first ran; a new build starts its own.
        var firstLaunchedAt = NativeTimestampFormat.plainZulu(at)
        if let data = try? Data(contentsOf: path),
           let prior = try? JSONSerialization.jsonObject(with: data) as? [String: Any], sameBuild(as: prior),
           let first = (prior["firstLaunchedAt"] ?? prior["writtenAt"]) as? String {
            firstLaunchedAt = first
        }
        let payload: [String: Any] = [
            "version": version,
            "build": build,
            "sourceRevision": sourceRevision ?? NSNull(),
            "sourceDirty": sourceDirty.map { $0 as Any } ?? NSNull(),
            "sourceContentID": sourceContentID ?? NSNull(),
            "writtenAt": NativeTimestampFormat.plainZulu(at),
            "firstLaunchedAt": firstLaunchedAt,
            // A relaunch needs a new window identity even when the build is unchanged.
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
        ]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: path, options: .atomic)
    }

    /// Whether a stamp's identity fields name this build: version, build, source revision and content.
    public func sameBuild(as stamp: [String: Any]) -> Bool {
        guard unavailableReason == nil else { return false }
        return stamp["version"] as? String == version && stamp["build"] as? String == build
            && (stamp["sourceRevision"] as? String)?.lowercased() == sourceRevision?.lowercased()
            && (stamp["sourceContentID"] as? String)?.lowercased() == sourceContentID?.lowercased()
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
