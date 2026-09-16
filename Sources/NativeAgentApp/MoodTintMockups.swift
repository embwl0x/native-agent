#if DEBUG
import AppKit
import SwiftUI

/// THE HARNESS for "Mood in the tint", User via Agent, 2026-09-14.
///
/// It was the mockup renderer; on the build (same day) it became the proof.
/// The tint is no longer computed here — `MoodTint.swift` is, and this file
/// renders the SHIPPED pass at two scalar values so the frames User and Agent
/// approved can be reproduced from the product code. They are, byte for byte.
///
/// Nothing here is reachable from a production page: the whole file is DEBUG
/// and the only entry point is gated on `SIMPLICITY_MOCKUPS_MOOD=1`. It renders
/// TWO frames of the same Mac chat window from the real SwiftUI views:
///
///   rest.png — dark mode exactly as it ships today. The resting state.
///   warm.png — the same frame, same content, with the capped warmth applied to
///              the glass surfaces only.
///
///   SIMPLICITY_MOCKUPS_MOOD=1 SIMPLICITY_SNAPSHOT_DIR=<dir> \
///     swift test --filter debugOnlySnapshotEntryPoints
///
/// THE ONE AXIS. Dark mode ↔ a breath of warmth. There is no second axis, no
/// cool end, no palette. `warmth` is a single 0…1 scalar; 0 IS today's dark
/// mode, unchanged and undescribed, and 1 is the cap.
///
/// HOW THE TINT IS APPLIED, AND WHY IT CANNOT MOVE CONTRAST. The warm hue is
/// composited with `BlendMode.color`, which carries the source's hue and
/// saturation and keeps the BACKDROP's luminosity. Relative luminance is
/// therefore preserved by construction, so every text/ground contrast ratio in
/// the frame is unchanged — the warmth is chroma only. That is the mechanism
/// behind "capped small enough that contrast never budges": it is not a value
/// tuned until the numbers happened to hold, it is a blend that cannot move
/// them.
///
/// WHERE IT LANDS. A mask, not a wash. White where the tint is allowed — the
/// rail glass, the room ground, the composer glass, the cards — and punched out,
/// softly, over the transcript's reading column and its immediate background.
/// Nothing under the prose.
///
/// HONESTY ABOUT THE RENDER. The frame is rasterised ONCE from the real view
/// tree (`ShellFrame` / `ShellSheet` / `ShellLamp` / `ShellSidebarRail` /
/// `MessageBubble` / `InlineCardReceipt` / `MacChatComposerControlStrip`) with
/// the tint off, and the two PNGs are the shipped pass composited over that one
/// raster at warmth 0 and warmth 1. `cacheDisplay` draws the AppKit hierarchy
/// synchronously and does NOT apply CALayer compositing filters, so it drops a
/// blend mode silently — hence the two stages, with `ImageRenderer` doing the
/// composite because it honours the blend.
///
/// WHAT THIS STILL DOES NOT PROVE. The composite here is over a FLATTENED
/// frame, so this cannot prove the warmth over a real desktop bleeding through
/// behind-window glass; that needs a full-screen capture over a loud wallpaper.
/// Nor does it show the tint in motion — the damping is printed, not filmed.
@MainActor
enum MoodTintMockups {

    // The axis, the cap, the hue and the damping all live in `MoodTint.swift`
    // now. A second copy here would be a second source of truth for the one
    // number this whole round is about.

    // MARK: - Frame geometry
    //
    // Declared, not discovered: the mask has to know exactly where the prose
    // column is, so this harness fixes every block's height rather than letting
    // a scroll view decide. The reading column and the rail are the shipped
    // constants; only the block heights are the mockup's own.

    private enum Frame {
        static let width: CGFloat = 1280
        static let height: CGFloat = 800
        static let rail = NativeAgentShellLayout.railWidth        // 112
        static let column = NativeAgentShellLayout.roomColumn     // 740
        static let gutter = NativeAgentShellLayout.roomGutter     // 16

        static let headerHeight: CGFloat = 84
        static let proseHeight: CGFloat = 468
        static let cardHeight: CGFloat = 84
        static let composerHeight: CGFloat = 120
        static let bottomPad: CGFloat = 24

        /// The reading column's left edge in window coordinates.
        static var columnX: CGFloat { rail + (width - rail - column) / 2 }

    }

