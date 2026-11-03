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

// Blueprint: | `MacFileAccess.swift` | `FileBytes`: bounded regular-file reads/appends, atomic writes, directory listing, entry moves and trash; checked entry/content readback distinguishes ENOENT from unavailable reads; `MacFileText` selects a lossless encoding from a bounded sample and returns complete-character byte windows |

public final class FileBytes: Sendable {
    public enum CheckedRead<Value: Sendable>: Sendable {
        case present(Value)
        case absent
        case unavailable(any Error)
    }

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
        let appendToExisting: Bool
        if append {
            switch entry(at: url) {
            case .present: appendToExisting = true
            case .absent: appendToExisting = false
            case .unavailable(let error): throw error
            }
        } else {
            appendToExisting = false
        }
        if appendToExisting {
            let handle = try regularFileHandle(at: url, writing: true)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
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
    public func entry(at url: URL) -> CheckedRead<Void> {
        // Entry existence includes a dangling symlink: move/trash manipulate
        // the link itself, so following it cannot verify the mutation.
        checkedRead {
            #if canImport(Darwin)
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            #else
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            #endif
        }
    }

    public func readbackData(at url: URL, maxBytes: Int, fromEnd: Bool) -> CheckedRead<Data> {
        checkedRead { try readData(at: url, maxBytes: maxBytes, fromEnd: fromEnd) }
    }

    private func checkedRead<Value: Sendable>(_ read: () throws -> Value) -> CheckedRead<Value> {
        do {
            return .present(try read())
        } catch {
            let cause = error as NSError
            if cause.domain == NSPOSIXErrorDomain, cause.code == Int(POSIXErrorCode.ENOENT.rawValue) {
                return .absent
            }
            return .unavailable(error)
        }
    }
}

/// Raw file/read is a byte window, unlike document extraction. Keep source
/// bytes (including NULs) intact and name the encoding used to interpret them.
enum MacFileText {
    struct Window {
        let data: Data
        let content: String
        let encoding: String
        let encodingSource: String
        let truncated: Bool
    }

    static func sampleLimit(for maxBytes: Int) -> Int { max(4_096, maxBytes) + 8 }

    static func window(_ probe: Data, maxBytes: Int) -> Window? {
        let sampleLimit = sampleLimit(for: maxBytes)
        let sampleCut = probe.count > sampleLimit
        var sample = Data(probe.prefix(sampleLimit))
        let encoding: String.Encoding
        let source: String
        let bomBytes: Int
        // UTF-32 LE shares UTF-16 LE's first two bytes. Judge the long BOM first.
        if sample.starts(with: [0xff, 0xfe, 0, 0]) {
            encoding = .utf32LittleEndian; source = "bom"; bomBytes = 4
        } else if sample.starts(with: [0, 0, 0xfe, 0xff]) {
            encoding = .utf32BigEndian; source = "bom"; bomBytes = 4
        } else if sample.starts(with: [0xff, 0xfe]) {
            encoding = .utf16LittleEndian; source = "bom"; bomBytes = 2
        } else if sample.starts(with: [0xfe, 0xff]) {
            encoding = .utf16BigEndian; source = "bom"; bomBytes = 2
        } else if sample.starts(with: [0xef, 0xbb, 0xbf]) {
            encoding = .utf8; source = "bom"; bomBytes = 3
        } else {
            let utf8End = sampleCut ? completeUTF8End(sample) : sample.count
            if String(data: sample.prefix(utf8End), encoding: .utf8) != nil {
                encoding = .utf8; source = "utf8_validation"; bomBytes = 0
                sample = Data(sample.prefix(utf8End))
            } else {
                // Detection is encoding selection, not replacement decoding.
                // No encoding / a lossy choice remains unavailable. Do not
                // label every non-UTF-8 file Latin-1 merely because it can map bytes.
                var lossy = ObjCBool(false)
                let detected = NSString.stringEncoding(for: sample,
                    encodingOptions: [.allowLossyKey: false],
                    convertedString: nil, usedLossyConversion: &lossy)
                guard detected != 0, !lossy.boolValue else { return nil }
                encoding = String.Encoding(rawValue: detected)
                source = "detected"; bomBytes = 0
            }
        }
        let payload = Data(sample.dropFirst(bomBytes))
        // A sample may itself end inside a Unicode scalar. Only a known sample
        // cap permits boundary trimming; malformed bytes at EOF still refuse.
        let unicodeEncodings: [String.Encoding] = [.utf8, .utf16LittleEndian, .utf16BigEndian,
                                                 .utf32LittleEndian, .utf32BigEndian]
        let unicode = unicodeEncodings.contains(encoding)
        var validSample: Data? = nil
        for dropped in 0...(sampleCut && unicode ? min(3, payload.count) : 0) {
            let candidate = Data(payload.dropLast(dropped))
            if String(data: candidate, encoding: encoding) != nil {
                validSample = candidate
                break
            }
        }
        guard let validSample else { return nil }
        // The sample is valid in this one encoding. A shorter window can only
        // fail at its terminal character; never switch decoder after a failure.
        let keptBOM = min(maxBytes, bomBytes)
        if keptBOM < bomBytes {
            return Window(data: Data(), content: "", encoding: name(encoding),
                encodingSource: source, truncated: !probe.isEmpty)
        }
        let cap = min(max(0, maxBytes - bomBytes), validSample.count)
        for dropped in 0...min(8, cap) {
            let count = cap - dropped
            guard let content = String(data: validSample.prefix(count), encoding: encoding) else { continue }
            let bytes = Data(sample.prefix(bomBytes + count))
            return Window(data: bytes, content: content, encoding: name(encoding),
                encodingSource: source, truncated: probe.count > bytes.count)
        }
        return nil
    }

    private static func name(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: "utf-8"
        case .utf16LittleEndian: "utf-16le"
        case .utf16BigEndian: "utf-16be"
        case .utf32LittleEndian: "utf-32le"
        case .utf32BigEndian: "utf-32be"
        case .isoLatin1: "iso-8859-1"
        case .windowsCP1252: "windows-1252"
        default: String.localizedName(of: encoding)
        }
    }

    /// Only an unfinished, otherwise valid terminal UTF-8 scalar is a boundary.
    private static func completeUTF8End(_ data: Data) -> Int {
        let tail = Array(data.suffix(3))
        for index in tail.indices {
            let width: Int
            switch tail[index] {
            case 0xc2...0xdf: width = 2
            case 0xe0...0xef: width = 3
            case 0xf0...0xf4: width = 4
            default: continue
            }
            let count = tail.count - index
            guard count < width, tail.dropFirst(index + 1).allSatisfy({ (0x80...0xbf).contains($0) }) else { continue }
            if count > 1 {
                let second = tail[index + 1]
                if (tail[index] == 0xe0 && second < 0xa0) || (tail[index] == 0xed && second > 0x9f)
                    || (tail[index] == 0xf0 && second < 0x90) || (tail[index] == 0xf4 && second > 0x8f) { continue }
            }
            return data.count - count
        }
        return data.count
    }
}
