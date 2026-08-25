@preconcurrency import Speech
import Foundation
import Testing
@testable import TelegramBot

/// Executable boundary proof for the headless Telegram voice lane. A poll-loop
/// turn has no UI in which macOS can render a Speech permission prompt, so a
/// fresh grant must be reported to the app-side card path, never requested.
@Suite("Telegram voice transcriber permission boundary")
struct TelegramVoiceTranscriberPermissionEvalTests {
    @Test func notDeterminedGrantFailsBeforeAudioPreparation() async {
        let reads = ReadCounter()
        let transcriber = SwiftAppleSpeechTranscriber(
            speechAuthorizationStatus: {
                reads.record()
                return .notDetermined
            }
        )
        // Deliberately invalid and nonempty: reaching audio preparation would
        // produce a conversion error instead of the actionable TCC diagnosis.
        let attachment = TelegramMediaAttachment(
            kind: "voice",
            fileId: "fresh-tcc-grant",
            mimeType: "audio/ogg",
            sizeBytes: 9,
            bytes: Data("not-audio".utf8),
            captureFilename: "fresh.oga"
        )

        do {
            _ = try await transcriber.transcribe(attachment)
            Issue.record("a fresh Speech grant must not enter headless transcription")
        } catch let error as TelegramVoiceTranscriptionError {
            #expect(error == .speechPermissionDenied("not determined"))
        } catch {
            Issue.record("expected actionable speech permission denial, got \(error)")
        }
        #expect(reads.count == 1, "the headless lane performs one status read and never requests authorization")
    }

    private final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func record() {
            lock.withLock { value += 1 }
        }

        var count: Int {
            lock.withLock { value }
        }
    }
}
