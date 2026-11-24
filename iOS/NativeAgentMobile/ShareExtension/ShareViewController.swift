import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers
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
@Observable
final class ShareComposeModel {
    var name = "NativeAgent"
    var note = ""
    var text = ""
    var attachments: [MultimodalAttachment] = []
    /// Each shared image, decoded once when it is prepared; the view never decodes on a body pass.
    var previews: [String: UIImage] = [:]
    var loading = true
    var error: String?
    var saved = false
    private let context: NSExtensionContext?
    private let id = UUID()
    fileprivate let pairingFingerprint = SharedChatInbox.identityDefaults?.string(forKey: SharedChatInbox.identityPairingKey)

    init(context: NSExtensionContext?) { self.context = context }

    func load() async {
        defer { loading = false }
        guard pairingFingerprint != nil else {
            error = "This iPhone is not paired with a Mac yet."
            return
        }
        do {
            name = try SharedChatInbox.agentName()
            let items = context?.inputItems as? [NSExtensionItem] ?? []
            let providers = items.flatMap { $0.attachments ?? [] }
            guard !providers.isEmpty, providers.count <= SharedChatInbox.maxItems else {
                throw SharedChatInbox.failure("Share between one and four items at a time.")
            }
            var parts: [String] = []
            var files: [MultimodalAttachment] = []
            var images: [String: UIImage] = [:]
            for provider in providers {
                if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                    let data = try await data(from: provider, type: UTType.pdf.identifier)
                    guard !data.isEmpty, data.count <= ChatAttachmentTypeResolver.fileByteLimit else {
                        throw SharedChatInbox.failure("PDFs must be nonempty and no larger than 10 MB.")
                    }
                    files.append(MultimodalAttachment(type: "file", base64: data.base64EncodedString(),
                        mime: "application/pdf", name: provider.suggestedName ?? "Shared.pdf", byteSize: data.count))
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let raw = try await data(from: provider, type: UTType.image.identifier)
                    guard let jpeg = await Task.detached(priority: .userInitiated, operation: {
                        MobileChatAttachmentPreparation.preparedJPEGData(from: raw)
                    }).value else {
                        throw SharedChatInbox.failure("This image could not be prepared for chat.")
                    }
                    let image = MultimodalAttachment(type: "image", base64: jpeg.base64EncodedString(),
                        mime: "image/jpeg", name: "Shared-\(files.count + 1).jpg", byteSize: jpeg.count)
                    images[image.id] = UIImage(data: jpeg)
                    files.append(image)
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
            previews = images
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
            try SharedChatInbox.save(SharedChatItem(id: id, createdAt: Date(), text: body, attachments: attachments,
                                                 pairingFingerprint: pairingFingerprint))
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    func finish() { context?.completeRequest(returningItems: nil) }
}

private struct ShareComposeView: View {
    @Bindable var model: ShareComposeModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NativeAgentMobileTheme.Spacing.lg) {
                    if model.saved {
                        Label("Saved for \(model.name)", systemImage: "checkmark.circle")
                            .font(.system(.title2, weight: .semibold))
                        Text("Open NativeAgent to send your share. It will appear in Chat.")
                    } else if model.loading {
                        ProgressView("Loading shared item…")
                    } else if model.pairingFingerprint != nil {
                        TextField("Add a note (optional)", text: $model.note, axis: .vertical)
                            .lineLimit(3...6).font(.system(.body, weight: .regular)).mobileCard()
                        if !model.text.isEmpty {
                            Text(model.text).font(.system(.body, weight: .regular)).textSelection(.enabled).mobileCard()
                        }
                        ForEach(model.attachments) { item in
                            VStack(alignment: .leading) {
                                if let image = model.previews[item.id] {
                                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                                }
                                Label(item.name ?? "Attachment", systemImage: item.type == "image" ? "photo" : "doc")
                                    .font(.system(.callout, weight: .regular))
                            }.mobileCard()
                        }
                        Text("Saved on this iPhone, then sent when you open NativeAgent.")
                            .font(.system(.caption, weight: .regular)).foregroundStyle(NativeAgentMobileTheme.Colors.secondary)
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
                if !model.saved, model.pairingFingerprint != nil {
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
