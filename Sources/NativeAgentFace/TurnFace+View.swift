import AppKit
import Foundation
import ImageIO
import NativeAgentShared
import SwiftUI
// Blueprint: | `TurnFace+View.swift` | Session-keyed turn slot reads and rendering of encoded preview images |

extension AppModel {
    func turnFace(for sessionID: String) -> TurnFace? {
        face.slot(.turn(session: sessionID)).value(as: TurnFace.self)
    }

    /// One part of a conversation's turn face: its reader redraws only when that part changes.
    func turnPart<Part: Equatable>(_ name: String, for sessionID: String, _ part: @escaping (TurnFace?) -> Part) -> Part {
        face.slot(.turn(session: sessionID)).select(name, as: TurnFace.self, part)
    }

    var turnSessionsFace: TurnSessionsFace? {
        face.slot(.turns).value(as: TurnSessionsFace.self)
    }
}

/// AppKit owns image rendering; the face never decodes the engine's stores or reconstructs lifecycle state.
struct TurnPreviewImage: View {
    let data: Data
    let caption: String
    @Environment(\.quietCaptureSession) private var capture
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var decodedData: Data?

    var body: some View {
        Group {
            if let capture, capture.screenData == data, let image = capture.screenImage {
                Image(nsImage: image).resizable().accessibilityLabel(caption)
            } else if decodedData == data, let image {
                Image(nsImage: image).resizable().accessibilityLabel(caption)
            } else if decodedData == data, let failure {
                Text(failure).font(NativeAgentFont.tag).foregroundStyle(.secondary)
            } else {
                Color.clear.accessibilityLabel("Reading the screen preview…")
            }
        }
        .task(id: data) {
            guard capture == nil else { return }
            image = nil
            failure = nil
            let decoded = await Self.decode(data)
            guard !Task.isCancelled else { return }
            decodedData = data
            if let decoded { image = decoded }
            else { failure = "The screen preview image is unreadable." }
        }
    }

    @concurrent nonisolated private static func decode(_ data: Data) async -> sending NSImage? {
        let options = [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
