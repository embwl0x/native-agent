import Foundation
import CryptoKit
import SwiftUI
import Testing
@testable import NativeAgentShared

@Suite("BridgeMessage")
struct BridgeMessageTests {
    @Test func macToPhoneKindsHavePinnedWireSignatures() throws {
        let golden = [
            "chat": "03cef5c2effdb65b37e1b9b428c639f5df609c5f5cac8cb14487d0df9264b575",
            "final": "13b07bb0c71db4f2b509185095daccb4331ff217b8e0d6342066c038fe3ac7ac",
            "notification": "bf3e58ac504f97a5e5644cb5d767d0e2e1cc54f4bef568476073ad7a9ad34d6d",
            "icloud_action_response": "68683a8df77d3df868902b18af6f536a0d58af4a38cdb892924f6d7cafc7654b",
            "progress": "b41eb48ee418f710b88526806e9e739bdabccca2bfa6a6b369b81b51f69258ea",
            "notice": "9557f7753391daa819d3979b2c73360e9f2fcf2d94958b2c9b4ccbf396539a0c",
            "tool_use": "836b42b5d8a85caa957a2ae3c43e4b5286006321bf2d5a67afc46bc717efc987",
            "tool_result": "96b60a3e71d2d6b4879fd035b034eeec9f391a033db9cc3c97d637561c5ba2f2",
            "text_delta": "b310c47fb1a7e3ecf032a27ad1a9be9e8304300e0e02f80c7011cca43e963798",
            "error": "bc03ecafa3b535fb7a3dbae3874fd4ebebe29641379ca0331d4010c02dfd65aa",
            "cancelled": "185ae2fb8f2b80f83f3a2dd1c288bdc1ea352e047f6891ceb913b1f38165582b",
            "rejection": "5a34115295b8703c2f28c2c873e1a510d4d6c52faf2d2ac450c809db8c4761ab",
        ]
        let secret = Data("golden-pairing-secret".utf8)
        for (kind, digest) in golden {
            var metadata = ["targetSourceKey": "ios:fixture"]
            if kind != "chat" { metadata["kind"] = kind }
            let mac = BridgeMessage(id: "golden-mac-reply", sender: "mac",
                timestamp: Date(timeIntervalSince1970: 1_788_782_400), text: "fixture",
                sessionID: "session", correlationID: "request",
                metadata: metadata, attachments: nil)
            // These are the production Mac signer, CloudKit codec, and phone verifier.
            let signed = try mac.signed(with: secret)
            #expect(signed.signature == digest, "\(kind)")
            let phone = try NAChatMessageCodec.decode(NAChatMessageCodec.encode(signed))
            #expect(phone.verifySignature(secret: secret))
            #expect(try phone.canonicalBodyForSigning() == mac.canonicalBodyForSigning())
        }
    }

