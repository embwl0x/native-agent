#if DEBUG
import AppKit
import SwiftUI

/// Offscreen SwiftUI rendering only: never creates a window or starts AppModel.
@MainActor
enum BotsShelfSnapshots {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previous = NSAppearance.current
        let previousAppAppearance = NSApplication.shared.appearance
        defer {
            NSAppearance.current = previous
            NSApplication.shared.appearance = previousAppAppearance
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            NSAppearance.current = appearance
            NSApplication.shared.appearance = appearance
            let scheme: ColorScheme = dark ? .dark : .light
            let suffix = dark ? "dark" : "light"
            for width in [1280, 820] {
                for selected in [false, true] {
                    let records = BotsShelfSample.records
                    try write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(.bots), botsPreviewOverride: true)
                    } detail: {
                        BotsShelfView(records: records, selectedID: selected ? records[0].id : nil)
                    }, name: "\(selected ? "detail" : "list")-\(width)-\(suffix)",
                       size: CGSize(width: width, height: 800), scheme: scheme, directory: directory)
                }
            }
        }
    }

    /// Shared by the DEBUG simplicity fixtures. Scale defaults to the shelf's
    /// existing 2x output; simplicity requests exact 1280 × 800 PNG pixels.
    static func write<V: View>(_ view: V, name: String, size: CGSize,
                              scheme: ColorScheme, directory: URL, scale: CGFloat = 2) throws {
        let previous = NSAppearance.current
        let previousAppAppearance = NSApplication.shared.appearance
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
        NSAppearance.current = appearance
        NSApplication.shared.appearance = appearance
        defer {
            NSAppearance.current = previous
            NSApplication.shared.appearance = previousAppAppearance
        }
        let content = view
            .frame(width: size.width, height: size.height)
            .background {
                // ImageRenderer cannot composite behind-window AppKit glass.
                // A fixed bundled macOS wallpaper supplies that ground under
                // the real shared ShellSheet, never a per-column substitute.
                if let wallpaper = NSImage(contentsOfFile: "/System/Library/Desktop Pictures/Sonoma.heic") {
                    Image(nsImage: wallpaper).resizable().scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(radius: 32).clipped()
                }
            }
            .environment(\.colorScheme, scheme)
            .transaction { $0.animation = nil }
        // Native glass, segmented controls and links cannot be drawn directly
        // by ImageRenderer. Rasterize the actual view tree in an offscreen
        // hosting view first; this creates no NSWindow and reads no screen.
        let host = NSHostingView(rootView: content)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // There is no desktop behind this host. Let the existing material
        // sample the bundled wallpaper within the same offscreen hierarchy.
        func prepareGlass(_ view: NSView) {
            if let glass = view as? NSVisualEffectView {
                glass.blendingMode = .withinWindow
                glass.state = .active
            }
            for child in view.subviews { prepareGlass(child) }
        }
        prepareGlass(host)
        guard let nativeBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw SnapshotError.noImage(name)
        }
        nativeBitmap.size = size
        host.cacheDisplay(in: host.bounds, to: nativeBitmap)
        guard let nativeImage = nativeBitmap.cgImage else { throw SnapshotError.noImage(name) }
        let renderer = ImageRenderer(content: Image(decorative: nativeImage, scale: 1)
            .resizable().frame(width: size.width, height: size.height))
        renderer.proposedSize = ProposedViewSize(size)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { throw SnapshotError.noImage(name) }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:]) else {
            throw SnapshotError.noImage(name)
        }
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

    private enum SnapshotError: Error { case noImage(String) }
}
#endif
