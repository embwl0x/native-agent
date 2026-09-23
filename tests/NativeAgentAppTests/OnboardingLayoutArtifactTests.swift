import AppKit
import SwiftUI
import Testing
@testable import NativeAgentApp

/// Opt-in visual fixture. No AppModel/environment runtime is constructed and
/// no buttons are pressed. The provider page is deliberately excluded: its
/// child task requires a real AppModel even in the wizard's snapshot mode.
@Suite(.serialized) @MainActor struct OnboardingLayoutArtifactTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NATIVEAGENT_ONBOARDING_LAYOUT_ARTIFACTS"] == "1"))
    func captureInertIdentityAndConfirmationLayouts() async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("nativeagent-onboarding-layout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for narrow in [false, true] {
            let size = CGSize(width: narrow ? 600 : 680, height: narrow ? 500 : 640)
            for variant in ["names", "abilities", "confirm"] {
                let state = OnboardingWizardState()
                state.userName = "Sample Person"
                state.agentName = "Sample Agent"
                state.showsAbilityOverview = variant == "abilities"
                state.step = variant == "confirm" ? .confirm : .identity
                let host = NSHostingView(rootView: OnboardingWizard(snapshotState: state)
                    .environment(\.dynamicTypeSize, narrow ? .accessibility5 : .large)
                    .environment(\.colorScheme, .dark)
                    .frame(width: size.width, height: size.height)
                    .transaction { $0.disablesAnimations = true; $0.animation = nil })
                // An attached but never ordered window settles native scroll
                // geometry without screen control, activation or host settings.
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: .borderless, backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                host.wantsLayer = true
                host.frame = CGRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let first = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: first)
                try await Task.sleep(for: .milliseconds(50))
                host.layoutSubtreeIfNeeded()
                let stem = "\(variant)-\(Int(size.width))-\(narrow ? "accessibility5" : "large")"
                let scroll = scrollView(host)
                let maximum = scroll.map { max(0, ($0.documentView?.bounds.height ?? 0) - $0.contentView.bounds.height) } ?? 0
                let offsets: [CGFloat] = maximum > 0 ? [0, maximum] : [0]
                for (page, offset) in offsets.enumerated() {
                    if let scroll, let document = scroll.documentView {
                        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.isFlipped ? offset : maximum - offset))
                        scroll.reflectScrolledClipView(scroll.contentView)
                    }
                    host.layoutSubtreeIfNeeded()
                    // Native scroll positioning updates SwiftUI's layer tree
                    // on a later transaction, not inside layoutSubtreeIfNeeded.
                    try await Task.sleep(for: .milliseconds(50))
                    host.displayIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("\(stem)-\(page).png"))
                    // cacheDisplay redraws NSViews into a bitmap and can omit
                    // compositor masks. Keep an independent layer-composited
                    // capture alongside it; never crop/mask the artifact by hand.
                    let layer = try #require(host.layer)
                    let context = try #require(CGContext(data: nil,
                        width: Int(size.width), height: Int(size.height),
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    // NSHostingView's layer uses flipped AppKit coordinates;
                    // orient the bitmap like the ordinary view capture.
                    context.translateBy(x: 0, y: size.height)
                    context.scaleBy(x: 1, y: -1)
                    layer.render(in: context)
                    let composite = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
                    try #require(composite.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent("\(stem)-\(page)-layers.png"))
                }
                let viewport = scroll.map { host.convert($0.contentView.bounds, from: $0.contentView) }
                let geometry = "host=\(host.bounds), fitting=\(host.fittingSize), scrollMaximum=\(maximum), offsets=\(offsets), viewport=\(String(describing: viewport)), nativeClipMasksToBounds=\(String(describing: scroll?.contentView.layer?.masksToBounds))\n"
                try geometry.write(to: output.appendingPathComponent("\(stem).txt"), atomically: true, encoding: .utf8)
            }
        }
        print("ONBOARDING_LAYOUT_ARTIFACTS=\(output.path)")
    }

    private func scrollView(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView($0) }.first
    }
}
