import Foundation
import XCTest
import NativeAgentShared
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.screens`, row
/// `ios.chat.photoBudget.cloudKitPayloadBudgetBytes` (was REPORTS-ONLY).
///
/// Silent-failure class: WRONG VALUE. `ChatView.cloudKitPhotoPayloadBudgetBytes`
/// is a hand-derived 520 KiB, justified in a comment by base64 expansion against
/// `NAChatMessageCodec.maxCloudKitRecordValueBytes` (800 KiB). Nothing checked
/// the derivation. If either constant moves, the phone accepts photos it can
/// never deliver: the encode throws `payloadTooLarge` deep in the transport and
/// the user sees a send that simply never lands.
///
/// This exercises the REAL codec that the real send path uses, at the real
/// budget, rather than restating the arithmetic.
final class ChatPhotoTransportBudgetEvalTests: XCTestCase {

    /// A worst-case chat turn: `count` photos whose RAW bytes exactly fill
    /// `rawTotalBytes`, base64'd, plus the metadata a real iOS send carries.
    private func turn(rawTotalBytes: Int, count: Int = 4) -> BridgeMessage {
        let perPhoto = rawTotalBytes / count
        let attachments = (0..<count).map { index -> MultimodalAttachment in
            // Random bytes: base64 of incompressible data is the honest worst
            // case, and JSON does not compress the payload either way.
            var raw = Data(count: perPhoto)
            raw.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                arc4random_buf(base, buffer.count)
            }
            return MultimodalAttachment(
                id: "attachment-\(index)",
                type: "image",
                base64: raw.base64EncodedString(),
                mime: "image/jpeg",
                name: "IMG_000\(index).jpg",
                byteSize: raw.count
            )
        }
        return BridgeMessage.make(
            sender: "ios",
            text: String(repeating: "what is in these photos? ", count: 40),
            sessionID: "session-under-test",
            correlationID: UUID().uuidString,
            metadata: ChatRuntimeControls.defaults.metadata(transport: "cloudkit"),
            attachments: attachments
        )
    }

    func test_aFullPhotoBudgetTurnFitsInsideTheCloudKitRecordCeiling() throws {
        let message = turn(rawTotalBytes: ChatView.cloudKitPhotoPayloadBudgetBytes)
        XCTAssertNoThrow(
            try NAChatMessageCodec.encode(message),
            """
            A chat turn carrying exactly ChatView.cloudKitPhotoPayloadBudgetBytes of photo
            bytes no longer encodes under NAChatMessageCodec.maxCloudKitRecordValueBytes.
            The composer would keep accepting photos the transport cannot ship.
            """
        )
    }

    func test_theBudgetLeavesRealHeadroomAboveBase64ExpansionNotJustABareFit() throws {
        // base64 is 4/3 expansion; the codec also projects scalar query fields
        // and reserves 4 KiB of record overhead on top of the JSON body.
        let expanded = Double(ChatView.cloudKitPhotoPayloadBudgetBytes) * 4.0 / 3.0
        let ceiling = Double(NAChatMessageCodec.maxCloudKitRecordValueBytes)
        XCTAssertLessThan(
            expanded, ceiling,
            "the photo budget alone exceeds the record ceiling once base64-expanded"
        )
        XCTAssertGreaterThan(
            ceiling - expanded, 64 * 1024,
            """
            less than 64 KiB is left for text, tool metadata, signature and record overhead.
            A long prompt on top of a full photo set would push the turn over the ceiling.
            """
        )
    }

    /// Negative control — proves the assertion above has teeth. If the codec
    /// stopped enforcing the ceiling, the "fits" test would pass for any budget.
    func test_aTurnWellOverTheBudgetIsRejectedByTheCodec() throws {
        let message = turn(rawTotalBytes: ChatView.cloudKitPhotoPayloadBudgetBytes * 2)
        XCTAssertThrowsError(try NAChatMessageCodec.encode(message)) { error in
            guard case DeviceSyncError.payloadTooLarge(let actual, let maximum) = error else {
                return XCTFail("expected payloadTooLarge, got \(error)")
            }
            XCTAssertGreaterThan(actual, maximum)
            XCTAssertEqual(maximum, NAChatMessageCodec.maxCloudKitRecordValueBytes)
        }
    }

    /// The per-photo split must never hand one photo the whole aggregate budget
    /// while photos are still pending — that is how the strip silently drops the
    /// tail of a multi-photo selection.
    func test_perPhotoBudgetSplitsTheAggregateAndNeverGoesNegative() {
        let total = ChatView.cloudKitPhotoPayloadBudgetBytes
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: total, remainingCount: 4), total / 4)
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: total, remainingCount: 1), total)
        XCTAssertGreaterThanOrEqual(ChatView.perPhotoBudget(remainingBytes: -1, remainingCount: 2), 0)
        XCTAssertEqual(ChatView.perPhotoBudget(remainingBytes: total, remainingCount: 0), 0)
    }
}
