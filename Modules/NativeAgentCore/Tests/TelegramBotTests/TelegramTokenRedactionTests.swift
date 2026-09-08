import Testing
import Foundation
@testable import TelegramBot
import NativeAgentCore
import NativeAgentTestSupport
import PersistenceCore

// Audit 2026-06-09 (security-adjacent): URLSession errors embed the failing
// URL incl. /bot<TOKEN>/; recordError rows render in the Mac UI.
@Suite("Telegram token redaction")
struct TelegramTokenRedactionTests {
    @Test func redactsBotTokenInURLErrorText() {
        let raw = "Error Domain=NSURLErrorDomain Code=-1009 \"offline\" UserInfo={NSErrorFailingURLStringKey=https://api.telegram.org/bot7123456789:AAH-secret_Token123/sendMessage}"
        let redacted = TelegramPollLoop._tgRedactToken(raw)
        #expect(!redacted.contains("AAH-secret_Token123"))
        #expect(redacted.contains("[REDACTED_TELEGRAM_TOKEN]"))
        #expect(redacted.contains("sendMessage"))
    }

    @Test func leavesTokenFreeTextAlone() {
        let raw = "getUpdates status 409"
        #expect(TelegramPollLoop._tgRedactToken(raw) == raw)
    }
}
