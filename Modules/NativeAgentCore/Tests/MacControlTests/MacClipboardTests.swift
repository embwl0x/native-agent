import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import MacControl

// MARK: - THE CLIPBOARD ORGAN (fable51 sweep item 30)
//
// Hermetic: a scripted pasteboard pushed through the EXACT production handlers
// (`SwiftNativeMacControl.dispatch`). User's real clipboard is never read and
// never written by any test in this file.
//
// The load-bearing half is the redaction boundary. `clipboard_read` is the one
// organ whose whole input is "whatever the last ⌘C put there", and a password
// manager's ⌘C puts a live credential there. So: a secret line must go dark
// WITH A REASON, and — just as important — ordinary prose beside it must NOT,
// because over-redaction blinds the organ silently.

private final class _ClipBoard: MacPasteboardSource, @unchecked Sendable {
    private let lock = NSLock()
    private var text: String?
    private var types: [MacPasteboardType]
    private var changeCount: Int
    private var available: Bool
    private(set) var writes: [String] = []

    init(
        text: String? = nil,
        types: [MacPasteboardType]? = nil,
        changeCount: Int = 1,
        available: Bool = true
    ) {
        self.text = text
        self.types = types ?? (text == nil ? [] : [MacPasteboardType(identifier: "public.utf8-plain-text", bytes: text?.utf8.count)])
        self.changeCount = changeCount
        self.available = available
    }

    func read() -> MacPasteboardContents? {
        lock.lock(); defer { lock.unlock() }
        guard available else { return nil }
        return MacPasteboardContents(text: text, types: types, changeCount: changeCount)
    }

    func write(text newText: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available else { return false }
        writes.append(newText)
        text = newText
        types = [MacPasteboardType(identifier: "public.utf8-plain-text", bytes: newText.utf8.count)]
        changeCount += 1
        return true
    }

    func recordedWrites() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return writes
    }
}

private func _clipClient(_ board: _ClipBoard) -> SwiftNativeMacControl {
    SwiftNativeMacControl(pasteboardSource: board)
}

private func _object(_ value: JSONValue) -> [String: JSONValue] {
    if case .object(let o) = value { return o }
    return [:]
}

private func _string(_ value: JSONValue?) -> String? {
    if case .string(let s)? = value { return s }
    return nil
}

private func _bool(_ value: JSONValue?) -> Bool? {
    if case .bool(let b)? = value { return b }
    return nil
}

private func _int(_ value: JSONValue?) -> Int? {
    if case .int(let n)? = value { return Int(n) }
    return nil
}

private func _array(_ value: JSONValue?) -> [JSONValue] {
    if case .array(let a)? = value { return a }
    return []
}

// MARK: - 1. Redaction on read

@Test
func clipboardRead_redactsASecretLine_andSaysWhy() async throws {
    let board = _ClipBoard(text: """
    Deployment notes for the staging cluster, written up after Tuesday's outage.
    sk-live-9f2ab7c41de85630bb14aa02cf7e91d4
    Restart the workers before you re-run the migration.
    """)
    let result = try await _clipClient(board).dispatch(action: "clipboard_read", body: [:])
    let out = _object(result.output)

    #expect(result.ok)
    #expect(_bool(out["redacted"]) == true, "a live API key must not reach a provider: \(out)")
    let text = try #require(_string(out["text"]))
    #expect(!text.contains("sk-live-9f2ab7c41de85630bb14aa02cf7e91d4"), "the key survived the boundary: \(text)")
    #expect(text.contains("[redacted:"), "redaction must be visible, not a silent gap: \(text)")

    // THE OTHER HALF. Over-redaction blinds this organ and fails silently.
    #expect(text.contains("Deployment notes for the staging cluster"), "prose was blanked: \(text)")
    #expect(text.contains("Restart the workers"), "prose was blanked: \(text)")

    // A reader deserves to know WHICH line went dark and why, or redaction is
    // indistinguishable from the organ failing to see.
    let redactions = _array(out["redactions"])
    #expect(redactions.count == 1, "\(redactions)")
    let row = _object(redactions[0])
    #expect(_int(row["line"]) == 2)
    #expect(_string(row["reason"])?.isEmpty == false)
}