    @Test func unsignedResyncEnvelopeReportsTheFailingField() throws {
        let hint = BridgeMessage(id: "golden-resync", sender: "mac",
            timestamp: Date(timeIntervalSince1970: 1_788_782_400), text: "signature_invalid_resync", sessionID: nil,
            correlationID: "request", metadata: ["kind": "signature_invalid_resync",
                "rejectedMessageId": "request", "publishedAt": "",
                "pairing_secret_version": "0", "targetSourceKey": "ios:fixture"], attachments: nil)
        #expect(hint.isUnsignedResyncHint)
        #expect(SHA256.hash(data: try hint.canonicalBodyForSigning()).map { String(format: "%02x", $0) }.joined()
            == "dfae6fa9cbb7e3f2f68493d0cc4df428c54b45009d12168740cb27115ba3f170")
        #expect(try NAChatMessageCodec.decode(NAChatMessageCodec.encode(hint)).isUnsignedResyncHint)
        var signedHint = hint
        signedHint.signature = "unexpected"
        #expect(signedHint.unsignedResyncHintFailure == "signature")
    }
    @Test func notificationEventIdentityIsStableAcrossTransportProjections() {
        let fromMac = NativeAgentDeviceEventIdentity.notification(userInfo: [
            "itemId": "inbox-card-7",
            "source": "dream",
        ])
        let fromSnapshot = NativeAgentDeviceEventIdentity.notification(userInfo: [
            "itemId": "inbox-card-7",
            "screen": "inbox",
        ])

        #expect(fromMac == fromSnapshot)
        #expect(NativeAgentDeviceEventIdentity.isCanonical(fromMac))
        #expect(NativeAgentDeviceEventIdentity.notification(
            userInfo: ["eventId": fromMac, "itemId": "ignored"]
        ) == fromMac)
    }

    @Test func notificationEventIdentitySeparatesSemanticNamespaces() {
        let item = NativeAgentDeviceEventIdentity.notification(userInfo: ["itemId": "same"])
        let approval = NativeAgentDeviceEventIdentity.notification(userInfo: ["approvalId": "same"])
        #expect(item != approval)
    }

    @Test func signingRoundTripVerifiesAndRejectsWrongSecret() throws {
        let secret = Data("nativeagent-secret".utf8)
        let wrongSecret = Data("other-secret".utf8)
        let message = BridgeMessage.make(
            sender: "ios",
            text: "hello",
            sessionID: "session-1",
            correlationID: "msg-1",
            metadata: ["surface": "ios"]
        )

        let signed = try message.signed(with: secret)

        #expect(signed.signature != nil)
        #expect(signed.verifySignature(secret: secret))
        #expect(!signed.verifySignature(secret: wrongSecret))
    }

    @Test func unsignedMessageDoesNotVerify() {
        let message = BridgeMessage.make(sender: "mac", text: "reply")

        #expect(!message.verifySignature(secret: Data("nativeagent-secret".utf8)))
    }

    @Test func explicitMessageIdentityMakesTransportReplayStable() {
        let message = BridgeMessage.make(
            id: "7f93f212-2f51-5c71-9bf6-cda124b9bf79",
            sender: "mac",
            text: "reply"
        )

        #expect(message.id == "7f93f212-2f51-5c71-9bf6-cda124b9bf79")
    }

    @Test func imageAttachmentsAreSignedAndRoundTrip() throws {
        let secret = Data("nativeagent-secret".utf8)
        let attachment = MultimodalAttachment(
            type: "image",
            base64: Data("fake-image".utf8).base64EncodedString(),
            mime: "image/jpeg",
            name: "iphone-photo.jpg",
            byteSize: 10
        )
        let signed = try BridgeMessage.make(
            sender: "ios",
            text: "look at this",
            attachments: [attachment]
        ).signed(with: secret)

        let data = try JSONEncoder().encode(signed)
        let decoded = try JSONDecoder().decode(BridgeMessage.self, from: data)

        #expect(decoded.attachments?.first?.mime == "image/jpeg")
        #expect(decoded.attachments?.first?.name == "iphone-photo.jpg")
        #expect(decoded.verifySignature(secret: secret))
    }
}

@Suite("NativeAgent identity display")
struct NativeAgentIdentityTests {
    @Test func configuredNamePassesWhileGenericLabelsUseFallback() {
        #expect(NativeAgentIdentity.displayName("  River  ") == "River")
        #expect(NativeAgentIdentity.displayName(nil) == "NativeAgent")
        #expect(NativeAgentIdentity.displayName("AI") == "NativeAgent")
        #expect(NativeAgentIdentity.displayName("agent", fallback: "the agent") == "the agent")
    }

    @Test func configuredNameUsesTheSharedEightyCodePointCeiling() {
        let payload = String(repeating: "\u{1F44D}\u{1F3FD}", count: 100)
        let result = NativeAgentIdentity.displayName(payload)
        #expect(result.unicodeScalars.count == 80)
        #expect(result.count == 40)
    }
}

@Suite("ColorHex")
struct ColorHexTests {
    @Test func rejectsInvalidHexStrings() {
        #expect(Color(hex: "not-a-color") == nil)
        #expect(Color(hex: "12345") == nil)
        #expect(Color(hex: "123456789") == nil)
    }

    @Test func acceptsRgbAndArgbHexStrings() {
        #expect(Color(hex: "#336699") != nil)
        #expect(Color(hex: "FF336699") != nil)
    }
}
