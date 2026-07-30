import Foundation
import SwiftUI
import Testing
@testable import NativeAgentShared

@Suite("BridgeMessage")
struct BridgeMessageTests {
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
