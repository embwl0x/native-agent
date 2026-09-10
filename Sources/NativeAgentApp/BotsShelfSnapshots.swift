#if DEBUG
import AppKit
import SwiftUI
import StandingBots

/// Offscreen SwiftUI rendering only: never creates a window or starts AppModel.
@MainActor
enum BotsShelfSnapshots {
    static func render(to directory: URL) throws {
        if ProcessInfo.processInfo.environment["BOTS_PRODUCTION"] == "1" {
            try renderProduction(to: directory)
            return
        }
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
                        BotsShelfView(records: records, selectedID: selected ? records[0].id : nil, activeIDs: [records[1].id])
                    }.environment(AppModel(dataRootOverride: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), startBackgroundTasks: false)), name: "\(selected ? "detail" : "list")-\(width)-\(suffix)",
                       size: CGSize(width: width, height: 800), scheme: scheme, directory: directory)
                }
            }
        }
    }

    /// Production view trees over real stores in an isolated temporary root.
    /// Only the content is synthetic; no alternate page or form is rendered.
    static func renderProduction(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bots-production-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BotDefinitionStore(dataRoot: root)
        let shelf = ShelfStore(dataRoot: root)
        let anchor = Date(timeIntervalSince1970: 1788962400)
        let names = ["Release watch", "Draft companion", "Folder notes", "Reading notes", "Archive check", "Garden journal", "Research thread", "Weekly reflection"]
        struct SavedJob: Encodable { let revision: Date; let next: Date }
        var jobs: [String: SavedJob] = [:]
        let briefs = ["Check the project releases and tell me what changed.", "Help me work through the draft when I ask.", "Read the chosen folder and keep notes in the requested form.", "Keep track of the reading I choose.", "Check the archive for changes.", "Gather the observations from the garden journal.", "Continue the research question in our conversation.", "Review the notes from the week."]
        for i in names.indices {
            var bot = BotDefinition(name: names[i], brief: briefs[i], cadence: i == 1 ? .manual : .interval(seconds: i == 0 ? 43200 : 86400),
                budget: BotBudget(tokens: 8000, seconds: 120), paused: i == 1, createdAt: anchor.addingTimeInterval(Double(i)))
            bot.provider = i == 1 ? "anthropic" : "openai"; bot.model = i == 1 ? "Sonnet" : "GPT-5.5"
            bot.reasoningEffort = i == 1 ? "medium" : "low"; bot.fast = false; bot.dailyTokenCeiling = 24000
            try store.create(bot)
            if !bot.paused { jobs[bot.id.uuidString] = SavedJob(revision: bot.updatedAt, next: anchor.addingTimeInterval(i == 0 ? 43200 : 86400)) }
            for j in 0..<(i == 0 ? 40 : 1) {
                let date = anchor.addingTimeInterval(-Double(j) * 43200)
                var entry = ShelfEntry(botId: bot.id, briefVersion: 1, runAt: date, coverageStart: date, coverageEnd: date,
                    headline: "", findings: "", changedSinceLastGood: "", runHealth: .ok, spend: ShelfSpend(tokens: 500, seconds: 12))
                entry.reply = i == 2 ? "The folder needs approval before the files can be read. The earlier notes are still available in this session." : j == 0 ? "The project published a small update this morning.\n\n- **Export fix:** saved drafts now export with their original formatting.\n- **Renaming:** saved drafts can be renamed.\n\nThe [release notes](https://example.org/releases) do not mention other changes." : "There has been no new release since the previous check. The export fix remains the latest change."
                entry.status = i == 2 ? .waitingForApproval : j == 2 ? .interrupted : .completed
                entry.statusDetail = j == 2 ? "Output limit reached" : nil
                entry.sessionID = bot.sessionID
                if i == 0 && j == 0 { entry.artifacts = [BotArtifact(name: "Release notes.md", path: "https://example.org/notes.md")] }
                try shelf.append(entry)
            }
        }
        try JSONEncoder().encode(jobs).write(to: root.appendingPathComponent("bots/runner-jobs.json"), options: .atomic)
        let app = AppModel(dataRootOverride: root, startBackgroundTasks: false)
        let records = try BotsShelfView.readRecords(root: root)
        for scheme in [ColorScheme.light, .dark] {
            for compact in [false, true] {
                for page in ["list-three", "list-eight", "detail", "waiting", "create"] {
                    let visible = page == "list-eight" ? records : Array(records.prefix(3))
                    let selected = page == "detail" ? records[0].id : page == "waiting" ? records[2].id : nil
                    try write(ShellFrame(classic: false) {
                        ShellSidebarRail(selection: .constant(.bots), botsPreviewOverride: true)
                    } detail: {
                        ZStack {
                            BotsShelfView(records: visible, selectedID: selected)
                                .opacity(page == "create" ? 0.2 : 1)
                            if page == "create" {
                                BotsEditorSheet(definition: nil, save: { _ in })
                                    .background(scheme == .dark ? Color(white: 0.14) : Color(white: 0.99), in: RoundedRectangle(cornerRadius: 12))
                                    .compositingGroup().shadow(radius: 16)
                            }
                        }
                    }.environment(app), name: "\(page)-\(compact ? "1024x700" : "1280x800")-\(scheme == .dark ? "dark" : "light")",
                       size: CGSize(width: compact ? 1024 : 1280, height: compact ? 700 : 800), scheme: scheme, directory: directory, scale: 1)
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
