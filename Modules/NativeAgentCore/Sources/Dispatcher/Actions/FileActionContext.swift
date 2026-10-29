import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import MacControl
import PersistenceCore
import TrustCenter
#if canImport(Darwin)
import Darwin
import Darwin
#endif
// Blueprint: | `FileActionContext.swift` | File source, path authority and authenticated connector context |
let connectorReadFileDefaultMaxBytes = 200_000
/// Compact default for long handoff markdown files, unless max_bytes is explicit.
let connectorReadFileHandoffDefaultMaxBytes = 12_000
let connectorListDirMaxEntries = 200
let connectorResultMaxChars = 30_000
/// Senses request path + size through the existing read fences and verified
/// descriptor. Ordinary file reads never bind this port.
public enum FileReadSourceMaterial {
    @TaskLocal public static var metadataOnly = false
    /// What files.read itself returns real content for: images and text, by
    /// content. Anything else is foreign bytes to it, so a sense serves it.
    public static func nativeReadSupported(path: String) -> Bool {
        let path = (path as NSString).expandingTildeInPath
        return VerifiedImageRead.isImagePath(URL(fileURLWithPath: path)) || !isBinary(path: path)
    }
    /// Binary by content, never by extension: a NUL byte or invalid UTF-8 in
    /// the first 8 KB (a scalar cut at the sample's end is not invalid).
    public static func isBinary(path: String) -> Bool {
        let path = (path as NSString).expandingTildeInPath
        // A document package (.pages, .numbers, .key, .rtfd) is foreign too.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        // Failed admission stays on the native route, whose reader reports
        // the error. In particular, opening a pipe must never wait for a writer.
        guard let handle = try? FileSystemActions.openRegularReadHandle(URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return (try? isBinary(handle: handle)) ?? false
    }
    /// Classify the admitted file without reopening its pathname or consuming
    /// bytes from the subsequent read.
    static func isBinary(handle: FileHandle) throws -> Bool {
        let offset = try handle.offset()
        try handle.seek(toOffset: 0)
        let sample = try handle.read(upToCount: 8192) ?? Data()
        try handle.seek(toOffset: offset)
        if sample.contains(0) { return true }
        if String(data: sample, encoding: .utf8) != nil { return false }
        for cut in 1...3 where sample.count > cut {
            if String(data: sample.dropLast(cut), encoding: .utf8) != nil { return false }
        }
        return true
    }
}
/// Sensitive data subpaths stay fenced even when allowed roots include data_root.
let connectorSensitiveDataSubpaths: Set<String> = [
    "oauth",
    "oauth_tokens",
    "secrets",
    "security",
    "trust",
    "pairings",
    "providers",
    "codex_home",
    "codex_child_home",
    "macctl_bridge.json",
    "browser_ipc.json",
    "trust_policy.json",
    "senses/ledger",
    "senses/news",
]
// App-data reach excludes private stores.
let connectorPartPrivateDataSubpaths = [
    "credentials", "connectors", "telegram/config.json", "slack/config.json",
    "mobile", "mobile_push", "notifications/push_tokens.json",
    "claude", "bridge-config",
]
/// Connector context retains resolved roots and the call's file-access policy.
public struct ConnectorActionContext: Sendable {
    /// Resolution base for reads/repository paths + an always-allowed root.
    public var repoRoot: URL?
    /// file_access dict: mode, sandbox, writableRoots, addDirs. Open-shape.
    public var fileAccess: [String: JSONValue]
    /// data root used for the sensitive-path block + data/skills allowance.
    public var dataRoot: URL?
    /// Explicit allowed roots beyond repo_root (persona root, workspace root).
    public var extraAllowedRoots: [URL]
    /// Persona root (SOUL.md / USER.md / VOICE.md / GROWTH.md / AGENTS.md +
    /// `skills/bodies/`). When nil, persona reads use defaultPersonaRoot for
    /// the context's data root.
    public var personaRoot: URL?
    /// Workspace aliases in file reads and the root for `workspace_list`.
    public var workspaceRoot: URL?
    let appDataWrite: Bool?
    public init(
        repoRoot: URL?,
        fileAccess: [String: JSONValue] = [:],
        dataRoot: URL? = nil,
        extraAllowedRoots: [URL] = [],
        personaRoot: URL? = nil,
        workspaceRoot: URL? = nil
    ) {
        let dataRoot = dataRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.repoRoot = repoRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.fileAccess = fileAccess
        self.dataRoot = dataRoot
        self.extraAllowedRoots = extraAllowedRoots
        self.personaRoot = personaRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.workspaceRoot = workspaceRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        if let reach = AbilityStore.fileReach, let dataRoot,
           reach.root.standardizedFileURL.resolvingSymlinksInPath().path == dataRoot.standardizedFileURL.resolvingSymlinksInPath().path {
            self.appDataWrite = reach.write
        } else { self.appDataWrite = nil }
    }
    /// Dispatch roots stay in-process; only the file-access dictionary is JSON.
    public static func fromDispatch(_ ctx: DispatchContext) -> ConnectorActionContext {
        var fa: [String: JSONValue] = [:]
        if case .object(let obj)? = ctx.extra["file_access"] { fa = obj }
        return ConnectorActionContext(
            repoRoot: ctx.repoRoot,
            fileAccess: fa,
            dataRoot: ctx.dataRoot,
            extraAllowedRoots: ctx.extraAllowedRoots,
            workspaceRoot: ctx.workspaceRoot
        )
    }
}
/// Basic and Full Mac readers share the same sensitive-subtree fence.
public func connectorPathIsSensitiveData(_ path: URL, dataRoot: URL) -> Bool {
    FileSystemActions.isSensitiveDataPath(
        path,
        ConnectorActionContext(repoRoot: nil, dataRoot: dataRoot)
    )
}
extension SwiftNativeSecurityCenter {
    public struct AttachmentRefusal: Error { public let reason: String; public let detail: String }
    /// The fence `read_file` keeps, for a regular file the agent attaches: never a
    /// sensitive store, in any posture; and inside a Trust workspace root
    /// unless this Mac is in Full Mac. A relative path is read against her
    /// workspace, as `read_file` reads it. make.add, the composer,
    /// reply.attach and a resumed turn's reply all keep it.
    public static func fencedAttachment(_ raw: String, dataRoot: URL) async -> Result<URL, AttachmentRefusal> {
        let file = NativeAgentWorkspaceRoot.resolveFileMutationPath(raw, dataRoot: dataRoot)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .failure(.init(reason: "attachment_missing",
                detail: "No regular file is at \(file.path). Check the path with app files.list, then try again."))
        }
        guard !connectorPathIsSensitiveData(file, dataRoot: dataRoot) else {
            return .failure(.init(reason: "path_not_allowed", detail: FileSystemActions.sensitiveReadRefusal(file)))
        }
        guard let policy = try? await SwiftNativeTrustCenter(dataRoot: dataRoot).loadTrustPolicyChecked() else {
            return .failure(.init(reason: "trust_mode_unreadable",
                detail: "The saved Trust policy could not be read, so no file was attached. The person can check Trust."))
        }
        if PermissionLaw.posture(policy) == .fullMac { return .success(file) }
        guard isInsideTrustedWorkspace(file, policy: policy, dataRoot: dataRoot) else {
            return .failure(.init(reason: "attachment_outside_workspace",
                detail: "\(file.path) is outside your Trust workspace folders, the same fence app files.read keeps. "
                + "Ask the owner to attach it themselves, or to add its folder to the workspace roots in Trust."))
        }
        return .success(file)
    }
}
