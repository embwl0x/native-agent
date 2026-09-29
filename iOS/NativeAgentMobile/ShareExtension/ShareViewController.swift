import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ImageIO
import NativeAgentShared

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareComposeModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareComposeView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@MainActor
final class ShareComposeModel: ObservableObject {
    @Published var name = "NativeAgent"
    @Published var note = ""
    @Published var text = ""
    @Published var attachments: [MultimodalAttachment] = []
    @Published var loading = true
    @Published var error: String?
    @Published var saved = false
    private let context: NSExtensionContext?
    private let id = UUID()

    init(context: NSExtensionContext?) { self.context = context }

    func load() async {
        defer { loading = false }
        do {
            name = try SharedChatInbox.agentName()
            let items = context?.inputItems as? [NSExtensionItem] ?? []
            let providers = items.flatMap { $0.attachments ?? [] }
            guard !providers.isEmpty, providers.count <= SharedChatInbox.maxItems else {
                throw SharedChatInbox.failure("Share between one and four items at a time.")
            }
            var parts: [String] = []
            var files: [MultimodalAttachment] = []
            let binaryCount = providers.filter {
                $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                    || $0.hasItemConformingToTypeIdentifier(UTType.pdf.identifier)
            }.count
            let fileBudget = MobileChatAttachmentPreparation.payloadBudgetBytes / max(1, binaryCount)
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    let data = try await data(from: provider, type: UTType.pdf.identifier)
                    guard data.count <= fileBudget else {
                        throw SharedChatInbox.failure("This PDF is too large for chat. Share a smaller PDF (up to \(fileBudget / 1024) KB).")
                    }
                    files.append(MultimodalAttachment(type: "file", base64: data.base64EncodedString(),
                        mime: "application/pdf", name: provider.suggestedName ?? "Shared.pdf", byteSize: data.count))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let raw = try await data(from: provider, type: UTType.image.identifier)
                    guard let source = CGImageSourceCreateWithData(raw as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1400
                          ] as CFDictionary),
                          let jpeg = MobileChatAttachmentPreparation.preparedJPEGData(
                            from: UIImage(cgImage: thumbnail), maxBytes: fileBudget) else {
                        throw SharedChatInbox.failure("This image could not be prepared for chat.")
                    }
                    files.append(MultimodalAttachment(type: "image", base64: jpeg.base64EncodedString(),
                        mime: "image/jpeg", name: "Shared-\(files.count + 1).jpg", byteSize: jpeg.count))
                } else {
                    let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                        ? UTType.url.identifier : UTType.text.identifier
                    parts.append(try await sharedText(from: provider, type: type))
                }
            }
            let joined = parts.joined(separator: "\n\n")
            guard joined.utf8.count <= SharedChatInbox.maxTextBytes else {
                throw SharedChatInbox.failure("This text is too long to share. Select a shorter passage.")
            }
            text = joined
            attachments = files
        } catch { self.error = error.localizedDescription }
    }

    private func data(from provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: SharedChatInbox.failure("The shared file is unavailable.")) }
            }
        }
    }

    private func sharedText(from provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error { continuation.resume(throwing: error) }
                else if let url = item as? URL { continuation.resume(returning: url.absoluteString) }
                else if let text = item as? String { continuation.resume(returning: text) }
                else if let text = item as? NSAttributedString { continuation.resume(returning: text.string) }
                else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else { continuation.resume(throwing: SharedChatInbox.failure("The shared text is unavailable.")) }
            }
        }
    }

    func save() {
        do {
            let body = [note.trimmingCharacters(in: .whitespacesAndNewlines), text]
                .filter { !$0.isEmpty }.joined(separator: "\n\n")
            try SharedChatInbox.save(SharedChatItem(id: id, createdAt: Date(), text: body, attachments: attachments))
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    func finish() { context?.completeRequest(returningItems: nil) }
}

private struct ShareComposeView: View {
    @ObservedObject var model: ShareComposeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentMobileTheme.Spacing.lg) {
                    if model.saved {
                        Label("Saved for \(model.name)", systemImage: "checkmark.circle")
                            .mobileTypography(.title, weight: .semibold)
                        Text("Open NativeAgent to send your share. It will appear in Chat.")
                    } else if model.loading {
                        ProgressView("Loading shared item…")
                    } else {
                        TextField("Add a note (optional)", text: $model.note, axis: .vertical)
                            .lineLimit(3...6).mobileTypography(.body).mobileCard()
                        if !model.text.isEmpty {
                            Text(model.text).mobileTypography(.body).textSelection(.enabled).mobileCard()
                        }
                        ForEach(model.attachments) { item in
                            VStack(alignment: .leading) {
                                if item.type == "image", let data = Data(base64Encoded: item.base64),
                                   let image = UIImage(data: data) {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                }
                                Label(item.name ?? "Attachment", systemImage: item.type == "image" ? "photo" : "doc")
                                    .mobileTypography(.label)
                            }.mobileCard()
                        }
                        Text("Saved on this iPhone, then sent when you open NativeAgent.")
                            .mobileTypography(.caption).foregroundStyle(NativeAgentMobileTheme.Colors.secondary)
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(NativeAgentMobileTheme.Colors.trouble)
                    }
                }.padding(NativeAgentMobileTheme.Spacing.xl)
            }
            .background(NativeAgentMobileTheme.Colors.canvas)
            .navigationTitle("Share to \(model.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.saved ? "Done" : "Cancel") { model.finish() }
                }
                if !model.saved {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { model.save() }
                            .buttonStyle(.glassProminent)
                            .disabled(model.loading || (model.text.isEmpty && model.attachments.isEmpty))
                    }
                }
            }
            .tint(NativeAgentMobileTheme.Colors.accent)
        }
        .task { await model.load() }
    }
}
