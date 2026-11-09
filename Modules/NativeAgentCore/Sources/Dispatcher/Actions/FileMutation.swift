import AuthoredCapabilities
import Foundation
import CryptoKit
import NativeAgentCore
import NativeAgentShared
import MacControl
import PersistenceCore
import TrustCenter
#if canImport(Darwin)
import Darwin
import Darwin
#endif
// Blueprint: | `FileMutation.swift` | Guarded write, transfer and Trash operations |
extension FileSystemActions {
    static func isLink(_ entry: URL) -> Bool {
        (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }
    /// Fence both a symlink's parent and its target: moving the link changes its containing folder.
    static func entryFolderRefusal(_ entry: URL, _ ctx: ConnectorActionContext) -> JSONValue? {
        guard isLink(entry) else { return nil }
        let folder = entry.deletingLastPathComponent()
        let allowed = allowedRoots(ctx, write: true)
        if !allowed.isEmpty && !isWithinRoots(folder, allowed) {
            return errResult("Path '\(entry.path)' is outside writable sandbox roots: \(rootsRepr(allowed))", code: "path_not_allowed")
        }
        if isSensitiveDataPath(folder, ctx) {
            return errResult("Path '\(entry.path)' is under a sensitive data sub-tree. Use dedicated Swift runtime tools instead.", code: "path_not_allowed")
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: entry.path, write: true) {
            return errResult(reason, code: "path_not_allowed")
        }
        return nil
    }
    static func mutationRefusal(_ resolved: URL, _ ctx: ConnectorActionContext, write: Bool = true) -> JSONValue? {
        if write, ctx.turn?.fileAccessCeiling.readOnly == true {
            return errResult("request.fileAccess=read_only blocks file changes. The request issuer must resubmit with write access.",
                code: "path_not_allowed")
        }
        if ctx.appDataWrite != nil, write {
            let dataRoot = ctx.dataRoot ?? PersistenceCore.defaultDataRoot()
            let protected = (Array(connectorSensitiveDataSubpaths) + connectorPartPrivateDataSubpaths + CapabilityLifecycle.protectedStores)
                .map { dataRoot.appendingPathComponent($0) }
                + [ctx.personaRoot ?? PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot)]
            if protected.contains(where: { isWithinRoots(resolved, [$0]) || isWithinRoots($0, [resolved]) }) {
                return errResult("The path reaches a protected app store or executable authority.", code: "path_not_allowed")
            }
        }
        if write {
            do {
                try CapabilityLifecycle.requireFileMutation(resolved,
                    dataRoot: ctx.dataRoot ?? PersistenceCore.defaultDataRoot(),
                    personaRoot: ctx.personaRoot, turn: ctx.turn)
            } catch { return errResult(error.localizedDescription, code: "path_not_allowed") }
        }
        let allowed = allowedRoots(ctx, write: write)
        if ((ctx.fileAccess["sandbox"]?.stringValue ?? "") == "read-only" || (ctx.fileAccess["mode"]?.stringValue ?? "") == "read_only"),
           !(ctx.appDataWrite == true && ctx.dataRoot.map { isWithinRoots(resolved, [$0]) } == true) {
            return errResult("Sandbox is read-only — cannot write files. Request write access for this session.", code: "path_not_allowed")
        }
        if !allowed.isEmpty && !isWithinRoots(resolved, allowed) {
            return errResult("Path '\(resolved.path)' is outside writable sandbox roots: \(rootsRepr(allowed))", code: "path_not_allowed")
        }
        if isSensitiveDataPath(resolved, ctx) {
            return errResult("Path '\(resolved.path)' is under a sensitive data sub-tree. Use dedicated Swift runtime tools instead.", code: "path_not_allowed")
        }
        if let reason = MacControlSensitivePathFence.protectedSystemMutationReason(forPath: resolved.path, write: write) {
            return errResult(reason, code: "path_not_allowed")
        }
        return nil
    }
    static func trashFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = input["path"]?.stringValue ?? ""
        guard !rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errResult("path is required", code: "bad_input")
        }
        let dataRoot = ctx.dataRoot ?? PersistenceCore.defaultDataRoot()
        // Trash the link itself; fence its parent and target so either spelling respects write authority.
        let entry = NativeAgentWorkspaceRoot.resolveFileEntryPath(rawPath, dataRoot: dataRoot)
        let resolved = NativeAgentWorkspaceRoot.resolveFileMutationPath(rawPath, dataRoot: dataRoot)
        if let refusal = entryFolderRefusal(entry, ctx) ?? mutationRefusal(resolved, ctx) { return refusal }
        if isWithinRoots(dataRoot, [resolved]) {
            return errResult("Cannot trash NativeAgent's data root or a folder containing it.", code: "path_not_allowed")
        }
        do {
            var destination: NSURL?
            try FileManager.default.trashItem(at: entry, resultingItemURL: &destination)
            return .object(["ok": .bool(true), "status": .string("completed"),
                "path": .string(entry.path), "trash_path": destination?.path.map(JSONValue.string) ?? .null,
                "message": .string("Moved to the Trash. Restore it from the Trash if needed.")])
        } catch { return errResult(error.localizedDescription, code: "trash_failed") }
    }
    static func transferFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext, copy: Bool) -> JSONValue {
        let path = input["path"]?.stringValue ?? "", destination = (input["destination"]?.stringValue ?? "")
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return errResult("path and destination are required; destination is the complete new path, including the filename.", code: "bad_input")
        }
        if let overwrite = input["overwrite"], overwrite != .null {
            guard case .bool = overwrite else { return errResult("overwrite must be true or false.", code: "bad_input") }
        }
        let dataRoot = ctx.dataRoot ?? PersistenceCore.defaultDataRoot()
        // Moves act on named entries and their containing folders; copies read and write the resolved targets.
        let resolvedSource = NativeAgentWorkspaceRoot.resolveFileMutationPath(path, dataRoot: dataRoot)
        let resolvedTarget = NativeAgentWorkspaceRoot.resolveFileMutationPath(destination, dataRoot: dataRoot)
        let source = copy ? resolvedSource : NativeAgentWorkspaceRoot.resolveFileEntryPath(path, dataRoot: dataRoot)
        let target = copy ? resolvedTarget : NativeAgentWorkspaceRoot.resolveFileEntryPath(destination, dataRoot: dataRoot)
        if !copy, let refusal = entryFolderRefusal(source, ctx) ?? entryFolderRefusal(target, ctx) { return refusal }
        for url in [resolvedSource, resolvedTarget] {
            if let refusal = mutationRefusal(url, ctx, write: !copy || url == resolvedTarget) { return refusal }
        }
        // Only a folder can contain its destination; a moved link carries no subtree.
        guard source != target, (!copy && isLink(source)) || !isWithinRoots(target, [source]),
              !isWithinRoots(dataRoot, [resolvedSource]) else {
            return errResult(
                "Cannot transfer an item onto itself, into itself, or transfer NativeAgent's data root or a folder containing it.", code: "path_not_allowed")
        }
        // A folder transfer carries its whole subtree; refuse unreadable trees and sensitive stores in either direction.
        if isWithinRoots(source, [dataRoot]) || isWithinRoots(target, [dataRoot]),
           (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            var unreadable: URL?
            let tree = FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil) { url, _ in unreadable = url; return false }
            while let url = tree?.nextObject() as? URL {
                guard let relative = NativeAgentWorkspaceRoot.relativePath(url.path, under: source.path), !relative.isEmpty else { unreadable = url; break }
                if isSensitiveDataPath(source.appendingPathComponent(relative), ctx) || isSensitiveDataPath(target.appendingPathComponent(relative), ctx) {
                    return errResult("""
                        Path '\(source.path)/\(relative)' is under a sensitive data sub-tree, so the folder holding it is not moved. Move the other \
                        files individually.
                        """, code: "path_not_allowed")
                }
            }
            if tree == nil || unreadable != nil {
                return errResult("""
                    '\((unreadable ?? source).path)' does not read, so what the folder holds cannot be checked and it is not moved. Move the \
                    files you can read individually.
                    """, code: "path_not_allowed")
            }
        }
        do {
            try VerifiedPath.transfer(from: source, to: target, copy: copy, overwrite: input["overwrite"] == .bool(true))
            return .object(["ok": .bool(true), "status": .string("completed"), "path": .string(source.path),
                "destination": .string(target.path), "operation": .string(copy ? "copy" : "move")])
        } catch VerifiedPath.Failure.posix(EEXIST) {
            return errResult(
                "Destination already exists. Choose another path or set overwrite:true only when replacement was requested.", code: "destination_exists")
        } catch VerifiedPath.Failure.posix(EXDEV) {
            return errResult("""
                Move requires source and destination on the same filesystem. Copy the file explicitly before deciding whether to trash the \
                original.
                """, code: "cross_device_move")
        } catch let failure as VerifiedPath.Failure { return errResult(failure.message, code: failure.code) }
        catch { return errResult(error.localizedDescription, code: "transfer_failed") }
    }
    static func writeFile(_ input: [String: JSONValue], _ ctx: ConnectorActionContext) -> JSONValue {
        let rawPath = input["path"]?.stringValue ?? ""
        if rawPath.isEmpty { return errResult("path is required", code: "bad_input") }
        guard let contentVal = input["content"], !isNull(contentVal) else {
            return errResult("content is required", code: "bad_input")
        }
        let content: String
        do { content = try jsonToStr(contentVal) }
        catch { return errResult("Content could not be serialized: \(error.localizedDescription)", code: "bad_input") }
        let append: Bool
        if let value = input["append"] {
            guard case .bool(let requested) = value else {
                return errResult("append must be true or false, or omitted for replacement.", code: "bad_input")
            }
            append = requested
        } else { append = false }
        let expectedHash: String?
        let blankHash: Bool = {
            if case .string(let s)? = input["expected_content_sha256"] {
                return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }()
        if let value = input["expected_content_sha256"], value != .null, !blankHash {
            guard case .string(let hash) = value, hash.count == 64,
                  hash.unicodeScalars.allSatisfy({ (48...57).contains($0.value) || (97...102).contains($0.value) }) else {
                return errResult("expected_content_sha256 must be a 64-character lowercase hex SHA-256, or omitted.", code: "bad_input")
            }
            guard !append else {
                return errResult("expected_content_sha256 guards a replacement; it cannot be used with append=true.", code: "bad_input")
            }
            expectedHash = hash
        } else { expectedHash = nil }
        let dataRoot = ctx.dataRoot ?? PersistenceCore.defaultDataRoot()
        let resolved = NativeAgentWorkspaceRoot.resolveFileMutationPath(rawPath, dataRoot: dataRoot)
        if let refusal = mutationRefusal(resolved, ctx) { return refusal }
        // Bound before_content to 200 kB for overwrite diffs; appends do not replace prior content.
        var beforeContent: String? = nil
        do {
            // Open each parent O_DIRECTORY|O_NOFOLLOW from the root and operate relative to the final descriptor. mkdirat creates missing parents there too, so
            // a symlink swap cannot redirect creation or writing.
            let verified = try VerifiedPath.openParent(of: resolved, createIntermediates: expectedHash == nil)
            defer { verified.release() }
            let data = Data(content.utf8)
            if append {
                // Kernel EOF append avoids losing concurrent payloads across separate exists/seek/write calls.
                let fd: Int32
                do {
                    // Darwin exclusive creation gives concurrent callers one creator and one existing-file open.
                    fd = try VerifiedPath.openFinal(
                        verified, flags: O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NONBLOCK, mode: 0o666)
                } catch VerifiedPath.Failure.posix(EEXIST) {
                    fd = try VerifiedPath.openFinal(
                        verified, flags: O_WRONLY | O_APPEND | O_NONBLOCK)
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var metadata = stat()
                guard fstat(fd, &metadata) == 0,
                      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                      metadata.st_nlink == 1 else {
                    return errResult("Append requires a regular file without hard links.", code: "path_not_allowed")
                }
                ctx.didOpenAppendHandle?()
                // Foundation checks complete writes and I/O errors; append still cannot promise cross-caller transactionality.
                if let refusal = mutationRefusal(resolved, ctx) { return refusal }
                try handle.write(contentsOf: data)
            } else {
                var existingMetadata = stat()
                let existingMode: mode_t?
                if fstatat(verified.fd, verified.name, &existingMetadata, AT_SYMLINK_NOFOLLOW) == 0 {
                    guard existingMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                        return errResult("Overwrite requires a regular file.", code: "path_not_allowed")
                    }
                    existingMode = existingMetadata.st_mode & 0o777
                } else if errno == ENOENT {
                    existingMode = nil
                } else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                if let fd = try? VerifiedPath.openFinal(verified, flags: O_RDONLY | O_NONBLOCK) {
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    var metadata = stat()
                    if fstat(fd, &metadata) == 0,
                       metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                       metadata.st_size <= 200_000,
                       let before = try? handle.read(upToCount: 200_000) {
                        beforeContent = String(data: before, encoding: .utf8)
                    }
                    try? handle.close()
                }
                // Replace atomically inside the verified parent; defer removes the temporary file on every exit.
                let tmpName = "\(resolved.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString.prefix(8)).tmp"
                let tmpFD = openat(
                    verified.fd, tmpName,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    existingMode == nil ? 0o666 : 0o600)
                guard tmpFD >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                defer { _ = unlinkat(verified.fd, tmpName, 0) }
                let tmpHandle = FileHandle(fileDescriptor: tmpFD, closeOnDealloc: true)
                defer { try? tmpHandle.close() }
                try tmpHandle.write(contentsOf: data)
                // Preserve private and executable modes; keep replacement private until content is complete.
                if let existingMode, fchmod(tmpFD, existingMode) != 0 {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                try tmpHandle.close()
                if let expectedHash {
                    // Read expected bytes through the verified parent immediately before replacing; this is not cross-process CAS.
                    do {
                        let currentFD = try VerifiedPath.openFinal(verified, flags: O_RDONLY | O_NONBLOCK)
                        let current = FileHandle(fileDescriptor: currentFD, closeOnDealloc: true)
                        defer { try? current.close() }
                        var digest = SHA256(), offset = 0, totalBytes = 0, version = ""
                        repeat {
                            let window = try readFileWindow(handle: current, path: resolved,
                                maxBytes: connectorReadFileDefaultMaxBytes, useCompactDefault: false,
                                offset: offset, expectedVersion: version, preserveInvalidUTF8: true)
                            guard !window.data.isEmpty || window.totalBytes == 0 else {
                                throw FileReadFailure(message: "Could not hash the complete original file.", code: "file_changed")
                            }
                            digest.update(data: window.data)
                            offset += window.data.count
                            totalBytes = window.totalBytes
                            version = window.version
                        } while offset < totalBytes
                        var opened = stat(), named = stat()
                        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == expectedHash,
                              fstat(currentFD, &opened) == 0,
                              fstatat(verified.fd, verified.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else {
                            return errResult("""
                                The file does not match expected_content_sha256 (use the content_sha256 from a whole-file read, not version). Read it \
                                again before revising; nothing was written.
                                """, code: "file_changed")
                        }
                    } catch {
                        return errResult("The original file could not be verified. Read it again before revising; nothing was written.", code: "file_changed")
                    }
                }
                if let refusal = mutationRefusal(resolved, ctx) { return refusal }
                if renameat(verified.fd, tmpName, verified.fd, verified.name) != 0 {
                    let err = String(cString: strerror(errno))
                    return errResult("atomic write failed: \(err)")
                }
            }
        } catch let failure as VerifiedPath.Failure {
            return errResult(failure.message, code: failure.code)
        } catch {
            return errResult(error.localizedDescription)
        }
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "path": .string(resolved.path),
            "bytes_written": .int(Int64(Data(content.utf8).count)),
            "status": .string("saved"),
            "append": .bool(append),
        ]
        if !append {
            if let bc = beforeContent {
                result["before_content"] = .string(String(bc.prefix(8000)))
            }
            result["after_content"] = .string(String(content.prefix(8000)))
        }
        return .object(result)
    }
}
