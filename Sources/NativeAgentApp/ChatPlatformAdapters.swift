import SwiftUI
import AppKit
import CoreGraphics
import ScreenCaptureKit
import ScreenVision
import Speech
import AVFoundation
import UniformTypeIdentifiers
import NativeAgentShared
import MemoryV2
import PersistenceCore
import ProviderRouting
#if canImport(CoreSpotlight)
import CoreSpotlight
#endif
#if canImport(CloudKit)
import CloudKit
#endif

struct DropZoneView: NSViewRepresentable {
    var onDrop: ([NSItemProvider]) -> Void
    var onToast: ((String) -> Void)? = nil

    func makeNSView(context: Context) -> DropNSView {
        let v = DropNSView()
        v.onDrop = onDrop
        v.onToast = onToast
        return v
    }

    func updateNSView(_ nsView: DropNSView, context: Context) {
        nsView.onDrop = onDrop
        nsView.onToast = onToast
    }
}

final class DropNSView: NSView {
    var onDrop: (([NSItemProvider]) -> Void)?
    var onToast: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        var providers: [NSItemProvider] = []
        // File URLs
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for url in urls {
                let provider = NSItemProvider()
                provider.registerFileRepresentation(forTypeIdentifier: UTType.fileURL.identifier, fileOptions: [], visibility: .all) { completion in
                    completion(url, false, nil)
                    return nil
                }
                providers.append(provider)
            }
        }
        // Images via TIFF — B.1: check raw TIFF size before converting
        if let tiff = pb.data(forType: .tiff) {
            if tiff.count > 10 * 1024 * 1024 {
                DispatchQueue.main.async { self.onToast?("Image too large (limit: 10 MB)") }
            } else if let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) {
                let provider = NSItemProvider()
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(png, nil)
                    return nil
                }
                providers.append(provider)
            }
        }
        if !providers.isEmpty { onDrop?(providers) }
        return !providers.isEmpty
    }
}

struct ScrollWheelCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }
}

final class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeMonitor()
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if event.window === self.window,
               self.bounds.contains(point),
               (abs(event.scrollingDeltaY) > 0.5 || abs(event.scrollingDeltaX) > 0.5) {
                self.onScroll?(event.scrollingDeltaY)
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// PATCH-2026-05-06: multimodal-ui — paste image from clipboard helper.
// Updated 2026-05-09: also accept native PNG / JPEG types from the clipboard, not
// just TIFF. Many apps (Safari, screenshot tool with newer macOS) put PNG on
// the clipboard directly, and the old TIFF-only path returned nil silently.
func pasteImageFromClipboard() -> MultimodalAttachment? {
    let pb = NSPasteboard.general
    let limit = 10 * 1024 * 1024
    // 1. PNG (most common on modern macOS)
    if let png = pb.data(forType: .png), png.count <= limit {
        return MultimodalAttachment(type: "image", base64: png.base64EncodedString(), mime: "image/png", byteSize: png.count)
    }
    // 2. TIFF — convert to PNG for transport
    if let tiff = pb.data(forType: .tiff), tiff.count <= limit,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]),
       png.count <= limit {
        return MultimodalAttachment(type: "image", base64: png.base64EncodedString(), mime: "image/png", byteSize: png.count)
    }
    // 3. Any other image-coerced data via NSImage
    if let imageData = pb.data(forType: NSPasteboard.PasteboardType("public.image")),
       imageData.count <= limit,
       let img = NSImage(data: imageData),
       let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]),
       png.count <= limit {
        return MultimodalAttachment(type: "image", base64: png.base64EncodedString(), mime: "image/png", byteSize: png.count)
    }
    return nil
}

/// Returns true iff the clipboard appears to contain an image NativeAgent can paste.
func clipboardHasImage() -> Bool {
    let pb = NSPasteboard.general
    return pb.data(forType: .png) != nil
        || pb.data(forType: .tiff) != nil
        || pb.data(forType: NSPasteboard.PasteboardType("public.image")) != nil
}

func modelOptions(from catalog: ModelCatalogResponse?, current: String, limit: Int = 80) -> [ModelCatalogItem] {
    let fallbackModels = (
        FirstPartyModelCatalog.publicOpenAIModels
        + FirstPartyModelCatalog.anthropicModels
        + FirstPartyModelCatalog.xAIModels
    ).enumerated().map { index, model in
        ModelCatalogItem(
            id: model.id,
            displayName: model.name,
            description: nil,
            defaultReasoningEffort: model.defaultReasoningEffort,
            supportedReasoningEfforts: model.supportedReasoningEfforts,
            supportsFast: model.supportsFast,
            priority: index
        )
    }
    let sourceModels = catalog?.models ?? CodexSelectableModelCatalog.modelCatalogItems() + fallbackModels
    var seen: Set<String> = []
    var models: [ModelCatalogItem] = []

    if let currentModel = sourceModels.first(where: { $0.id == current }), seen.insert(currentModel.id).inserted {
        models.append(currentModel)
    } else if !current.isEmpty, seen.insert(current).inserted {
        models.append(ModelCatalogItem(id: current, displayName: current, description: "Custom model", defaultReasoningEffort: "high", supportedReasoningEfforts: ["low", "medium", "high", "xhigh"], supportsFast: nil, priority: 999))
    }

    for model in sourceModels {
        guard seen.insert(model.id).inserted else { continue }
        models.append(model)
        if models.count >= limit { break }
    }
    return models
}

