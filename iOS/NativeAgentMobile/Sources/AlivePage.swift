import SwiftUI
import UIKit
import NativeAgentShared
// Blueprint: | `AlivePage.swift` | Native list page, headers, list environment and scroll-edge fades |

// MARK: - Page

/// True inside an AlivePage: the kit's sections, cards and rows are then
/// iOS's own List sections and cells.
private struct AliveInListKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var aliveInList: Bool {
        get { self[AliveInListKey.self] }
        set { self[AliveInListKey.self] = newValue }
    }
}

/// A tab root hides the bar and wears the big serif door at one fixed height;
/// a pushed page or a sheet keeps its bar (Back, Done) and a smaller door.
enum AlivePageStyle { case root, pushed }

/// A page's door: a serif word with an optional trailing control on its row
/// (never a separate toolbar row), and ONE line under it. With `showsStatus`
/// (the chat header only), that line becomes the Mac connection status
/// whenever the Mac is not live; every other page's line describes the page.
/// The line is always held, so nothing below jumps when it arrives or swaps.
/// With `dot`, the agent's light sits before the name.
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

/// The trailing control in a title row (the chat's `…`, the Desk's `+`): a
/// 44pt glass circle, because it floats on the functional layer.
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

/// A room, header, optional freshness/accessory and native sections.
/// Only the chat header and connection surfaces describe Mac status.
struct AlivePage<Trailing: View, Content: View>: View {
    let title: String
    var line: String?
    var style: AlivePageStyle
    var freshnessGroup: String?
    var accessory: AnyView?
    let trailing: Trailing
    let content: Content

    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, accessory: AnyView? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.line = line
        self.style = style
        self.freshnessGroup = freshnessGroup
        self.accessory = accessory
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        // iOS's own grouped List: native cells, separators, press highlight
        // and chevrons; her room and haze stay behind it.
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    AlivePageHeader(title: title, line: line, style: style) { trailing }
                        .padding(.horizontal, 4)
                    if let freshnessGroup { AliveFreshnessNote(group: freshnessGroup) }
                    if let accessory { accessory }
                }
                .aliveListRow(top: style == .root ? AliveMetrics.rootTop : 4, bottom: 4)
            }
            content
                .listRowBackground(AlivePalette.fill)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.aliveInList, true)
        .alivePageChrome(title: title, root: style == .root)
    }
}

extension AlivePage where Trailing == EmptyView {
    init(title: String, line: String? = nil, style: AlivePageStyle = .pushed,
         freshnessGroup: String? = nil, accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, line: line, style: style, freshnessGroup: freshnessGroup,
                  accessory: accessory, trailing: { EmptyView() }, content: content)
    }
}

extension View {
    /// The page chrome around any scroll or list: the room, the bar (hidden at
    /// a tab root, kept with Back when pushed), the undrawn title that
    /// VoiceOver still reads, the fade under the status bar (and, pushed,
    /// under the floating Back button), and the fade under the floating tab bar.
    func alivePageChrome(title: String, root: Bool) -> some View {
        mobileReadingScreen()
            .navigationTitle(title)
            .aliveHiddenTitle()
            .toolbar(root ? .hidden : .automatic, for: .navigationBar)
            .aliveTopFade(holdsBar: !root)
            .aliveBottomFade()
    }

    /// The room fades over the system scroll edge under floating controls.
    /// The bottom safe area keeps the last row clear.
    func aliveBottomFade() -> some View {
        modifier(AliveBottomFade(room: AliveRoom()))
    }

    /// The same fade over a room with its own mood (the chat's).
    func aliveBottomFade<Room: View>(room: Room) -> some View {
        modifier(AliveBottomFade(room: room))
    }

    /// Scrolled content fades out under the status bar. `holdsBar` (a pushed
    /// page): the room itself (colour AND haze, like the bottom fade) covers
    /// the status bar and the bar with the floating Back button, fading out
    /// just below it, so nothing reads through the button.
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
                    // From the screen's top edge down to the end of the status bar.
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

    /// A list row that is only its content: no cell, no separator, the page's
    /// side inset.
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
                // From 24pt above whatever floats at the bottom to the edge.
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
