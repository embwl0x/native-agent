import Foundation
import Testing
@testable import TelegramBot

// MARK: - Coverage ledger: telegram.voice.transcriptionNotice
//                         telegram.voice.audioAttachmentLane
//
// voiceTranscriptionNotice is a STRING-MATCH classifier over an error's
// description. Every branch shares the "I got your voice note" prefix and the
// only assertion in the suite matched that prefix — so all six diagnoses could
// silently collapse into the generic "transcription failed before I could read
// it" and the suite would still be green, while the user is told nothing
// actionable and quietly stops sending voice notes.
//
// The evals below feed the REAL error values thrown at the real throw sites
// (file:line in each case) rather than hand-written strings, so a message
// reword at the throw site that stops matching its own branch is caught.

@Suite struct TelegramVoiceDiagnosisTests {

    /// One representative error per branch, taken from the actual throw sites.
    private static let branchCases: [(label: String, error: Error)] = [
        // TelegramVoiceTranscription.swift:588
        ("openai key", TelegramVoiceTranscriptionError.notConfigured),
        // shouldRetryWithoutOnDevice's real macOS string (:523)
        ("siri/dictation", TelegramVoiceTranscriptionError.speechRecognitionFailed(
            "Siri and Dictation are disabled"
        )),
        // TelegramVoiceTranscription.swift:475
        ("permission", TelegramVoiceTranscriptionError.speechPermissionDenied("denied")),
        // TelegramVoiceTranscription.swift:479/:482
        ("apple speech", TelegramVoiceTranscriptionError.speechUnavailable(
            "recognizer is not currently available"
        )),
        // TelegramVoiceTranscription.swift:213 — the ffmpeg-missing lane
        ("conversion", TelegramVoiceTranscriptionError.conversionFailed(
            "Telegram OGG/Opus audio is not readable by AVFoundation on this Mac, and no ffmpeg binary was found"
        )),
        // TelegramPollLoop.swift voice cap re-check
        ("oversized", TelegramMediaDownloadError.oversized(reportedBytes: 99, capBytes: 10)),
    ]

    @Test func voiceTranscriptionNotice_gives_a_distinct_diagnosis_per_error_class() {
        var notices: [String: String] = [:]
        for (label, error) in Self.branchCases {
            notices[label] = TelegramPollLoop.voiceTranscriptionNotice(for: error)
        }
        #expect(notices.count == Self.branchCases.count)

        let generic = TelegramPollLoop.voiceTranscriptionNotice(
            for: TelegramVoiceTranscriptionError.transport("connection reset by peer")
        )

        for (label, notice) in notices {
            // Envelope, not copy: it must still read as a voice-note reply …
            #expect(notice.contains("voice note"), "\(label) lost the voice-note framing")
            // … and it must NOT be the unclassified fallback.
            #expect(notice != generic, "\(label) collapsed into the generic fallback")
        }
        // Pairwise distinct — a merged branch is exactly the silent failure.
        #expect(Set(notices.values).count == Self.branchCases.count)
    }

    @Test func voiceTranscriptionNotice_uses_the_fallback_only_when_unclassified() {
        let generic = TelegramPollLoop.voiceTranscriptionNotice(
            for: TelegramVoiceTranscriptionError.transport("connection reset by peer")
        )
        #expect(generic.contains("voice note"))
        // A second genuinely unclassified error must land on the SAME string —
        // the fallback is one bucket, not a per-error passthrough that could
        // leak an internal description into the chat.
        let other = TelegramPollLoop.voiceTranscriptionNotice(
            for: TelegramVoiceTranscriptionError.malformedResponse
        )
        #expect(other == generic)
        // And it must never echo the raw error text back at the user.
        #expect(!generic.contains("connection reset"))
    }

    /// The permission branch is the one with an actionable route for the human
    /// at the Mac; it must not be swallowed by the earlier "dictation" branch.
    @Test func voiceTranscriptionNotice_permission_branch_is_not_shadowed_by_dictation() {
        let permission = TelegramPollLoop.voiceTranscriptionNotice(
            for: TelegramVoiceTranscriptionError.speechPermissionDenied("denied")
        )
        let dictation = TelegramPollLoop.voiceTranscriptionNotice(
            for: TelegramVoiceTranscriptionError.speechRecognitionFailed("Siri and Dictation are disabled")
        )
        #expect(permission != dictation)
    }

    // MARK: audio attachment lane

    /// `extras["audio"]` is a DECLARED ingest path (forwarded voice memos, m4a
    /// files) with zero exercise in the suite — every voice fixture sends a
    /// "voice" object. If the key or mime handling regresses, voiceAttachment
    /// returns nil, the message falls through to
    /// recordBlocked(reason: "empty_or_non_text") and the sender gets NO reply
    /// at all — indistinguishable from the bot being offline.
    @Test func voiceAttachment_accepts_the_audio_key_and_preserves_file_identity() {
        let message = TelegramMessage(
            messageId: 12,
            chatId: 77,
            fromUserId: 11,
            extras: .object([
                "audio": .object([
                    "file_id": .string("AUDIO-FILE-ID-1"),
                    "mime_type": .string("audio/mpeg"),
                    "file_size": .int(4096),
                ]),
            ])
        )
        let attachment = TelegramPollLoop.voiceAttachment(from: message)
        #expect(attachment?.kind == "audio")
        #expect(attachment?.fileId == "AUDIO-FILE-ID-1")
        #expect(attachment?.mimeType == "audio/mpeg")
        #expect(attachment?.sizeBytes == 4096)
    }

    @Test func voiceAttachment_prefers_voice_over_audio_and_rejects_neither() {
        let both = TelegramMessage(
            messageId: 13,
            chatId: 77,
            extras: .object([
                "voice": .object(["file_id": .string("VOICE-1")]),
                "audio": .object(["file_id": .string("AUDIO-1")]),
            ])
        )
        #expect(TelegramPollLoop.voiceAttachment(from: both)?.kind == "voice")

        let neither = TelegramMessage(
            messageId: 14,
            chatId: 77,
            extras: .object(["video": .object(["file_id": .string("VIDEO-1")])])
        )
        #expect(TelegramPollLoop.voiceAttachment(from: neither) == nil)

        // A present-but-empty file_id must not produce a half-formed
        // attachment that later fails a download with a confusing error.
        let blank = TelegramMessage(
            messageId: 15,
            chatId: 77,
            extras: .object(["audio": .object(["file_id": .string("   ")])])
        )
        #expect(TelegramPollLoop.voiceAttachment(from: blank) == nil)
    }
}
