import Foundation
import Testing
import Dispatcher
import MacControl
import PersistenceCore
@testable import ChatOrchestration

@Test func desktopPixelsAcceptStrictOptionalArguments() throws {
    #expect(try SwiftToolDispatcher.desktopPixelsRequested(["pixels": .bool(true), "app": .null, "part": .string(" \n ")]))
    #expect(try !SwiftToolDispatcher.desktopPixelsRequested(["pixels": .null]))
    #expect(try !SwiftToolDispatcher.desktopPixelsRequested([:]))
    // With app or part, pixels:true is that window's image, not the desktop.
    #expect(try !SwiftToolDispatcher.desktopPixelsRequested(["pixels": .bool(true), "app": .string("Mail")]))
    #expect(try !SwiftToolDispatcher.desktopPixelsRequested(["pixels": .bool(true), "part": .string("toolbar")]))
    #expect(throws: (any Error).self) {
        try SwiftToolDispatcher.desktopPixelsRequested(["pixels": .string("true")])
    }
}

private struct DesktopSource: MacScreenCaptureSource {
    let allowed: Bool
    func isScreenRecordingTrusted() -> Bool { allowed }
    func capture(rect: MacAXFrame?) async -> Result<MacScreenShot, MacScreenCaptureFailure> {
        #expect(allowed, "Denied capture must never reach the source")
        #expect(rect == nil, "Desktop capture must not pretend to isolate a window")
        return .success(MacScreenShot(bounds: MacAXFrame(x: 0, y: 0, w: 3200, h: 2000),
            pixelWidth: 3200, pixelHeight: 2000))
    }
}

private struct DesktopRenderer: MacScreenImageRenderer {
    func renderPNG(shot: MacScreenShot, placements: [MacScreenMarkerPlacement], downscale: Double) -> Data? {
        #expect(placements.isEmpty)
        #expect(downscale == 0.5)
        return Data([1, 2, 3])
    }
}

@Test func desktopPixelsDenyWithoutScreenRecording() async {
    let sink = LocalToolImage.Sink()
    let reply = await LocalToolImage.$sink.withValue(sink) {
        await SwiftToolDispatcher.desktopPixels(source: DesktopSource(allowed: false), renderer: DesktopRenderer())
    }
    guard case .object(let fields) = reply else { Issue.record("Missing refusal"); return }
    #expect(fields["image_pixels"] == .bool(false))
    #expect(sink.finish(success: true).isEmpty)
}

@Test func desktopPixelsDeliverBoundedTransientObservation() async {
    let sink = LocalToolImage.Sink()
    let reply = await LocalToolImage.$sink.withValue(sink) {
        await SwiftToolDispatcher.desktopPixels(source: DesktopSource(allowed: true), renderer: DesktopRenderer())
    }
    guard case .object(let fields) = reply else { Issue.record("Missing result"); return }
    #expect(fields["image_pixels"] == .bool(true))
    #expect(fields["width"] == .int(1600))
    #expect(fields["height"] == .int(1000))
    #expect(fields["verification_scope"] == .string("visual_observation_only"))
    #expect(fields["path"] == nil)
    #expect(sink.finish(success: true).count == 1)
    #expect(LocalToolImage.pixelCapableTools.contains("screen"))
}

@Test func desktopPixelsWithoutImageContinuationCannotClaimSeeing() async {
    let reply = await SwiftToolDispatcher.desktopPixels(source: DesktopSource(allowed: false), renderer: DesktopRenderer())
    guard case .object(let fields) = reply else { Issue.record("Missing refusal"); return }
    #expect(fields["image_pixels"] == .bool(false))
}
