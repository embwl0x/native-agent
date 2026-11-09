import SwiftUI
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
    let card: @MainActor @Sendable (AnyView) -> AnyView

    public init(insets: EdgeInsets, minimumHeight: CGFloat, title: Font, detail: Font, value: Font,
                elevation: Color, actionSurface: Color, card: @escaping @MainActor @Sendable (AnyView) -> AnyView) {
        self.insets = insets
        self.minimumHeight = minimumHeight
        self.title = title
        self.detail = detail
        self.value = value
        self.elevation = elevation
        self.actionSurface = actionSurface
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
    /// A list owns cards and dividers; an embedded face draws its own groups.
    @Entry var faceInList = false
    /// Quiet capture draws the held reading or its waiting state, without starting lifecycle work.
    @Entry var faceHoldsDocuments = true
}

struct FaceCard: ViewModifier {
    @Environment(\.faceStyle) private var style
    func body(content: Content) -> some View { style.card(AnyView(content)) }
}
