import XCTest
@testable import NativeAgentMobile

/// Coverage-ledger fence `ios.providers.surfaceLabel`.
///
/// The Mac owns surface IDs, but iOS owns their visible text. Every currently
/// rendered canonical ID must have an intentional display name; an unknown key
/// must fail visibly rather than looking like a normal title-cased label.
final class ProviderSurfaceLabelEvalTests: XCTestCase {
    func test_everyCanonicalSurfaceHasAnExplicitMobileLabel() {
        for surface in ProviderSettingsView.canonicalSurfaces {
            let presentation = MobileProviderSurfaceLabelPresentation.presentation(for: surface)
            guard case .named(let label) = presentation else {
                return XCTFail("canonical surface \(surface) fell through to \(presentation)")
            }
            XCTAssertFalse(label.isEmpty)
        }
        XCTAssertEqual(
            MobileProviderSurfaceLabelPresentation.presentation(for: "cognition_reflection"),
            .named("Cognition Reflection")
        )
        XCTAssertEqual(
            MobileProviderSurfaceLabelPresentation.presentation(for: "missions"),
            .named("Workshop")
        )
    }

    func test_unknownOrMalformedSurfaceDoesNotRenderAsARawCapitalizedKey() {
        XCTAssertEqual(
            MobileProviderSurfaceLabelPresentation.presentation(for: "cognition_reflection_v2").text,
            "Unrecognized surface (cognition_reflection_v2)"
        )
        XCTAssertEqual(
            MobileProviderSurfaceLabelPresentation.presentation(for: " Cognition_reflection ").text,
            "Surface label unavailable"
        )
    }

    func test_providerScreenUsesTheExplicitSurfaceLabelPresentation() throws {
        let source = try MobileEvalSources.mobileSource("ProviderSettingsView.swift")
        XCTAssertTrue(source.contains("MobileProviderSurfaceLabelPresentation.presentation(for: surface).text"))
        XCTAssertFalse(source.contains("default:          return surface.capitalized"))
    }
}
