#!/usr/bin/env swift
import Foundation

// Scan-only copy: never changes the executable that is signed or distributed. Swift ABI Mangling.rst defines symbolic references in compiler-owned typeref
// metadata as a control byte plus a 4-byte relative or 8-byte absolute pointer. Those numbers can coincidentally spell a name; they are not string literals.
enum ScanError: Error { case malformed(String) }

func scanCopy(_ input: Data) throws -> Data {
    var bytes = input
    func integer(_ offset: Int, _ width: Int) throws -> UInt64 {
        guard offset >= 0, width <= bytes.count, offset <= bytes.count - width else {
            throw ScanError.malformed("truncated Mach-O integer")
        }
        return (0..<width).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * $1) }
    }
    func name(_ offset: Int) throws -> String {
        guard offset >= 0, offset <= bytes.count - 16 else {
            throw ScanError.malformed("truncated Mach-O name")
        }
        return String(decoding: bytes[offset..<(offset + 16)].prefix { $0 != 0 }, as: UTF8.self)
    }
    guard bytes.count >= 4 else { return bytes }
    let magic = try integer(0, 4)
    guard magic == 0xfeedfacf else {
        if [0xfeedface, 0xcefaedfe, 0xcffaedfe, 0xbebafeca, 0xcafebabe,
            0xbfbafeca, 0xcafebabf].contains(magic) {
            throw ScanError.malformed("unsupported Mach-O architecture; no partial scan")
        }
        return bytes // Non-Mach-O inputs have no symbolic-reference metadata to mask.
    }
    let count = Int(try integer(16, 4))
    let commandSize = Int(try integer(20, 4))
    guard bytes.count >= 32, commandSize <= bytes.count - 32,
          count <= commandSize / 8 else { throw ScanError.malformed("invalid load-command bounds") }
    let end = 32 + commandSize
    var command = 32
    for _ in 0..<count {
        let kind = try integer(command, 4)
        let size = Int(try integer(command + 4, 4))
        guard size >= 8, command <= end - size else { throw ScanError.malformed("invalid load command") }
        if kind == 0x19 { // LC_SEGMENT_64
            guard size >= 72 else { throw ScanError.malformed("truncated segment") }
            let sections = Int(try integer(command + 64, 4))
            guard sections <= (size - 72) / 80 else { throw ScanError.malformed("invalid section count") }
            for index in 0..<sections {
                let section = command + 72 + index * 80
                guard try name(section) == "__swift5_typeref" else { continue }
                guard try name(command + 8) == "__TEXT", try name(section + 16) == "__TEXT",
                      try integer(command + 60, 4) & 2 == 0 else {
                    throw ScanError.malformed("typeref metadata is not in read-only __TEXT")
                }
                let offset = Int(try integer(section + 48, 4))
                let length = try integer(section + 40, 8)
                guard offset >= end, offset <= bytes.count, length <= UInt64(bytes.count - offset) else {
                    throw ScanError.malformed("typeref section exceeds file")
                }
                let sectionEnd = offset + Int(length)
                var cursor = offset
                while cursor < sectionEnd {
                    let tag = bytes[cursor]
                    let width = (1...0x17).contains(tag) ? 4 : ((0x18...0x1f).contains(tag) ? 8 : 0)
                    if width > 0 {
                        guard width < sectionEnd - cursor else {
                            throw ScanError.malformed("truncated symbolic reference")
                        }
                        // NUL separators preserve offsets and prevent joining the identifier fragments on either side of a pointer.
                        for position in (cursor + 1)...(cursor + width) { bytes[position] = 0 }
                    }
                    cursor += 1 + width
                }
            }
        }
        if kind == 0x1d { // LC_CODE_SIGNATURE: its page hashes are digests, never text
            guard size >= 16 else { throw ScanError.malformed("truncated code signature command") }
            try maskSignatureHashes(&bytes, at: Int(try integer(command + 8, 4)), length: Int(try integer(command + 12, 4)))
        }
        command += size
    }
    guard command == end else { throw ScanError.malformed("load-command size mismatch") }
    return bytes
}

// The embedded signature (SuperBlob) holds CodeDirectories whose hash slots are digests of every page; they change on each signing and can spell anything. Only
// those slots are zeroed: the identifier, entitlements and CMS stay scanned.
func maskSignatureHashes(_ bytes: inout Data, at start: Int, length: Int) throws {
    func big(_ offset: Int) throws -> Int {
        guard offset >= start, offset <= start + length - 4 else { throw ScanError.malformed("code signature read out of bounds") }
        return (0..<4).reduce(0) { $0 << 8 | Int(bytes[offset + $1]) }
    }
    guard start >= 0, length >= 12, start <= bytes.count - length else { throw ScanError.malformed("code signature exceeds file") }
    guard try big(start) == 0xfade0cc0 else { throw ScanError.malformed("code signature is not a SuperBlob") }
    let blobs = try big(start + 8)
    guard blobs <= (length - 12) / 8 else { throw ScanError.malformed("invalid code signature blob count") }
    for index in 0..<blobs {
        let blob = start + (try big(start + 16 + index * 8))
        guard try big(blob) == 0xfade0c02 else { continue } // CodeDirectory
        let blobLength = try big(blob + 4)
        guard blobLength >= 40, blob <= start + length - blobLength else { throw ScanError.malformed("invalid CodeDirectory length") }
        let hashOffset = try big(blob + 16), special = try big(blob + 24), code = try big(blob + 28)
        let hashSize = Int(bytes[blob + 36])
        let first = hashOffset - special * hashSize, last = hashOffset + code * hashSize
        guard hashSize > 0, first >= 40, last <= blobLength else { throw ScanError.malformed("CodeDirectory hash slots exceed the blob") }
        bytes.replaceSubrange((blob + first)..<(blob + last), with: repeatElement(0, count: last - first))
    }
}

do {
    guard CommandLine.arguments.count == 2 else { throw ScanError.malformed("expected executable path") }
    FileHandle.standardOutput.write(try scanCopy(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))))
} catch {
    FileHandle.standardError.write(Data("Mach-O identity scan failed: \(error)\n".utf8))
    exit(1)
}
