import Foundation
import CryptoKit
import Testing
@testable import MemoryV2

@Suite("Embedding model ranged assembly and digest gate")
struct EmbeddingModelDownloadTests {
    @Test func preservesCustomModelAndInstallsFreshRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Fixture.bundle/Contents/Resources")
        let source = root.appendingPathComponent("embedding")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("embedding.mlpackage"), withIntermediateDirectories: true)
        try Data(#"{"model":"embedding.mlpackage","vocab":"vocab.txt","model_id":"fixture","dimensions":4}"#.utf8)
            .write(to: source.appendingPathComponent("embedding.json"))
        try Data("custom vocabulary".utf8).write(to: source.appendingPathComponent("vocab.txt"))
        try Data("fixture model".utf8).write(to: source.appendingPathComponent("embedding.mlpackage/model"))
        let archive = root.appendingPathComponent("model.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
        try zip.run(); zip.waitUntilExit()
        #expect(zip.terminationStatus == 0)
        let bytes = try Data(contentsOf: archive)
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let descriptor = """
        {"schema_version":1,"url":"https://example.invalid/model.zip","sha256":"\(sha)","byte_length":\(bytes.count),"distribution":"separate-download","archive_root":"embedding"}
        """
        try Data(descriptor.utf8).write(to: resources.appendingPathComponent("embedding-download.json"))
        try Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.embedding.fixture</string></dict></plist>"#.utf8)
            .write(to: resources.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: resources.deletingLastPathComponent().deletingLastPathComponent()))
        let target = root.appendingPathComponent("extras/coreml")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: target)
        #expect(CoreMLEmbeddingProvider.extrasModel(inDirectory: target) != nil)
        let downloader = EmbeddingModelDownload(dataRoot: root, bundle: bundle)
        #expect(try await downloader.install() == false)
        var updates = await downloader.updates().makeAsyncIterator()
        #expect(await updates.next()?.phase == "Custom memory model in use")
        #expect(try Data(contentsOf: target.appendingPathComponent("vocab.txt")) == Data("custom vocabulary".utf8))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("extras/.coreml-download").path))
        try Data("invalid marker".utf8).write(to: target.appendingPathComponent("release.sha256"))
        #expect(EmbeddingModelDownload.preservesCustomInstallation(at: target))
        try Data(String(repeating: "a", count: 64).utf8).write(to: target.appendingPathComponent("release.sha256"))
        #expect(!EmbeddingModelDownload.preservesCustomInstallation(at: target))
        try FileManager.default.removeItem(at: target)
        #expect(!EmbeddingModelDownload.preservesCustomInstallation(at: target))
        // Seed completed resume parts: the real fresh-install path assembles and
        // installs the archive without network or a model download in the fixture.
        let work = root.appendingPathComponent("extras/.coreml-download/\(sha)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for (index, range) in EmbeddingModelDownload.ranges(size: Int64(bytes.count)).enumerated() {
            try bytes.subdata(in: Int(range.start)..<Int(range.end + 1)).write(to: work.appendingPathComponent("part-\(index)"))
        }
        #expect(try await downloader.install())
        #expect(try String(contentsOf: target.appendingPathComponent("release.sha256"), encoding: .utf8) == sha)
        #expect(try await downloader.install() == false)
    }

    @Test func parsesReleaseDescriptor() throws {
        let json = #"{"schema_version":1,"name":"NativeAgent-0.4.7.embedding.zip","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","byte_length":123456,"url":"https://example.com/releases/NativeAgent-0.4.7.embedding.zip","distribution":"separate-download","archive_root":"embedding","model":{"model":"embedding.mlpackage","vocab":"vocab.txt","model_id":"bge-large-en-v1.5","dimensions":1024}}"#
        let descriptor = try EmbeddingModelDownload.Descriptor.parse(Data(json.utf8))
        #expect(descriptor.url.absoluteString == "https://example.com/releases/NativeAgent-0.4.7.embedding.zip")
        #expect(descriptor.byteLength == 123456)
        #expect(descriptor.sha256 == String(repeating: "a", count: 64))
        #expect(descriptor.distribution == "separate-download")
        for invalid in [json.replacingOccurrences(of: "123456", with: "0"),
                        json.replacingOccurrences(of: "https://", with: "http://"),
                        json.replacingOccurrences(of: String(repeating: "a", count: 64), with: "bad")] {
            #expect(throws: EmbeddingModelDownload.Failure.invalidRelease) {
                try EmbeddingModelDownload.Descriptor.parse(Data(invalid.utf8))
            }
        }
    }

    @Test func devBundleWithoutDescriptorDoesNotDownload() async throws {
        // Exercise the same Bundle.main lookup as the app using the dev-built test bundle.
        #expect(Bundle.main.url(forResource: "embedding-download", withExtension: "json") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloader = EmbeddingModelDownload(dataRoot: root)
        let installed = try await downloader.install()
        #expect(!installed)
        var updates = await downloader.updates().makeAsyncIterator()
        let status = try #require(await updates.next())
        #expect(!status.available)
        #expect(!status.running)
        #expect(status.phase == "Not started")
        #expect(status.total == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func assemblesUnevenRangesAndResumedParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<103).map { UInt8($0) })
        let ranges = EmbeddingModelDownload.ranges(size: Int64(bytes.count), parts: 48)
        #expect(ranges.first?.start == 0)
        #expect(ranges.last?.end == 102)
        #expect(ranges.reduce(0) { $0 + $1.count } == 103)
        let parts = try ranges.enumerated().map { index, range in
            let url = root.appendingPathComponent("\(index)")
            let part = bytes.subdata(in: Int(range.start)..<Int(range.end + 1))
            try part.prefix(1).write(to: url)
            let output = try FileHandle(forWritingTo: url)
            try output.seekToEnd()
            try output.write(contentsOf: part.dropFirst())
            try output.close()
            return url
        }
        let joined = root.appendingPathComponent("joined")
        let sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try EmbeddingModelDownload.assemble(parts: parts, ranges: ranges, destination: joined, sha256: sha)
        #expect(try Data(contentsOf: joined) == bytes)
        #expect(EmbeddingModelDownload.ranges(size: 0).isEmpty)
        #expect(EmbeddingModelDownload.ranges(size: 2).count == 2)
    }

    @Test func rejectsCorruptDigestAndIncompleteParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let part = root.appendingPathComponent("part")
        let joined = root.appendingPathComponent("staged.zip")
        try Data("abc".utf8).write(to: part)
        #expect(throws: EmbeddingModelDownload.Failure.digestMismatch) {
            try EmbeddingModelDownload.assemble(parts: [part], ranges: EmbeddingModelDownload.ranges(size: 3, parts: 1), destination: joined, sha256: String(repeating: "0", count: 64))
        }
        #expect(throws: EmbeddingModelDownload.Failure.incompletePart) {
            try EmbeddingModelDownload.assemble(parts: [part], ranges: EmbeddingModelDownload.ranges(size: 4, parts: 1), destination: joined, sha256: String(repeating: "0", count: 64))
        }
    }
}
