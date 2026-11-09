import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AlivePage.swift` | Native list page, headers, list environment and scroll-edge fades |

// MARK: - Page

private struct AliveInListKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aliveInList: Bool {
        get { self[AliveInListKey.self] }
        set { self[AliveInListKey.self] = newValue }
    }
}

/// Tab roots share a fixed header height; pushed pages and sheets retain Back/Done navigation.
enum AlivePageStyle { case root, pushed }

/// Reserve the subtitle's height so status changes cannot move content; only Chat substitutes Mac status.
struct AlivePageHeader<Trailing: View>: View {
    let title: String
    var line: String?
    var dot: AliveStatusDot.State?
    var style: AlivePageStyle
    var showsStatus: Bool
    let trailing: Trailing
    @ScaledMetric(relativeTo: .largeTitle) private var rootSize: CGFloat = 34
    @ScaledMetric(relativeTo: .title) private var pushedSize: CGFloat = 28

    init(title: String, line: String? = nil, dot: AliveStatusDot.State? = nil, style: AlivePageStyle = .root,
         showsStatus: Bool = false, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.line = line
        self.dot = dot
        self.style = style
        self.showsStatus = showsStatus
        self.trailing = trailing()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                if let dot { AliveStatusDot(state: dot) }
                Text(title)
                    .font(.system(size: style == .root ? rootSize : pushedSize, weight: .regular, design: .serif))
                    .foregroundStyle(AlivePalette.text)
                    .lineLimit(style == .root ? 1 : 3)
                    .minimumScaleFactor(style == .root ? 0.7 : 1)
                    .fixedSize(horizontal: false, vertical: style == .pushed)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                trailing
            }
            .frame(minHeight: AliveMetrics.titleRow)
            Group {
                if showsStatus {
                    AliveConnectionLine(line: line)
                } else {
                    AliveHeaderLine(line: line)
                }
            }
            .padding(.leading, dot == nil ? 0 : 22)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension AlivePageHeader where Trailing == EmptyView {
    init(title: String, line: String? = nil, dot: AliveStatusDot.State? = nil, style: AlivePageStyle = .root,
         showsStatus: Bool = false) {
        self.init(title: title, line: line, dot: dot, style: style, showsStatus: showsStatus) { EmptyView() }
    }
}

private struct AliveHeaderLine: View {
    let line: String?

    var body: some View {
        let shown = line.flatMap { $0.isEmpty ? nil : $0 }
        Text(shown ?? " ")
            .font(.subheadline)
            .foregroundStyle(AlivePalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: AliveMetrics.lineRow, alignment: .leading)
            .opacity(shown == nil ? 0 : 1)
            .accessibilityHidden(shown == nil)
    }
}

/// Mac status replaces the header line without moving the page; its target stays 44pt.
private struct AliveConnectionLine: View {
    let line: String?
    @EnvironmentObject private var bridgeClient: MacBridgeClient

    var body: some View {
        if bridgeClient.connection.holds {
            AliveHeaderLine(line: line)
        } else {
            MacStatusChip(speaksAsAgent: true)
                .frame(minHeight: 44, alignment: .leading)
                .padding(.vertical, (AliveMetrics.lineRow - 44) / 2)
        }
    }
}

/// The 44pt title control uses glass because it floats above content.
struct AliveTitleControlLabel: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(AlivePalette.text)
            .frame(width: 44, height: 44)
            .aliveGlass(in: Circle(), interactive: true)
            .contentShape(Circle())
    }
}

/// Only Chat and connection surfaces describe Mac status.
struct AlivePage<Trailing: View, Content: View>: View {
    let title: String
    var line: String?
    var style: AlivePageStyle
    var freshnessGroup: String?
    let trailing: Trailing
    let content: Content

    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.line = line
        self.style = style
        self.freshnessGroup = freshnessGroup
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    AlivePageHeader(title: title, line: line, style: style) { trailing }
                        .padding(.horizontal, 4)
                    if let freshnessGroup { AliveFreshnessNote(group: freshnessGroup) }
                }
                .aliveListRow(top: style == .root ? AliveMetrics.rootTop : 4, bottom: 4)
            }
            content
                .listRowBackground(AlivePalette.fill)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.aliveInList, true)
        .environment(\.faceInList, true)
        .environment(\.faceStyle, .phone)
        .alivePageChrome(title: title, root: style == .root)
    }
}

extension FaceStyle {
    static let phone = FaceStyle(
        insets: EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16), minimumHeight: 44,
        title: .body.weight(.medium), detail: .subheadline, value: .subheadline.monospacedDigit(),
        elevation: AlivePalette.fill, actionSurface: AlivePalette.fill,
        card: { AnyView($0.background(AlivePalette.fill, in: RoundedRectangle(cornerRadius: 12))) })
}

extension AlivePage where Trailing == EmptyView {
    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, line: line, style: style, freshnessGroup: freshnessGroup,
                  trailing: { EmptyView() }, content: content)
    }
}

extension View {
    /// Keep titles accessible without duplicating the visible header; fades protect content under floating navigation.
    func alivePageChrome(title: String, root: Bool) -> some View {
        mobileReadingScreen()
            .navigationTitle(title)
            .aliveHiddenTitle()
            .toolbar(root ? .hidden : .automatic, for: .navigationBar)
            .aliveTopFade(holdsBar: !root)
            .aliveBottomFade()
    }

    /// Fade content below floating controls; reserve bottom space so the last row remains reachable.
    func aliveBottomFade() -> some View {
        modifier(AliveBottomFade(room: AliveRoom()))
    }

    func aliveBottomFade<Room: View>(room: Room) -> some View {
        modifier(AliveBottomFade(room: room))
    }

    /// Cover both room colour and haze beneath the pushed Back button so content cannot show through it.
    @ViewBuilder func aliveTopFade(_ on: Bool = true, holdsBar: Bool = false) -> some View {
        if holdsBar {
            overlay {
                GeometryReader { g in
                    let bar = g.safeAreaInsets.top
                    AliveRoom().mask {
                        VStack(spacing: 0) {
                            LinearGradient(stops: [.init(color: .black, location: 0),
                                                   .init(color: .black, location: max(0, bar - 8) / (bar + 16)),
                                                   .init(color: .clear, location: 1)],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: bar + 16)
                            Spacer(minLength: 0)
                        }
                        .ignoresSafeArea(edges: .top)
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else if on {
            overlay(alignment: .top) {
                GeometryReader { g in
                    let y = g.frame(in: .global).minY
                    LinearGradient(colors: [AlivePalette.room, AlivePalette.room.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: y > 0 ? y : g.safeAreaInsets.top)
                        .offset(y: -y)
                }
                .frame(height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        } else {
            self
        }
    }

    func aliveListRow(top: CGFloat = 0, bottom: CGFloat = 0) -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: top, leading: AliveMetrics.pageInset, bottom: bottom,
                                      trailing: AliveMetrics.pageInset))
    }
}

private struct AliveBottomFade<Room: View>: ViewModifier {
    let room: Room

    func body(content: Content) -> some View {
        content.scrollEdgeEffectStyle(.soft, for: .bottom)
        .overlay {
            GeometryReader { g in
                let fade = g.safeAreaInsets.bottom + 24
                room.mask {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(stops: [.init(color: .clear, location: 0),
                                               .init(color: .black.opacity(0.85), location: 0.5),
                                               .init(color: .black, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: fade)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
