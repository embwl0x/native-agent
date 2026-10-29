import AuthoredCapabilities
import Foundation
import CryptoKit
import Darwin
import PersistenceCore
import NativeAgentCore
// Blueprint: | `SenseHelperMaterial.swift` | Bounded file and package material conversion for the existing sense helper |

extension SenseHelperProcess {
    nonisolated static func materialWire(_ material: SenseMaterial, dataRoot: URL, source: any SenseSourceProvider) async throws -> JSONValue {
        // Local source capture has no execution cap and never holds this actor.
        let (value, file) = try await Task.detached(priority: .utility) { try materialValue(material, dataRoot: dataRoot) }.value
        if let file {
            await (source as? any SenseFileReadReporting)?.didReadFile(path: file.path, bytes: file.bytes, version: file.version, data: file.data)
        }
        return value
    }

    private nonisolated static func materialValue(_ material: SenseMaterial, dataRoot: URL) throws -> (JSONValue, (path: String, bytes: Int, version: String, data: Data)?) {
        switch material {
        case .accessibility(let tree): return (.object(["kind": .string("accessibility"), "tree": tree]), nil)
        case .file(let path, let bytes, let captured):
            try SenseSandboxProfile.requirePublicPath(path, dataRoot: dataRoot,
                personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let data: Data
            let sourceBytes: Int
            if let captured {
                data = captured; sourceBytes = bytes
            } else {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory,
                   SenseMaterial.packageExtensions.contains(url.pathExtension.lowercased()) {
                    let package = try packageArchive(url, dataRoot: dataRoot)
                    data = package.data; sourceBytes = package.bytes
                } else {
                    guard attrs[.type] as? FileAttributeType == .typeRegular else {
                        throw SenseFailure(code: "source_unavailable", message: "Sense file material must be a regular file or document package.")
                    }
                    data = try boundedFile(url, dataRoot: dataRoot)
                    sourceBytes = data.count
                }
            }
            let version = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (.object(["kind": .string("file"), "path": .string(url.path), "bytes": .int(Int64(data.count)),
                "version": .string(version), "data": .string(data.base64EncodedString())]),
                (path: url.path, bytes: sourceBytes, version: version, data: data))
        case .pageSnapshot(let snapshot): return (.object(["kind": .string("page"), "snapshot": snapshot]), nil)
        case .text(let text): return (.object(["kind": .string("text"), "text": .string(text)]), nil)
        }
    }

    private nonisolated static func boundedFile(_ url: URL, dataRoot: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw SenseFailure(code: "source_unavailable", message: "Sense file material is unavailable.") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var attrs = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &attrs) == 0, (attrs.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              fcntl(fd, F_GETPATH, &path) == 0 else {
            throw SenseFailure(code: "source_denied", message: "Sense file material must remain a regular file.")
        }
        let openedPath = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        try SenseSandboxProfile.requirePublicPath(openedPath, dataRoot: dataRoot,
            personaRoot: PersistenceCore.defaultPersonaRoot(dataRoot: dataRoot))
        let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 * 1_024 else {
            throw SenseFailure(code: "input_limit", message: "Sense file material exceeds 16 MiB.")
        }
        var after = stat()
        guard fstat(fd, &after) == 0, attrs.st_size == after.st_size,
              attrs.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, attrs.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              attrs.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, attrs.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              data.count == Int(after.st_size) else {
            throw SenseFailure(code: "file_changed", message: "Sense file material changed during the read.")
        }
        return data
    }

    /// Stored ZIP keeps package member identities intact without granting the helper filesystem access or staging a copy of User's material in scratch.
    private nonisolated static func packageArchive(_ root: URL, dataRoot: URL) throws -> (data: Data, bytes: Int) {
        let files = try ExistingCornersSourceProvider.packageManifest(root).filter(\.isFile).map(\.url)
        func word<T: FixedWidthInteger>(_ number: T, into data: inout Data) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        var archive = Data(), directory = Data(), totalBytes = 0
        for url in files.sorted(by: { $0.path < $1.path }) {
            let name = Data(NativeAgentWorkspaceRoot.relativePath(url.path, under: root.path)!.utf8)
            guard name.count <= Int(UInt16.max), !name.isEmpty,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw SenseFailure(code: "source_denied", message: "Sense document package member changed while reading.")
            }
            let bytes = try boundedFile(url, dataRoot: dataRoot)
            totalBytes += bytes.count
            var crc: UInt32 = 0xffff_ffff
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
            }
            crc ^= 0xffff_ffff
            let offset = UInt32(archive.count), count = UInt32(bytes.count)
            word(UInt32(0x04034b50), into: &archive)
            for value in [UInt16(20), 0x0800, 0, 0, 0] { word(value, into: &archive) }
            word(crc, into: &archive); word(count, into: &archive); word(count, into: &archive)
            word(UInt16(name.count), into: &archive); word(UInt16(0), into: &archive)
            archive.append(name); archive.append(bytes)
            word(UInt32(0x02014b50), into: &directory)
            for value in [UInt16(20), 20, 0x0800, 0, 0, 0] { word(value, into: &directory) }
            word(crc, into: &directory); word(count, into: &directory); word(count, into: &directory)
            word(UInt16(name.count), into: &directory)
            for _ in 0..<4 { word(UInt16(0), into: &directory) }
            word(UInt32(0), into: &directory); word(offset, into: &directory); directory.append(name)
            guard archive.count + directory.count + 22 <= 16 * 1_024 * 1_024 else {
                throw SenseFailure(code: "input_limit", message: "Sense document package exceeds 16 MiB of ZIP material.")
            }
        }
        let offset = UInt32(archive.count)
        archive.append(directory)
        word(UInt32(0x06054b50), into: &archive)
        word(UInt16(0), into: &archive); word(UInt16(0), into: &archive)
        word(UInt16(files.count), into: &archive); word(UInt16(files.count), into: &archive)
        word(UInt32(directory.count), into: &archive); word(offset, into: &archive); word(UInt16(0), into: &archive)
        return (archive, totalBytes)
    }
}
