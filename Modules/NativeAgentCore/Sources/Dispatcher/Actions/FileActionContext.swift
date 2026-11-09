import NativeAgentShared
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
// Blueprint: | `FileActionContext.swift` | File path authority and connector context; Trust-fenced descriptor-bound attachments |
let connectorReadFileDefaultMaxBytes = 200_000
/// Keep long handoff markdown compact unless the caller explicitly requests max_bytes.
let connectorReadFileHandoffDefaultMaxBytes = 12_000
let connectorListDirMaxEntries = 200
let connectorResultMaxChars = 30_000
/// One file operation's read shape and admitted image continuation.
public struct FileReadOptions: Sendable {
    public var metadataOnly: Bool
    public var imageSink: LocalToolImage.Sink?
    public init(metadataOnly: Bool = false, imageSink: LocalToolImage.Sink? = nil) {
        self.metadataOnly = metadataOnly; self.imageSink = imageSink
    }
}
/// Senses reuse verified descriptors and read fences for metadata without binding ordinary file reads.
public enum FileReadSourceMaterial {
    /// Text and images are readable content; foreign bytes need a sense.
    public static func nativeReadSupported(path: String) -> Bool {
        let path = (path as NSString).expandingTildeInPath
        return VerifiedImageRead.isImagePath(URL(fileURLWithPath: path)) || !isBinary(path: path)
    }
    /// Classify by content, never extension; a UTF-8 scalar cut at the 8 KB sample boundary is not invalid.
    public static func isBinary(path: String) -> Bool {
        let path = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue { return true }
        // Failed admission stays with the native error owner; opening a pipe must never wait for a writer.
        guard let handle = try? FileSystemActions.openRegularReadHandle(URL(fileURLWithPath: path)) else { return false }
        defer { try? handle.close() }
        return (try? isBinary(handle: handle)) ?? false
    }
    /// Classify the admitted descriptor without reopening its path or consuming the subsequent read.
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
let connectorPartPrivateDataSubpaths = [
    "credentials", "connectors", "telegram/config.json", "slack/config.json",
    "mobile", "mobile_push", "notifications/push_tokens.json",
    "claude", "bridge-config",
]
public struct ConnectorActionContext: Sendable {
    public var turn: Turn?
    public var readOptions: FileReadOptions
    public var didOpenAppendHandle: (@Sendable () -> Void)?
    public var repoRoot: URL?
    public var fileAccess: [String: JSONValue]
    public var dataRoot: URL?
    public var extraAllowedRoots: [URL]
    /// An absent explicit root resolves through defaultPersonaRoot for this context's data root.
    public var personaRoot: URL?
    public var workspaceRoot: URL?
    var appDataWrite: Bool? {
        guard let reach = turn?.fileReach, let dataRoot,
              reach.root.standardizedFileURL.resolvingSymlinksInPath().path == dataRoot.standardizedFileURL.resolvingSymlinksInPath().path else { return nil }
        return reach.write
    }
    public init(
        repoRoot: URL?,
        fileAccess: [String: JSONValue] = [:],
        dataRoot: URL? = nil,
        extraAllowedRoots: [URL] = [],
        personaRoot: URL? = nil,
        workspaceRoot: URL? = nil,
        turn: Turn?,
        readOptions: FileReadOptions = .init(),
        didOpenAppendHandle: (@Sendable () -> Void)? = nil
    ) {
        let dataRoot = dataRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.repoRoot = repoRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.fileAccess = fileAccess
        self.dataRoot = dataRoot
        self.extraAllowedRoots = extraAllowedRoots
        self.personaRoot = personaRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.workspaceRoot = workspaceRoot.flatMap { $0.path.isEmpty ? nil : $0 }
        self.turn = turn; self.readOptions = readOptions; self.didOpenAppendHandle = didOpenAppendHandle
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
            workspaceRoot: ctx.workspaceRoot,
            turn: ctx.turn, readOptions: ctx.fileReadOptions
        )
    }
}
/// Basic and Full Mac readers share the same sensitive-subtree fence.
public func connectorPathIsSensitiveData(_ path: URL, dataRoot: URL, turn: Turn?) -> Bool {
    FileSystemActions.isSensitiveDataPath(
        path,
        ConnectorActionContext(repoRoot: nil, dataRoot: dataRoot, turn: turn)
    )
}
extension SwiftNativeSecurityCenter {
    /// Send only complete bytes from the inspected descriptor; reopening the pathname could send different content.
    package static func outgoingAttachment(_ raw: String, dataRoot: URL, maximumBytes: Int, turn: Turn?) async throws -> (file: URL, bytes: Data) {
        let file: URL
        switch await fencedAttachment(raw, dataRoot: dataRoot, turn: turn) {
        case .success(let admitted): file = admitted
        case .failure(let refusal):
            throw ToolFailureError(refusal.detail, argumentPath: "files", effects: .none)
        }
        let handle: FileHandle
        do { handle = try FileSystemActions.openRegularReadHandle(file) }
        catch { throw ToolFailureError("The attachment could not be opened as a regular file. Nothing was sent.", argumentPath: "files", effects: .none) }
        defer { try? handle.close() }
        var bytes = Data()
        do {
            while true {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: min(65536, maximumBytes - bytes.count + 1)) ?? Data()
                if chunk.isEmpty { break }
                guard chunk.count <= maximumBytes - bytes.count else {
                    throw ToolFailureError("Attachments exceed the 8 MiB total limit. Nothing was sent.", argumentPath: "files", effects: .none)
                }
                bytes.append(chunk)
            }
        } catch let failure as ToolFailureError { throw failure }
        catch is CancellationError { throw CancellationError() }
        catch { throw ToolFailureError("The attachment could not be read completely. Nothing was sent.", argumentPath: "files", effects: .none) }
        guard !bytes.isEmpty else {
            throw ToolFailureError(
                "An attachment is empty (possibly still being written). Nothing was sent; wait for the completed file.", argumentPath: "files", effects: .none)
        }
        // Inspect binary credentials literally; incidental %HH bytes cannot establish URL-encoded text.
        let text = bytes.contains(0) ? nil : String(data: bytes, encoding: .utf8)
        let unsafeContent = text.map { ContextSecretContentPolicy.redactedFragment($0) != $0 }
            ?? ContextSecretContentPolicy.containsLiteralSecretLikeContent(String(decoding: bytes, as: UTF8.self))
        guard !unsafeContent,
              ContextSecretContentPolicy.redactedFragment(file.lastPathComponent) == file.lastPathComponent else {
            throw ToolFailureError("""
                An attachment contains credential-shaped content or a secret-bearing filename. Nothing was sent; create a safe export \
                without secrets.
                """, argumentPath: "files", effects: .none)
        }
        return (file, bytes)
    }

    public struct AttachmentRefusal: Error { public let reason: String; public let detail: String }
    /// Attachments share the read fence: never sensitive stores, and inside Trust roots unless Full Mac applies. Resolve relative paths against the workspace;
    /// composer, make.add and resumed replies keep the same fence.
    public static func fencedAttachment(_ raw: String, dataRoot: URL, turn: Turn?) async -> Result<URL, AttachmentRefusal> {
        let file = NativeAgentWorkspaceRoot.resolveFileMutationPath(raw, dataRoot: dataRoot)
        guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            return .failure(.init(reason: "attachment_missing",
                detail: "No regular file is at \(file.path). Check the path with app files.list, then try again."))
        }
        guard !connectorPathIsSensitiveData(file, dataRoot: dataRoot, turn: turn) else {
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