@Test
func clipboardRead_leavesOrdinaryProseAlone() async throws {
    let board = _ClipBoard(text: "Remind me to ask about the password reset flow before Thursday.")
    let result = try await _clipClient(board).dispatch(action: "clipboard_read", body: [:])
    let out = _object(result.output)

    // A SENTENCE mentioning a secret is prose. Blanking it is the failure mode
    // that makes her unable to read her own clipboard.
    #expect(_bool(out["redacted"]) == false, "\(out)")
    #expect(_string(out["text"]) == "Remind me to ask about the password reset flow before Thursday.")
}

@Test
func clipboardRead_redactsBeforeItTruncates() async throws {
    // Truncating first would cut the token in half and hand out the surviving
    // half as ordinary prose — no shape left for the redactor to match.
    let filler = String(repeating: "a document line that is plainly prose.\n", count: 30)
    let board = _ClipBoard(text: filler + "ghp_A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7")
    let result = try await _clipClient(board).dispatch(
        action: "clipboard_read",
        body: ["max_chars": .int(100_000)]
    )
    let out = _object(result.output)
    let text = try #require(_string(out["text"]))
    #expect(!text.contains("ghp_A1b2C3d4"), "\(text)")
    #expect(_bool(out["redacted"]) == true)
}

@Test
func clipboardRead_capsWhatItReturns_andSaysItCut() async throws {
    let board = _ClipBoard(text: String(repeating: "x", count: 5_000))
    let result = try await _clipClient(board).dispatch(
        action: "clipboard_read",
        body: ["max_chars": .int(500)]
    )
    let out = _object(result.output)

    #expect(_bool(out["truncated"]) == true)
    #expect(_string(out["text"])?.count == 500)
    // The FULL size is still reported: a cap must never become a claim about
    // how much was there.
    #expect(_int(out["chars"]) == 5_000)
    #expect(_int(out["returned_chars"]) == 500)
}

@Test
func clipboardRead_clampsAnAbsurdRequestInsteadOfHonoringIt() {
    #expect(MacClipboardRead.clampedMaxChars(nil) == MacClipboardRead.defaultMaxChars)
    #expect(MacClipboardRead.clampedMaxChars(5) == MacClipboardRead.minMaxChars)
    #expect(MacClipboardRead.clampedMaxChars(9_000_000) == MacClipboardRead.hardMaxChars)
}

// MARK: - 2. Non-text pasteboard

@Test
func clipboardRead_namesNonTextTypes_withoutDumpingTheBytes() async throws {
    let board = _ClipBoard(
        text: nil,
        types: [
            MacPasteboardType(identifier: "public.png", bytes: 148_221),
            MacPasteboardType(identifier: "public.file-url", bytes: 96),
        ]
    )
    let result = try await _clipClient(board).dispatch(action: "clipboard_read", body: [:])
    let out = _object(result.output)

    #expect(result.ok, "a picture on the clipboard is an ANSWER, not a failure")
    #expect(_bool(out["has_text"]) == false)
    #expect(out["text"] == JSONValue.null)
    #expect(_bool(out["has_non_text"]) == true)

    let types = _array(out["types"]).map { _object($0) }
    #expect(types.count == 2)
    #expect(_string(types[0]["type"]) == "public.png")
    #expect(_int(types[0]["bytes"]) == 148_221)
    #expect(_string(types[1]["type"]) == "public.file-url")

    // Nothing anywhere in the result may carry image bytes.
    let encoded = "\(out)"
    #expect(!encoded.contains("data:"), "\(encoded.prefix(400))")
}

@Test
func clipboardRead_reportsAMixedPasteboardHonestly() async throws {
    let board = _ClipBoard(
        text: "Q3 revenue chart",
        types: [
            MacPasteboardType(identifier: "public.utf8-plain-text", bytes: 16),
            MacPasteboardType(identifier: "public.tiff", bytes: 2_400_000),
        ]
    )
    let out = _object(try await _clipClient(board).dispatch(action: "clipboard_read", body: [:]).output)

    #expect(_bool(out["has_text"]) == true)
    #expect(_string(out["text"]) == "Q3 revenue chart")
    // Both facts are true at once, and both are said.
    #expect(_bool(out["has_non_text"]) == true)
}

