import Foundation

/// Exact identity of the bytes currently running inside the app bundle.
///
/// Development and release builders stamp these values before signing. The
/// source revision is useful only together with `sourceDirty`: a dirty build is
/// intentionally never presented as exact proof of the named commit.
struct NativeAgentBuildIdentity: Sendable, Equatable {
    let version: String
    let build: String
    let sourceRevision: String?
    let sourceDirty: Bool

    static var current: NativeAgentBuildIdentity {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:], resourcesURL: Bundle.main.resourceURL)
    }

    static func from(
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
            sourceDirty: stampedDirty || !revisionStampsAgree
        )
    }

    var exactSourceRevision: String? {
        guard !sourceDirty,
              let sourceRevision,
              Self.isFullGitObjectID(sourceRevision) else {
            return nil
        }
        return sourceRevision.lowercased()
    }

    var bridgePayload: [String: Any] {
        [
            "version": version,
            "build": build,
            "sourceRevision": sourceRevision ?? NSNull(),
            "sourceDirty": sourceDirty,
            "exactSourceRevision": exactSourceRevision ?? NSNull(),
        ]
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
