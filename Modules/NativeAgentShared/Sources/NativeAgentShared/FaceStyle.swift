import SwiftUI
import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif
// Blueprint: | `FaceStyle.swift` | Door-supplied card surface, row density, insets and type |

public struct FaceStyle: Sendable {
    public let insets: EdgeInsets
    public let minimumHeight: CGFloat
    public let title: Font
    public let detail: Font
    public let value: Font
    public let elevation: Color
    public let actionSurface: Color
    /// The fill of a row's one answer when the row waits on the person: the door's one accent, deep enough to carry white words. Absent,
    /// the answer takes the tint the door's window already gives its controls.
    public let answer: Color?
    let card: @MainActor @Sendable (AnyView) -> AnyView

    public init(insets: EdgeInsets, minimumHeight: CGFloat, title: Font, detail: Font, value: Font,
                elevation: Color, actionSurface: Color, answer: Color? = nil,
                card: @escaping @MainActor @Sendable (AnyView) -> AnyView) {
        self.insets = insets
        self.minimumHeight = minimumHeight
        self.title = title
        self.detail = detail
        self.value = value
        self.elevation = elevation
        self.actionSurface = actionSurface
        self.answer = answer
        self.card = card
    }

    /// Hosts must supply their native style; this unspecialized value draws no card surface.
    public static let inherited = FaceStyle(
        insets: EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16), minimumHeight: 30,
        title: .body.weight(.medium), detail: .callout, value: .callout.monospacedDigit(),
        elevation: .primary.opacity(0.04), actionSurface: inheritedSurface, card: { $0 })

    #if os(iOS)
    private static let inheritedSurface = Color(uiColor: .systemBackground)
    #else
    private static let inheritedSurface = Color(nsColor: .windowBackgroundColor)
    #endif
}

public extension EnvironmentValues {
    @Entry var faceStyle: FaceStyle = .inherited
    @Entry var faceListColumnWidth: CGFloat? = nil
    /// Quiet capture draws the held reading or its waiting state, without starting lifecycle work.
    @Entry var faceHoldsDocuments = true
}

struct FaceCard: ViewModifier {
    @Environment(\.faceStyle) private var style
    func body(content: Content) -> some View { style.card(AnyView(content)) }
}

extension EnvironmentValues {
    @Entry var faceContainerWidth: CGFloat = 0
    @Entry var faceListWidth: FaceListWidth? = nil
}

@MainActor @Observable final class FaceConfirmations {
    enum Source: Equatable { case row(UUID), control(UUID) }

    struct Request {
        let source: Source
        let title: String
        let label: String
        let role: ButtonRole?
        let perform: @MainActor () -> Void
    }

    var pending: Request?
}

struct FaceDialogs: ViewModifier {
    #if os(macOS)
    @State private var confirmations = FaceConfirmations()
    #endif

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.environment(confirmations)
            .modifier(FaceConfirmationDialog(pending: Binding(
                get: { confirmations.pending }, set: { confirmations.pending = $0 })))
        #else
        content
        #endif
    }
}

struct FaceConfirmationDialog: ViewModifier {
    @Binding var pending: FaceConfirmations.Request?

    func body(content: Content) -> some View {
        content.confirmationDialog(pending?.title ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending) { request in
            Button(request.label, role: request.role) { request.perform() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct FaceWidth: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content.environment(\.faceContainerWidth, width)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
    }
}

@MainActor @Observable final class FaceListWidth {
    var width: CGFloat = 0
    @ObservationIgnored private var mounted: [UUID: Binding<Bool>] = [:]
    @ObservationIgnored private var reader: UUID?

    func attach(_ id: UUID, measuring: Binding<Bool>) {
        mounted[id] = measuring
        if reader == nil { reader = id }
        measuring.wrappedValue = reader == id
    }

    func detach(_ id: UUID) {
        mounted.removeValue(forKey: id)
        if reader == id {
            reader = mounted.keys.first
            if let reader { mounted[reader]?.wrappedValue = true }
        }
    }

    func measured(_ width: CGFloat, by id: UUID) {
        if reader == id { self.width = width }
    }
}

struct FaceListWidthProbe: ViewModifier {
    let list: FaceListWidth
    @State private var id = UUID()
    @State private var measuring = false

    func body(content: Content) -> some View {
        content.background {
            if measuring {
                Color.clear.allowsHitTesting(false).onGeometryChange(for: CGFloat.self) { $0.size.width } action: { list.measured($0, by: id) }
            }
        }
        .onAppear { list.attach(id, measuring: $measuring) }
        .onDisappear { list.detach(id) }
    }
}

private struct FaceListHost: ViewModifier {
    @State private var list = FaceListWidth()

    func body(content: Content) -> some View {
        content.environment(\.faceContainerWidth, list.width)
            .environment(\.faceListWidth, list)
            .modifier(FaceDialogs())
    }
}

public extension View {
    @ViewBuilder func faceList(_ enabled: Bool = true) -> some View {
        if enabled { modifier(FaceListHost()) }
        else { environment(\.faceListWidth, nil) }
    }
}
