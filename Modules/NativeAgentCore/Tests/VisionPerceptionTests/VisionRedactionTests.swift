import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
import MacControl
@testable import VisionPerception

// MARK: - Redaction on the pixel channel
//
// The blast radius is the same as the AX channel's: turn trace, persisted tool
// row, sync. So the bar is the same, and the strongest form of the test is a
// DEEP SCAN of the serialized percept for the secret's characters — not a
// check that some field was marked, which would pass while the string rode out
// through a neighbouring one.

/// Every string anywhere in a JSON value.
private func strings(in value: JSONValue) -> [String] {
    switch value {
    case .string(let text): return [text]
    case .array(let items): return items.flatMap { strings(in: $0) }
    case .object(let object): return object.values.flatMap { strings(in: $0) }
    default: return []
    }
}

@Test func aCvvShapedStringInPixelsDoesNotRideOutClear() throws {
    let scene = Scene.mainScene()
    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: VisionKitTextRecognizer(), windowTitle: "Account Settings"
    )
    // The pixels say "451" beside pixels that say "CVV". Nothing in the frame
    // is an AX node, so the caption geometry is the ONLY thing that can make
    // this a secret — and it must.
    let emitted = strings(in: percept.toJSON())
    #expect(!emitted.contains("451"), "the CVV value rode out in the clear")
    #expect(percept.notes.contains { $0.contains("redacted") })

    // …and it was withheld for a NAMED reason, not lost. Redaction that is
    // indistinguishable from the organ failing to see is its own bug.
    let recognizer = VisionKitTextRecognizer()
    let boxes = try VisionTextLayer.recognize(image: scene.image, using: recognizer).boxes
    let redacted = VisionTextRedaction.redact(boxes: boxes, imageSize: scene.size)
    let code = try #require(redacted.first { $0.raw == "451" })
    #expect(code.secret)
    #expect(code.reason == "labeled_cvv")
    #expect(code.display == nil)
}

@Test func standaloneSecretShapesAreWithheldWithNoCaptionAtAll() throws {
    let scene = Scene.secretsScene()
    let recognizer = VisionKitTextRecognizer()
    let boxes = try VisionTextLayer.recognize(image: scene.image, using: recognizer).boxes
    let redacted = VisionTextRedaction.redact(boxes: boxes, imageSize: scene.size)
    #expect(redacted.count >= 2)
    let leaked = redacted.filter { !$0.secret }.map(\.raw)
    #expect(leaked.isEmpty, "a standalone secret shape rode out: \(leaked)")

    let percept = try VisionPerceptionCompiler().compile(
        image: scene.image, using: recognizer
    )
    let emitted = strings(in: percept.toJSON())
    #expect(!emitted.contains { $0.contains("482913") })
    #expect(!emitted.contains { $0.contains("sk-live") })
}

@Test func aWithheldStringNeverEntersAHandleFingerprint() throws {
    // A handle rides out in every envelope, and a digest keyed by a secret is
    // still keyed by the secret. So a region whose only text was withheld gets
    // an unlabeled fingerprint, not a hashed one.
    let secret = VisionRedactedText(
        raw: "482913",
        json: MacScreenViewTextRedaction.redactedText("482913", reason: "otp_shape"),
        secret: true,
        reason: "otp_shape"
    )
    #expect(secret.display == nil)
    let fingerprint = VisionHandles.fingerprint(
        roleGuess: VisionRoleGuess.textField,
        label: secret.display,
        rect: VisionRect(x: 10, y: 10, w: 100, h: 30),
        imageSize: VisionSize(width: 800, height: 600)
    )
    #expect(!fingerprint.contains("482913"))
}

@Test func captionGeometryMatchesTheAxChannelsShape() {
    let value = VisionRect(x: 300, y: 100, w: 60, h: 20)
    // Immediately left, same line.
    #expect(VisionTextRedaction.isCaption(
        VisionRect(x: 240, y: 100, w: 50, h: 20), forValueAt: value, proximity: 120
    ))
    // Directly above, horizontally overlapping.
    #expect(VisionTextRedaction.isCaption(
        VisionRect(x: 300, y: 70, w: 50, h: 20), forValueAt: value, proximity: 120
    ))
    // Too far away is not a caption — otherwise every short word on the screen
    // darkens every number.
    #expect(!VisionTextRedaction.isCaption(
        VisionRect(x: 10, y: 100, w: 50, h: 20), forValueAt: value, proximity: 120
    ))
    // To the RIGHT is not a caption.
    #expect(!VisionTextRedaction.isCaption(
        VisionRect(x: 380, y: 100, w: 50, h: 20), forValueAt: value, proximity: 120
    ))
}

@Test func ordinaryTextIsNotDarkened() throws {
    let scene = Scene.mainScene()
    let recognizer = VisionKitTextRecognizer()
    let boxes = try VisionTextLayer.recognize(image: scene.image, using: recognizer).boxes
    let redacted = VisionTextRedaction.redact(boxes: boxes, imageSize: scene.size)
    // Over-redaction is a failure too: an organ that darkens the screen sees
    // nothing useful. Only the CVV value should be withheld here.
    #expect(redacted.filter(\.secret).count == 1)
    #expect(redacted.contains { $0.display == "Save" })
    #expect(redacted.contains { $0.display == "user@example.com" })
}
