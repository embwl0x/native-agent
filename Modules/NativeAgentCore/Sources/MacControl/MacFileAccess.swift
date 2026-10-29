import Foundation
import NativeAgentCore
import PersistenceCore
import Senses
import TrustCenter
#if canImport(Darwin)
import Darwin
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
#if canImport(AppKit)
import AppKit
import Carbon
import OSAKit
import os
#endif

// Blueprint: | `MacFileAccess.swift` | `FileBytes`: bounded regular-file reads/appends, atomic writes, directory listing, verified entry moves and trash |

public final class FileBytes: Sendable {
    public init() {}
    // FileManager.default is NOT Sendable as of Swift 6 — fetch per-call
    // instead of storing on the actor/adapter. Per Apple's own audit it's
    // thread-safe for these operations even though the type lacks
    // the Sendable bill of health.
    public func readData(at url: URL, maxBytes: Int, fromEnd: Bool = false) throws -> Data {
        let handle = try regularFileHandle(at: url, writing: false)
        defer { try? handle.close() }
        if fromEnd {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: end - min(end, UInt64(max(0, maxBytes))))
        }
        return try handle.read(upToCount: max(0, maxBytes)) ?? Data()
    }
    private func regularFileHandle(at url: URL, writing: Bool) throws -> FileHandle {
        #if canImport(Darwin)
        // A FIFO blocks during open, before FileHandle can impose any read
        // limit. Inspect the opened descriptor, not a racy path preflight.
        let flags = writing ? O_WRONLY | O_APPEND : O_RDONLY
        let fd = Darwin.open(url.path, flags | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(fd)
            throw POSIXError(code)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(fd)
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                NSLocalizedDescriptionKey: "I can only read or append to a regular file.",
            ])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        #else
        return try writing ? FileHandle(forWritingTo: url) : FileHandle(forReadingFrom: url)
        #endif
    }
    public func writeData(_ data: Data, to url: URL, append: Bool) throws {
        let fm = FileManager.default
        if append, fm.fileExists(atPath: url.path) {
            let handle = try regularFileHandle(at: url, writing: true)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            let parent = url.deletingLastPathComponent()
            if !fm.fileExists(atPath: parent.path) {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            // A failed replacement (including a full disk) must leave the
            // previous file intact, rather than truncating it before writing.
            try data.write(to: url, options: .atomic)
        }
    }
    public func listDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }
    public func moveItem(from src: URL, to dst: URL) throws {
        // Resolve parent aliases, retaining the final entry as the moved object.
        func entry(_ url: URL) -> URL {
            url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        }
        try VerifiedPath.transfer(from: entry(src), to: entry(dst), copy: false, overwrite: false)
    }
    public func trashItem(at url: URL) throws {
        var resulting: NSURL? = nil
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
    public func itemExists(at url: URL) -> Bool {
        // Entry existence includes a dangling symlink: move/trash manipulate
        // the link itself, so following it cannot verify the mutation.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}
