import Foundation
import Testing
@testable import NativeAgentApp

@Suite("Mac pairing presentation")
struct MacPairingPresentationTests {
    // The retired QR payload pins now protect the actual settings entry flow.
    @Test("automatic pairing leads, secret transfer is folded, and no QR is rendered")
    func automaticPairingWithManualFallback() throws {
        let source = try AppSourceScraping.appSource("MacPairingView.swift")
        let automatic = try #require(source.range(of: "The pairing key arrives automatically through iCloud."))
        let disclosure = try #require(source.range(of: "DisclosureGroup(\"Pairing hasn't connected?\""))
        #expect(automatic.lowerBound < disclosure.lowerBound)
        #expect(source.contains("@State private var manualPairingExpanded = false"))
        #expect(source.contains("Text(bridge.syncStatus)"))
        let open = try #require(source[disclosure.upperBound...].firstIndex(of: "{"))
        let close = try #require(AppSourceScraping.balancedEnd(in: source, startingAt: open, opening: "{", closing: "}"))
        let fallback = String(source[open...close])
        #expect(fallback.contains("Button(keyRevealed ? \"Hide\" : \"Reveal\")"))
        #expect(fallback.contains("pb.setString(secretBase64, forType: .string)"))
        #expect(fallback.contains("The pairing key is a secret."))
        #expect(!source.contains("qrImage"))
        #expect(!source.contains("CIQRCodeGenerator"))
        #expect(!source.contains("pairingPayloadJSON"))
        #expect(source.contains(".confirmationDialog("))
        #expect(source.contains("PairingPublicationHealth.record("))
    }
}