@Test
func clipboardRead_saysSoWhenThereIsNoPasteboardAtAll() async throws {
    let board = _ClipBoard(available: false)
    let result = try await _clipClient(board).dispatch(action: "clipboard_read", body: [:])
    let out = _object(result.output)

    // "No pasteboard on this system" must never be dressed up as "the
    // clipboard is empty" — they are different facts and lead to different
    // next moves.
    #expect(!result.ok)
    #expect(result.error == "clipboard_unavailable")
    #expect(_bool(out["available"]) == false)
}

// MARK: - 3. Write, and the round trip

@Test
func clipboardWrite_thenRead_roundTrips() async throws {
    let board = _ClipBoard(text: "whatever was here before")
    let client = _clipClient(board)

    let wrote = try await client.dispatch(
        action: "clipboard_write",
        body: ["text": .string("ship it on Thursday")]
    )
    let wroteOut = _object(wrote.output)
    #expect(wrote.ok)
    #expect(_bool(wroteOut["written"]) == true)
    #expect(_int(wroteOut["chars"]) == 19)
    // `verified` is a READ-BACK, not the return value of the set call.
    #expect(_bool(wroteOut["verified"]) == true)
    // The text is never echoed: the caller wrote it, and an echo would leave
    // the organ through a channel with no redactor on it.
    #expect(wroteOut["text"] == nil)

    let read = _object(try await client.dispatch(action: "clipboard_read", body: [:]).output)
    #expect(_string(read["text"]) == "ship it on Thursday")
    #expect(board.recordedWrites() == ["ship it on Thursday"])
}

@Test
func clipboardWrite_refusesWithoutText_andWritesNothing() async throws {
    let board = _ClipBoard(text: "untouched")
    let result = try await _clipClient(board).dispatch(action: "clipboard_write", body: [:])

    #expect(!result.ok)
    #expect(result.error == "missing_text")
    #expect(board.recordedWrites().isEmpty, "a refusal must not have written first")
}

@Test
func clipboardWrite_refusesAnUnboundedPayload() async throws {
    let board = _ClipBoard()
    let huge = String(repeating: "y", count: MacClipboardRead.maxWriteChars + 1)
    let result = try await _clipClient(board).dispatch(
        action: "clipboard_write",
        body: ["text": .string(huge)]
    )

    #expect(!result.ok)
    #expect(result.error == "text_too_long")
    #expect(board.recordedWrites().isEmpty)
}

@Test
func clipboardWrite_reportsASystemRefusalRatherThanClaimingSuccess() async throws {
    let board = _ClipBoard(available: false)
    let result = try await _clipClient(board).dispatch(
        action: "clipboard_write",
        body: ["text": .string("hello")]
    )

    #expect(!result.ok)
    #expect(result.error == "clipboard_write_refused")
    #expect(_bool(_object(result.output)["written"]) == false)
}

// MARK: - 4. The tiers, pinned

@Test
func clipboardActions_areDispatchable_andSitInTheirOwnTiers() {
    #expect(macControlDispatchableActions.contains("clipboard_read"))
    #expect(macControlDispatchableActions.contains("clipboard_write"))
    // Same gate CATEGORY as the keystroke that fills the pasteboard.
    #expect(macControlGateCategory(forAction: "clipboard_read") == "accessibility")
    #expect(macControlGateCategory(forAction: "clipboard_write") == "accessibility")
    // Neither is INJECTION: adding one here would demand a
    // `MacInjectionCapability` for an action that posts no event.
    #expect(!macControlAccessibilityInjectionActions.contains("clipboard_read"))
    #expect(!macControlAccessibilityInjectionActions.contains("clipboard_write"))
    // Neither joins the AX read set, whose contract is specifically the walk.
    #expect(!macControlAccessibilityReadActions.contains("clipboard_read"))
}