    // MARK: - Entry point

    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let previous = NSAppearance.current
        let previousApp = NSApplication.shared.appearance
        let dark = NSAppearance(named: .darkAqua)!
        NSAppearance.current = dark
        NSApplication.shared.appearance = dark
        defer {
            NSAppearance.current = previous
            NSApplication.shared.appearance = previousApp
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mood-tint-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false,
                           activeChatSessionIDWriter: { _ in }, chatSnapshotPublisher: {})

        // 2026-09-14, the build. `cacheDisplay` draws the AppKit hierarchy
        // synchronously and does NOT apply CALayer compositing filters, so a
        // blend mode is silently dropped by it — the mockups hit the same wall
        // and solved it the same way. ONE raster of the window with the tint
        // off, then the SHIPPED pass (`MoodTint.swift`) composited over it
        // through `ImageRenderer`, which does honour the blend. The product
        // owns the tint; the harness owns only the frame and the scalar.
        let base = try raster(chatWindow(app: app, warmth: 0))

        try write(render(base, warmth: 0), to: directory.appendingPathComponent("rest.png"))
        try write(render(base, warmth: 1), to: directory.appendingPathComponent("warm.png"))


        // The collapse, and the filter, printed rather than drawn. Neither
        // accessibility request can be forged from a parent view, so the gate
        // the modifiers actually call is exercised directly here instead.
        reportGateAndFilter()
    }

    /// The shipped window pass over the flattened frame, at one scalar. The
    /// prose guard is published by a transparent stand-in laid over the
    /// reading column, so the mask the product builds is the mask measured
    /// here — this file computes no tint of its own.
    private static func render(_ base: CGImage, warmth: Double) throws -> CGImage {
        let content = ZStack(alignment: .topLeading) {
            Image(decorative: base, scale: 1)
                .resizable()
                .frame(width: Frame.width, height: Frame.height)
            Color.clear
                .frame(width: Frame.column, height: Frame.proseHeight - 60)
                .moodTintProseGuard(columnWidth: Frame.column, leadingInset: 0)
                .padding(.leading, Frame.columnX)
                .padding(.top, Frame.headerHeight)
        }
        .moodTintWindow()
        // Outside the pass, not inside it: the environment flows DOWN, so a
        // value set on the content never reaches the modifier wrapping it.
        .environment(\.colorScheme, .dark)
        .environment(\.moodTintLevelOverride, warmth)
        .frame(width: Frame.width, height: Frame.height)

        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(CGSize(width: Frame.width, height: Frame.height))
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw MoodTintError.noImage }
        return image
    }

    /// The shipped gate and the shipped filter, at the conditions that matter.
    private static func reportGateAndFilter() {
        func gate(_ label: String, enabled: Bool = true, scheme: ColorScheme = .dark,
                  reduceTransparency: Bool = false, contrast: ColorSchemeContrast = .standard) {
            let level = MoodTintGate.level(
                enabled: enabled, scheme: scheme, reduceTransparency: reduceTransparency,
                contrast: contrast, override: 1.0, weather: 1.0)
            print("MOODTINT gate  \(label.padding(toLength: 28, withPad: " ", startingAt: 0)) level=\(level)")
        }
        gate("warm, nothing in the way")
        gate("Reduce Transparency on", reduceTransparency: true)
        gate("Increase Contrast on", contrast: .increased)
        gate("light appearance", scheme: .light)
        gate("switch off", enabled: false)

        // The step response, from rest, holding the reading at 1.
        var level = 0.0
        var hours = 0.0
        for (label, step) in [("one turn (10 min)", 1.0 / 6)] + (1...24).map { ("\($0)h", 1.0) } {
            let before = level
            level = MoodTintWeather.damped(previous: level, reading: 1, elapsedHours: step)
            hours += step
            let moved = (level - before) / max(1e-9, 1 - before)
            print(String(format: "MOODTINT filter %-18@ t=%5.2fh level=%.4f tint=%.4f movedGap=%.2f%%",
                         label as NSString, hours, level, level * MoodTintWeather.cap, moved * 100))
        }
        // And the drain: the same filter, reading 0.
        var drain = level
        for hour in 1...24 {
            drain = MoodTintWeather.damped(previous: drain, reading: 0, elapsedHours: 1)
            if hour % 4 == 0 {
                print(String(format: "MOODTINT drain  %2dh level=%.4f tint=%.4f", hour, drain, drain * MoodTintWeather.cap))
            }
        }
    }

    // MARK: - The frame, from the shipping views

    private static func chatWindow(app: AppModel, warmth: Double) -> some View {
        ShellFrame(classic: false) {
            ShellSidebarRail(selection: .constant(.chat), botsPreviewOverride: false)
        } detail: {
            chatColumn(app: app)
        }
        .environment(app)
        .environment(\.colorScheme, .dark)
        // The SHIPPED path: `ShellFrame` carries `.moodTintWindow()`, the prose
        // block below carries the shipped guard, and the card tints itself.
        // The only thing the harness supplies is the scalar.
        .environment(\.moodTintLevelOverride, warmth)
        .frame(width: Frame.width, height: Frame.height)
    }

    @ViewBuilder
    private static func chatColumn(app: AppModel) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(app.agentDisplayName)
                    .font(ShellType.title)
                    .foregroundStyle(NativeAgentShell.text)
                Circle()
                    .fill(NativeAgentShell.calm)
                    .frame(width: 7, height: 7)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Frame.gutter)
            .frame(maxWidth: Frame.column)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Frame.headerHeight, alignment: .bottom)
            .padding(.bottom, 0)

            VStack(alignment: .leading, spacing: 18) {
                MessageBubble(message: ChatMessage(
                    role: "user",
                    content: "Did anything change in the release notes overnight?"))
                MessageBubble(message: ChatMessage(content: """
                One change, and it is the one you were waiting on. The export fix landed \
                at 02:40 and is in the notes now; saved drafts keep their original \
                formatting when they leave the app.

                Nothing else moved. The renaming work is still listed as planned, and \
                there is no new build behind it yet — I will say so the moment there is.
                """))
            }
            .padding(.horizontal, Frame.gutter)
            .frame(maxWidth: Frame.column, alignment: .leading)
            .frame(maxWidth: .infinity, maxHeight: Frame.proseHeight, alignment: .topLeading)

            InlineCardReceipt(
                mark: .done,
                outcome: "Read the release notes on this Mac",
                meta: "Completed · Today, 06:12 · 4s",
                detailsLabel: "What I read"
            ) {
                Text("Release notes.md")
                    .font(ShellType.label)
                    .foregroundStyle(NativeAgentShell.tertiary)
            }
            .padding(.horizontal, Frame.gutter)
            .frame(maxWidth: Frame.column, alignment: .leading)
            .frame(height: Frame.cardHeight, alignment: .center)
            .frame(maxWidth: .infinity)

            MacChatComposerControlStrip(
                shell: true, isListening: false, screenCaptureAllowed: true,
                screenCaptureDisabled: false, pendingAttachmentCount: 0,
                isRunning: false, canSend: false, onToggleVoice: {},
                onCaptureScreen: {}, onAttach: {}, onStop: {}, onSend: {}
            ) {
                Text("Message the agent")
                    .font(ShellType.body)
                    .foregroundStyle(NativeAgentShell.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Frame.gutter)
            .frame(maxWidth: Frame.column)
            .frame(height: Frame.composerHeight, alignment: .center)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
        }
        .padding(.bottom, Frame.bottomPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Rasterising (mock-only copy; no window, no screen readback)

    private static func raster<V: View>(_ view: V) throws -> CGImage {
        let size = CGSize(width: Frame.width, height: Frame.height)
        let content = view
            .frame(width: size.width, height: size.height)
            .background {
                // ImageRenderer cannot composite behind-window AppKit glass; a
                // fixed bundled wallpaper supplies the ground the real shared
                // ShellSheet samples, inside the same offscreen hierarchy.
                if let wallpaper = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic") {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 32).clipped()
                }
            }
            .transaction { $0.animation = nil }
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        func prepareGlass(_ view: NSView) {
            if let glass = view as? NSVisualEffectView {
                glass.blendingMode = .withinWindow
                glass.state = .active
            }
            for child in view.subviews { prepareGlass(child) }
        }
        prepareGlass(host)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw MoodTintError.noImage
        }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw MoodTintError.noImage }
        return image
    }

    private static func write(_ cgImage: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw MoodTintError.noImage
        }
        try png.write(to: url)
    }

    private enum MoodTintError: Error { case noImage }
}
#endif
