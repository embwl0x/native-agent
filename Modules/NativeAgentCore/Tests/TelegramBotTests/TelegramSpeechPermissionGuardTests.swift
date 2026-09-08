import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

/// PATCH-2026-08-18. Pins the two facts that make the headless-orphaned-grant
/// regression (root cause 130dc377) impossible to reintroduce silently.
@Suite("Speech permission denial handling")
struct TelegramSpeechPermissionGuardTests {

    /// THE INVARIANT. A prompting authorization API anywhere in the TelegramBot
    /// sources is the bug itself: this module only ever runs headless, off an
    /// inbound update, where macOS cannot render a consent prompt and resolves
    /// the request to a permanent .denied without asking the user. The only
    /// legitimate prompt site in the whole app is
    /// SystemPermissionPreflight.requestSpeechRecognitionIfNotDetermined(),
    /// which is @MainActor and app-side. A unit test cannot observe TCC, so this
    /// pins the fact at the SOURCE level instead — the same technique the
    /// transcript-correction scope test already uses.
    @Test func telegramBotSourcesNeverRequestSpeechAuthorization() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TelegramBotTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // NativeAgentCore
            .appendingPathComponent("Sources/TelegramBot", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: sourceRoot, includingPropertiesForKeys: nil)

        var offenders: [String] = []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            // Strip comments before matching: these sources' own explanatory
            // comments name the forbidden API on purpose, and matching them
            // would make the guard fire on its own documentation. Done as a real
            // scan rather than a line filter — dropping any line that STARTS
            // with "//" would hide live code trailing a block-comment close
            // (`/*` newline `// */ SFSpeechRecognizer.requestAuthorization {}`),
            // a false negative in exactly the guard that must not have one.
            if Self.strippingComments(text).contains("SFSpeechRecognizer.requestAuthorization") {
                offenders.append(file.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty,
                "headless TelegramBot sources must never call SFSpeechRecognizer.requestAuthorization; offenders: \(offenders)")
    }

    /// Removes `//` line comments and `/* */` block comments (nested-aware),
    /// leaving only executable text. String literals are not modelled; the only
    /// consequence would be a false POSITIVE (the guard firing on the API name
    /// inside a literal), which fails loud rather than silent.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var blockDepth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let rest = source[index...]
            if blockDepth == 0, rest.hasPrefix("//") {
                // Skip to end of line.
                if let newline = source[index...].firstIndex(of: "\n") {
                    out.append("\n")
                    index = source.index(after: newline)
                } else {
                    index = source.endIndex
                }
                continue
            }
            if rest.hasPrefix("/*") {
                blockDepth += 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if blockDepth > 0, rest.hasPrefix("*/") {
                blockDepth -= 1
                index = source.index(index, offsetBy: 2)
                continue
            }
            if blockDepth == 0 {
                out.append(source[index])
            }
            index = source.index(after: index)
        }
        return out
    }

    /// The headless path must still READ the grant and fail loudly.
    @Test func telegramVoiceTranscriptionReadsAuthorizationStatus() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TelegramBot/TelegramVoiceTranscription.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        #expect(text.contains("SFSpeechRecognizer.authorizationStatus()"))
    }

    /// The denial predicate's full contract. Only a genuine permission denial
    /// may raise the capability card; every other voice failure is a real
    /// failure that no System Settings switch fixes, and flagging it would turn
    /// the card into noise the user learns to ignore.
    @Test func denialPredicateFiresOnlyForPermissionDenial() {
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            TelegramVoiceTranscriptionError.speechPermissionDenied("denied")))
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            TelegramVoiceTranscriptionError.speechPermissionDenied("restricted")))

        // Neighbours that must NOT flag. speechUnavailable is the sharp one:
        // its message mentions speech, so a naive string match catches it.
        let nonDenials: [TelegramVoiceTranscriptionError] = [
            .speechUnavailable("recognizer is not currently available"),
            .speechRecognitionFailed("timed out"),
            .malformedResponse,
            .conversionFailed("ffmpeg exited 1"),
        ]
        for error in nonDenials {
            #expect(!TelegramPollLoop.isSpeechPermissionDenial(error),
                    "must not flag a capability for \(error)")
        }

        // Untyped errors fall through to the narrow string check.
        struct Untyped: LocalizedError {
            let errorDescription: String?
        }
        #expect(TelegramPollLoop.isSpeechPermissionDenial(
            Untyped(errorDescription: "voice transcription: speech recognition permission denied: denied")))
        #expect(!TelegramPollLoop.isSpeechPermissionDenial(
            Untyped(errorDescription: "network connection lost")))
    }
}