func reasoningOptions(from catalog: ModelCatalogResponse?, model: String) -> [ReasoningEffortOption] {
    let fallback = catalog?.reasoningEfforts ?? [
        ReasoningEffortOption(id: "none", label: "None", description: nil),
        ReasoningEffortOption(id: "low", label: "Low", description: nil),
        ReasoningEffortOption(id: "medium", label: "Medium", description: nil),
        ReasoningEffortOption(id: "high", label: "High", description: nil),
        ReasoningEffortOption(id: "xhigh", label: "XHigh", description: nil),
        ReasoningEffortOption(id: "max", label: "Max", description: nil),
        ReasoningEffortOption(id: "ultra", label: "Ultra", description: nil)
    ]
    guard let record = catalog?.models.first(where: { $0.id == model }),
          let supported = record.supportedReasoningEfforts,
          !supported.isEmpty else {
        return fallback
    }
    return fallback.filter { supported.contains($0.id) }
}

struct TelegramNumericIDParseResult: Equatable {
    let canonicalIDs: [String]
    let invalidTokens: [String]

    var isConfigured: Bool { !canonicalIDs.isEmpty }
}

struct TelegramAllowlistPresentation: Equatable {
    let acceptedCount: Int
    let invalidTokens: [String]

    var isValidAndConfigured: Bool { acceptedCount > 0 && invalidTokens.isEmpty }
    var statusLabel: String {
        isValidAndConfigured ? "Allowlist configured" : "Add valid Telegram IDs before using this bot"
    }
}

func telegramAllowlistPresentation(chats: String, users: String) -> TelegramAllowlistPresentation {
    let chat = parseTelegramNumericIDs(chats)
    let user = parseTelegramNumericIDs(users)
    return TelegramAllowlistPresentation(
        acceptedCount: Set(chat.canonicalIDs + user.canonicalIDs).count,
        invalidTokens: chat.invalidTokens + user.invalidTokens
    )
}

func telegramAuthorizationHasUnsavedChanges(
    enabled: Bool,
    requireMention: Bool,
    allowlist: TelegramAllowlistPresentation,
    savedEnabled: Bool?,
    savedRequireMention: Bool?,
    savedAcceptedCount: Int?
) -> Bool {
    guard let savedEnabled, let savedRequireMention, let savedAcceptedCount else { return true }
    return enabled != savedEnabled
        || requireMention != savedRequireMention
        || allowlist.acceptedCount != savedAcceptedCount
        || !allowlist.invalidTokens.isEmpty
}

func telegramReasoningEffortMismatch(
    from catalog: ModelCatalogResponse?,
    model: String,
    selected: String
) -> String? {
    let normalized = normalizedReasoningEffort(from: catalog, model: model, selected: selected)
    guard normalized != selected else { return nil }
    return "Saved think level '\(selected)' is unsupported for \(model). Save to use \(normalized)."
}

/// The Telegram config used to carry its own model tuple.  The routing store is
/// now the single runtime authority, so a stale legacy tuple can never win a
/// status read simply because it happened to be written more recently.
struct TelegramBrainResolution: Equatable {
    let model: String?
    let reasoningEffort: String?
    let ignoresLegacyTuple: Bool
}

func resolveTelegramBrain(
    routing: SurfacePreference?,
    legacyModel: String?,
    legacyReasoningEffort: String?
) -> TelegramBrainResolution {
    TelegramBrainResolution(
        model: routing?.model,
        reasoningEffort: routing?.reasoningEffort,
        ignoresLegacyTuple: legacyModel != nil || legacyReasoningEffort != nil
    )
}

func parseTelegramNumericIDs(_ value: String) -> TelegramNumericIDParseResult {
    let tokens = value
        .split { $0 == "," || $0 == " " || $0 == "\n" || $0 == "\t" }
        .map(String.init)
        .filter { !$0.isEmpty }
    var valid: [String] = []
    var invalid: [String] = []
    for token in tokens {
        if let id = Int64(token) {
            valid.append(String(id))
        } else {
            invalid.append(token)
        }
    }
    return TelegramNumericIDParseResult(
        canonicalIDs: Array(Set(valid)).sorted(),
        invalidTokens: invalid
    )
}

func normalizedReasoningEffort(
    from catalog: ModelCatalogResponse?,
    model: String,
    selected: String
) -> String {
    let options = reasoningOptions(from: catalog, model: model)
    if options.contains(where: { $0.id == selected }) { return selected }
    if let record = catalog?.models.first(where: { $0.id == model }),
       let preferred = record.defaultReasoningEffort,
       options.contains(where: { $0.id == preferred }) {
        return preferred
    }
    return options.first?.id ?? "high"
}

// PATCH-2026-05-07: proactive-inbox-1 InboxStripContainer — loads and renders unread inbox items
