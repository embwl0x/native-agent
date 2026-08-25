import AVFoundation
import Foundation
import Testing
@testable import TelegramBot

/// EVAL COVERAGE — `telegram.voice.audioTranscodeStage`.
///
/// These are real OGG/Opus bytes and the production process launcher. The
/// executable is a checked local fixture, so this boundary proof never consults
/// a host ffmpeg installation. AVFoundation is deliberately refused because
/// Telegram's OGG lane reaches ffmpeg only after that native path cannot export
/// the attachment.
@Suite("Telegram voice audio preparation boundary")
struct TelegramVoiceAudioPreparerEvalTests {
    private let checkedOggOpus = Data(base64Encoded:
        "T2dnUwACAAAAAAAAAADCex1uAAAAAEbUg74BE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAAMJ7HW4BAAAAfYaB6gE9T3B1c1RhZ3MMAAAATGF2ZjYyLjMuMTAwAQAAAB0AAABlbmNvZGVyPUxhdmM2Mi4xMS4xMDAgbGlib3B1c09nZ1MABJgKAAAAAAAAwnsdbgIAAADun8+OA0UxOHiCAbdsfkDmAAAKvpqnvv+2hdcKceDda6DjxsXDMsZkHm5jUjpFDIpTj0QYsIxkq+yYlnlsVFMwVU6C5BbKWUnYxwldWXijP/esmIUDV0wlJ/WKw/WMdoevflpzXcfZ1s5DLQlJr2/POrQt+pViWY6ZIm/p7sN4nDPO6MaBALRugiY/ME/JXH0f/twSt8+fO9mtz1IDi3Sc2rtM405PPuoGocdHJe5WHcufNJPvQA=="
    )!

    private func temporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-voice-preparer-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func forceAVFoundationRefusal(_: URL, _: URL) async throws {
        throw TelegramVoiceTranscriptionError.conversionFailed("AVFoundation cannot decode checked Telegram Opus")
    }

    private func checkedFFmpegFixture(in directory: URL) throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ffmpeg_checked_ogg_fixture.sh")
        let executable = directory.appendingPathComponent("checked-ffmpeg-fixture")
        try FileManager.default.copyItem(at: source, to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path
        )
        return executable
    }

    @Test func checkedOggOpusProducesANonemptyM4AThroughTheProductionFFmpegProcess() async throws {
        let directory = try temporaryDirectory("success")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try checkedFFmpegFixture(in: directory)
        let attachment = TelegramMediaAttachment(
            kind: "voice",
            fileId: "checked-ogg",
            mimeType: "audio/ogg",
            sizeBytes: checkedOggOpus.count,
            bytes: checkedOggOpus,
            captureFilename: "checked.oga"
        )

        let prepared = try await TelegramVoiceAudioPreparer.prepareSpeechURL(
            attachment,
            temporaryDirectory: directory,
            avFoundationTranscoder: Self.forceAVFoundationRefusal,
            ffmpegLocator: { ffmpeg }
        )
        let output = try Data(contentsOf: prepared.url)
        #expect(prepared.url.pathExtension == "m4a")
        #expect(output.count > 0)
        let asset = AVURLAsset(url: prepared.url)
        let duration = try await asset.load(.duration)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(duration.seconds > 0)
        #expect(!audioTracks.isEmpty)

        let audioFile = try AVAudioFile(forReading: prepared.url)
        let frameCapacity = AVAudioFrameCount(min(audioFile.length, 1_024))
        let decoded = try #require(
            AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCapacity)
        )
        try audioFile.read(into: decoded, frameCount: frameCapacity)
        #expect(decoded.frameLength > 0)
        prepared.cleanup()
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["checked-ffmpeg-fixture"])
    }

    @Test func invalidOggFailsAsConversionFailedAndCleansBothTemporaryFiles() async throws {
        let directory = try temporaryDirectory("adverse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ffmpeg = try checkedFFmpegFixture(in: directory)
        let attachment = TelegramMediaAttachment(
            kind: "voice",
            fileId: "invalid-ogg",
            mimeType: "audio/ogg",
            sizeBytes: 11,
            bytes: Data("not an ogg".utf8),
            captureFilename: "broken.oga"
        )

        do {
            _ = try await TelegramVoiceAudioPreparer.prepareSpeechURL(
                attachment,
                temporaryDirectory: directory,
                avFoundationTranscoder: Self.forceAVFoundationRefusal,
                ffmpegLocator: { ffmpeg }
            )
            Issue.record("invalid OGG unexpectedly converted")
        } catch let error as TelegramVoiceTranscriptionError {
            guard case .conversionFailed = error else {
                Issue.record("expected conversionFailed, got \(error)")
                return
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["checked-ffmpeg-fixture"])
    }

    @Test func missingFFmpegLocatorFailsAsConversionFailedAndCleansTemporaryAudio() async throws {
        let directory = try temporaryDirectory("missing-locator")
        defer { try? FileManager.default.removeItem(at: directory) }
        let attachment = TelegramMediaAttachment(
            kind: "voice",
            fileId: "no-converter",
            mimeType: "audio/ogg",
            sizeBytes: checkedOggOpus.count,
            bytes: checkedOggOpus,
            captureFilename: "checked.oga"
        )

        do {
            _ = try await TelegramVoiceAudioPreparer.prepareSpeechURL(
                attachment,
                temporaryDirectory: directory,
                avFoundationTranscoder: Self.forceAVFoundationRefusal,
                ffmpegLocator: { nil }
            )
            Issue.record("missing ffmpeg locator unexpectedly converted audio")
        } catch let error as TelegramVoiceTranscriptionError {
            guard case .conversionFailed = error else {
                Issue.record("expected conversionFailed, got \(error)")
                return
            }
        }

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
