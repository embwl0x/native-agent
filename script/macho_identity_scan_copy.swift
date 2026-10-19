#!/usr/bin/env swift
import Foundation

// Scan-only copy: never changes the executable that is signed or distributed.
// Swift ABI Mangling.rst defines symbolic references in compiler-owned typeref
// metadata as a control byte plus a 4-byte relative or 8-byte absolute pointer.
// Those numbers can coincidentally spell a name; they are not string literals.
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
        return bytes // Shell scripts and existing non-Mach-O scanner fixtures.
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
                        // NUL separators preserve offsets and prevent joining
                        // the identifier fragments on either side of a pointer.
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

// The embedded signature (SuperBlob) holds CodeDirectories whose hash slots are
// digests of every page; they change on each signing and can spell anything.
// Only those slots are zeroed: the identifier, entitlements and CMS stay scanned.
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

func selfTest() throws {
    func fixture(_ payload: [UInt8], sectionName: String = "__swift5_typeref") -> Data {
        var data = Data(repeating: 0, count: 32 + 72 + 80)
        func put(_ offset: Int, _ value: UInt64, _ width: Int = 4) {
            for i in 0..<width { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
        }
        func text(_ offset: Int, _ value: String) {
            for (i, byte) in value.utf8.enumerated() { data[offset + i] = byte }
        }
        put(0, 0xfeedfacf); put(16, 1); put(20, 152)
        put(32, 0x19); put(36, 152); text(40, "__TEXT"); put(92, 5); put(96, 1)
        text(104, sectionName); text(120, "__TEXT")
        put(144, UInt64(payload.count), 8); put(152, 184)
        data.append(contentsOf: payload)
        return data
    }
    let triplet = Array("Qzx".utf8)
    let relative = fixture([2] + triplet + [0, 0])
    let absolute = fixture([0x18] + Array("QzxABCDE".utf8) + [0])
    guard try !scanCopy(relative).suffix(6).contains(triplet[0]),
          try !scanCopy(absolute).suffix(10).contains(triplet[0]) else {
        throw ScanError.malformed("numeric references were not masked")
    }
    for section in ["__swift5_typeref", "__cstring", "__swift5_reflstr"] {
        let literal = fixture(triplet + [0], sectionName: section)
        guard try scanCopy(literal) == literal else { throw ScanError.malformed("real short literal was hidden") }
    }
    let nonMetadata = fixture([2] + triplet + [0, 0], sectionName: "__cstring")
    guard try scanCopy(nonMetadata) == nonMetadata else { throw ScanError.malformed("control bytes outside metadata were hidden") }
    do {
        _ = try scanCopy(fixture([2, 65]))
        throw ScanError.malformed("truncated reference accepted")
    } catch ScanError.malformed(let reason) where reason == "truncated symbolic reference" {}
    var signed = fixture([])
    let signatureStart = signed.count
    func be(_ value: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * (3 - $0))) } }
    let identifier = Array("Qzx.ident".utf8) + [0], digest = Array("QzxDIGEST".utf8) + Array(repeating: 0x51, count: 11)
    var directory = be(0xfade0c02) + be(0) + be(0x20400) + be(0) + be(48 + identifier.count + 20) + be(48)
        + be(1) + be(0) + be(0) + [20, 1, 0, 12] + be(0) + be(0)
    directory += identifier + digest
    directory.replaceSubrange(4..<8, with: be(directory.count))
    let superBlob = be(0xfade0cc0) + be(20 + directory.count) + be(1) + be(0) + be(20) + directory
    signed.append(contentsOf: superBlob)
    signed[16] = 2; signed[20] = 168
    var load = Data(repeating: 0, count: 16)
    for (i, v) in [0x1d, 16, signatureStart + 16, superBlob.count].enumerated() {
        for b in 0..<4 { load[i * 4 + b] = UInt8(truncatingIfNeeded: v >> (8 * b)) }
    }
    signed.insert(contentsOf: load, at: 184)
    signed[152] = 200
    let masked = try scanCopy(signed)
    guard masked.range(of: Data("QzxDIGEST".utf8)) == nil, masked.range(of: Data("Qzx.ident".utf8)) != nil else {
        throw ScanError.malformed("signature hash slots were not masked, or its identifier was hidden")
    }
    let plain = Data("ordinary private_fixture_identity".utf8)
    guard try scanCopy(plain) == plain else { throw ScanError.malformed("plain executable changed") }
    print("Mach-O identity scan-copy tests passed")
}

do {
    guard CommandLine.arguments.count == 2 else { throw ScanError.malformed("expected executable path or --self-test") }
    if CommandLine.arguments[1] == "--self-test" { try selfTest() }
    else { FileHandle.standardOutput.write(try scanCopy(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))) }
} catch {
    FileHandle.standardError.write(Data("Mach-O identity scan failed: \(error)\n".utf8))
    exit(1)
}
