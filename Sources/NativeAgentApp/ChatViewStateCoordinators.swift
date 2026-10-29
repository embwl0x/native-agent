import AppKit
import AppToolRuntime
import EngineRuntime
import ChatTurnRuntime
import NativeAgentShared
import Foundation
import Observation
import SwiftUI

/// Measuring the twitch (10-29): every move of the transcript that is not the reader's own hand.
let scrollMoveLog = ModuleLog(category: "TranscriptScroll", trail: true)

// Blueprint: | `ChatViewStateCoordinators.swift` | Chat viewport/follow state, measured turn-card/composer clearance and clear confirmation; occurrence-preserving toast queue |

@Observable
@MainActor
final class ChatToastQueue {
    var current: String?

    private var queue: [String] = []
    private let displayDuration: TimeInterval
    init(displayDuration: TimeInterval = 2.0) {
        self.displayDuration = max(0, displayDuration)
    }

    /// Preserve every producer occurrence in a bounded FIFO.
    func show(_ message: String) {
        if queue.count >= 10 { queue.removeFirst() }
        queue.append(message)
        if current == nil { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        current = queue.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            self.current = nil
            self.advance()
        }
    }
}

/// What the scroll view reports about the reader's viewport. An offset that
/// moves with nothing else changing is the reader or a jump they asked for;
/// one that moves with the content or the insets is layout.
struct TranscriptViewportReading: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    /// The inset under the header: content above it is behind the chrome.
    var top: CGFloat = 0
    /// The height between the two insets: what can actually be read.
    var visible: CGFloat = 0

    var atBottom: Bool {
        offset + top + visible >= contentHeight - NativeAgentShellLayout.composerClearanceMargin
    }
}

/// Shared transcript viewport owner. Only reader input moves the reading place; layout
/// changes restore its block and gap, while the live edge follows the bottom anchor.
@Observable
@MainActor
final class ChatScrollFollow {
    var autoFollow: Bool
    /// The live edge is in view. Read by the re-arm and the Latest pill.
    private(set) var atBottom = true
    /// The transcript is pinned to an earlier page (a page anchor is set), so
    /// its bottom is not the live bottom. Read by the re-arm and the Latest
    /// pill's own gate, never by ChatView.body.
    var transcriptPagedBack = false

    /// A transcript that opens on its newest follows it; one read from the top
    /// (a crew's findings) starts in place.
    init(following: Bool = true) {
        autoFollow = following
    }

    func forceFollow() {
        if !autoFollow { scrollMoveLog("scroll.follow on (re-arm)") }
        autoFollow = true
    }

    func disarmFollow() {
        if autoFollow { pickPlace(); scrollMoveLog("scroll.follow off") }
        autoFollow = false
    }

    // MARK: The reader's place

    nonisolated static let readingSpace = "transcript.reading"
    private struct Block {
        var minY: CGFloat
        /// The mount that reported it. A card that moves to its reply mounts
        /// again before the old mount goes, so only its own mount removes it.
        var mount: UUID
    }
    @ObservationIgnored private var blocks: [String: Block] = [:]
    @ObservationIgnored private var place: (id: String, gap: CGFloat)?
    @ObservationIgnored private var viewport = TranscriptViewportReading()
    /// Viewport y of the reader's last press inside the transcript; nil reads
    /// from the middle of what is visible.
    @ObservationIgnored private var pressedAt: CGFloat?
    /// The offset the last correction asked for, so its own arrival is not
    /// taken for the reader scrolling.
    @ObservationIgnored private var correcting: CGFloat?
    /// The reader (or a jump they asked for) is moving the scroll view.
    @ObservationIgnored var scrolling = false
    /// Set by `TranscriptScrollView`, which owns the scroll position.
    @ObservationIgnored var moveTo: ((CGFloat) -> Void)?
    @ObservationIgnored var moveToLiveEdge: (() -> Void)?

    /// The reader asked for the newest (a send): follow it, from the live edge.
    func followFromLiveEdge() {
        scrollMoveLog("scroll.live_edge (send) follow=%@", autoFollow ? "on" : "off")
        autoFollow = true
        moveToLiveEdge?()
    }

    func blockMoved(_ id: String, mount: UUID, to minY: CGFloat) {
        blocks[id] = Block(minY: minY, mount: mount)
        guard !autoFollow else { return }
        guard let place else { return pickPlace() }
        guard place.id == id else { return }
        let offset = minY - place.gap
        guard abs(offset - (correcting ?? viewport.offset)) > 0.5 else { return }
        correcting = offset
        scrollMoveLog("scroll.keep_place block=%@ from=%.1f to=%.1f delta=%.1f", id, viewport.offset, offset, offset - viewport.offset)
        // A scroll position's y is measured from under the top inset (the
        // header); the offset the geometry reports includes it.
        moveTo?(offset + viewport.top)
    }

    /// The place survives its block leaving: a card that moves under its reply
    /// can unmount before its new mount reports, and that mount is put back
    /// with the same gap. The reader's next scroll or press picks again.
    func blockGone(_ id: String, mount: UUID) {
        guard blocks[id]?.mount == mount else { return }
        blocks[id] = nil
    }

    func viewportChanged(from old: TranscriptViewportReading, to new: TranscriptViewportReading) {
        viewport = new
        if atBottom != new.atBottom { atBottom = new.atBottom }
        // The first offset after a correction is its arrival (clamped, if
        // the content could not reach it); either way the request is spent.
        if let correcting {
            self.correcting = nil
            if abs(correcting - new.offset) < 0.5 { return }
        }
        guard new.offset != old.offset else { return }
        // An offset that moves with the content or the insets is layout (a
        // clamp, an inset change) unless the reader is scrolling through it.
        let layout = new.contentHeight != old.contentHeight || new.visible != old.visible || new.top != old.top
        guard !layout || scrolling else { return }
        pressedAt = nil
        pickPlace()
    }

    /// A press records the reading place without leaving the live edge; opening a disclosure does.
    func pressed(atY y: CGFloat) {
        guard y >= viewport.top, y <= viewport.top + viewport.visible else { return }
        pressedAt = y
        if !autoFollow { pickPlace() }
    }

    /// The reader opened a disclosure (working notes, a tool's detail): the
    /// row they pressed holds its place and the detail grows downward, where
    /// the bottom anchor would have pushed the heading above the viewport.
    func opening() {
        if autoFollow { disarmFollow() }
    }

    /// The block that holds the reading line, else the first one below it.
    private func pickPlace() {
        let line = viewport.offset + (pressedAt ?? viewport.top + viewport.visible / 2)
        var holding: (String, CGFloat)?
        var below: (String, CGFloat)?
        for (id, block) in blocks {
            if block.minY <= line {
                if holding.map({ block.minY > $0.1 }) ?? true { holding = (id, block.minY) }
            } else if below.map({ block.minY < $0.1 }) ?? true {
                below = (id, block.minY)
            }
        }
        place = (holding ?? below).map { ($0.0, $0.1 - viewport.offset) }
    }

    /// Whether the reader's place is inside this row.
    func isReading(_ rowID: String) -> Bool {
        !autoFollow && place.map { $0.id == rowID || $0.id.hasPrefix(rowID + "#") } == true
    }

}

extension EnvironmentValues {
    /// The transcript viewport a block reports to; nil outside a transcript.
    @Entry var readingPlace: ChatScrollFollow?
}

/// The one transcript scroll view. The main chat, the detached panel and
/// Simple's threads scroll through it, so the reader's place is kept the same
/// way in all of them (ChatScrollFollow).
struct TranscriptScrollView<Content: View>: View {
    let coordinator: ChatScrollFollow
    /// False while this transcript is mounted behind another page: the wheel
    /// and press monitors are window-wide.
    var isActive: Bool = true
    /// Scrolling back down to the live edge re-arms follow; the main chat also
    /// asks for its latest page here when it is paged back.
    var onRearm: () -> Void = {}
    @ViewBuilder let content: Content
    @State private var position = ScrollPosition()

    var body: some View {
        ScrollView {
            content
                .environment(\.readingPlace, coordinator)
                .coordinateSpace(.named(ChatScrollFollow.readingSpace))
        }
        .scrollPosition($position)
        // The live edge follows the bottom; `blockMoved` preserves a reader elsewhere.
        .defaultScrollAnchor(coordinator.autoFollow ? .bottom : .top, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in coordinator.scrolling = phase.isScrolling }
        .onScrollGeometryChange(for: TranscriptViewportReading.self) { geometry in
            TranscriptViewportReading(
                offset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                top: geometry.contentInsets.top,
                // The container already excludes the header and composer
                // insets (10-29: a 1203pt window read 1029 = 1203 - 62 - 112);
                // subtracting them again left a long transcript never at its
                // bottom, so scrolling back down never re-armed following.
                visible: geometry.containerSize.height
            )
        } action: { old, new in
            coordinator.viewportChanged(from: old, to: new)
            // Following IS the live edge: a size change (rows arriving after a relaunch, a card, a
            // resize) that leaves a following transcript off its edge puts it back, until the reader
            // scrolls (10-29: a one-shot move on open fired mid-load and left the chat at the top).
            if coordinator.autoFollow, !coordinator.scrolling, !coordinator.atBottom,
               new.contentHeight != old.contentHeight || new.visible != old.visible {
                scrollMoveLog("scroll.repin live_edge content=%.0f visible=%.0f offset=%.1f", new.contentHeight, new.visible, new.offset)
                position.scrollTo(edge: .bottom)
            }
            // Any offset change while following that is not at the live edge is a visible jump.
            if coordinator.autoFollow, !coordinator.scrolling, abs(new.offset - old.offset) > 2,
               new.contentHeight == old.contentHeight {
                scrollMoveLog("scroll.jump following offset %.1f -> %.1f content=%.0f visible=%.0f", old.offset, new.offset, new.contentHeight, new.visible)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4).onChanged { _ in coordinator.disarmFollow() }
        )
        .background(
            ScrollWheelCatcher(isActive: isActive, onPress: coordinator.pressed(atY:)) { deltaY in
                switch ChatViewportPresentation.scrollFollowAction(
                    deltaY: deltaY, atBottom: coordinator.atBottom, autoFollow: coordinator.autoFollow
                ) {
                case .disarm:
                    coordinator.disarmFollow()
                case .rearm:
                    // Returning to the bottom re-arms follow without snapping.
                    onRearm()
                    coordinator.forceFollow()
                case .none:
                    break
                }
            }
            .allowsHitTesting(false)
        )
        .onAppear {
            coordinator.moveTo = { position.scrollTo(y: $0) }
            coordinator.moveToLiveEdge = { position.scrollTo(edge: .bottom) }
        }
    }
}

/// Measured card and composer heights; only the Latest pill observes them, never ChatView.body.
@MainActor
@Observable
final class ChatTurnCardClearance {
    /// What the card actually drew, where it drew it.
    var measuredHeight: CGFloat = 0
    /// Whether a card is on screen at all; idle keeps the floor.
    var showsCard = false
    /// Composer inset height, needed by the frame-aligned Latest overlay.
    var measuredComposerHeight: CGFloat = 0
    /// Room the transcript lends the floating card, as content at its end.
    var room: CGFloat = 0
    var clearance: CGFloat {
        ChatViewportPresentation.transcriptBottomClearance(
            showingTurnCard: showsCard,
            measuredCardHeight: measuredHeight,
            measuredComposerHeight: measuredComposerHeight
        )
    }

    /// Idle overlay clearance keeps the floor until the composer is measured.
    func idleClearance(floor: CGFloat) -> CGFloat {
        max(floor, ChatViewportPresentation.composerClearance(
            measuredComposerHeight: measuredComposerHeight))
    }
}

/// The scroll target, and the room lent to the working card that floats
/// over the live edge. The room is content, so a card appearing, growing or
/// leaving is the transcript growing at its end, never the viewport resizing.
struct ChatTranscriptBottomAnchor: View {
    let anchorID: String
    let store: ChatTurnCardClearance
    var margin: CGFloat = NativeAgentShellLayout.composerClearanceMargin

    var body: some View {
        Color.clear
            .frame(height: margin + store.room)
            .id(anchorID)
    }
}

/// The Latest pill's bottom inset. The clearance read is confined to a
/// modifier body.
struct ChatTurnCardClearancePadding: ViewModifier {
    let store: ChatTurnCardClearance
    let idle: CGFloat

    func body(content: Content) -> some View {
        content.padding(
            .bottom,
            (store.showsCard ? store.clearance : store.idleClearance(floor: idle))
        )
    }
}

/// Value-only presentation rules used by the chat viewport. The view is their
/// sole consumer; no state is duplicated here.
enum ChatViewportPresentation {
    static func turnCardClearance(showingTurnCard: Bool, measuredHeight: CGFloat) -> CGFloat {
        guard showingTurnCard else { return MacChatTurnCardMetrics.floatingClearance }
        return max(MacChatTurnCardMetrics.floatingClearance, measuredHeight)
    }

    /// The frame-aligned Latest overlay must clear the sum of both stacked bottom insets.
    static func transcriptBottomClearance(
        showingTurnCard: Bool,
        measuredCardHeight: CGFloat,
        measuredComposerHeight: CGFloat
    ) -> CGFloat {
        let card = turnCardClearance(
            showingTurnCard: showingTurnCard,
            measuredHeight: measuredCardHeight
        )
        return card + composerClearance(measuredComposerHeight: measuredComposerHeight)
    }

    /// Capped composer height (including padding) plus margin, or zero until measured.
    static func composerClearance(measuredComposerHeight: CGFloat) -> CGFloat {
        guard measuredComposerHeight > 0 else { return 0 }
        let sane = min(measuredComposerHeight, NativeAgentShellLayout.composerClearanceMax)
        return sane + NativeAgentShellLayout.composerClearanceMargin
    }

    /// Only for a reader who left, and only when the live edge is out of
    /// view: one who scrolled up a hair has nothing below the fold, and the
    /// bottom of an earlier page is not the live edge.
    static func shouldShowLatestPill(autoFollow: Bool, atBottom: Bool, pagedBack: Bool) -> Bool {
        !autoFollow && (!atBottom || pagedBack)
    }

    enum ScrollFollowAction: Equatable {
        case none
        case disarm
        case rearm
    }

    static func scrollFollowAction(
        deltaY: CGFloat,
        atBottom: Bool,
        autoFollow: Bool
    ) -> ScrollFollowAction {
        if deltaY > 0.5 { return .disarm }
        if deltaY < -0.5, atBottom, !autoFollow { return .rearm }
        return .none
    }
}

/// Only a presented clear confirmation may consume its captured session, once.
struct ChatClearConfirmationState: Equatable {
    private(set) var sessionId: String?
    var isPresented: Bool { sessionId != nil }

    mutating func request(sessionId: String) {
        guard !isPresented else { return }
        self.sessionId = sessionId
    }

    mutating func cancel() {
        sessionId = nil
    }

    /// Returns the captured session exactly once per confirmation.
    mutating func consumeConfirmation() -> String? {
        defer { cancel() }
        return sessionId
    }
}

/// Observes turn lifecycle and approvals here so their updates do not invalidate ChatView.body.
struct ChatTurnCardInset: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Simple view has no Work pane, so its card keeps the thumbnail.
    @Environment(\.layoutProfile) private var layoutProfile
    let store: ChatTurnCardClearance

    /// Inside the composer's glass container, already in the reply column; the
    /// tray's gap keeps it within the merge distance, so the glass fuses.
    private var card: some View {
        // Shared with detached chat; this window's Stop belongs to the composer.
        MacChatTurnCardHost(
            sessionId: appModel.activeChatSessionId,
            onOpenScreen: layoutProfile == SimpleViewMode.simple ? nil : { WorkPaneState.shared.userShow(.screen) }
        )
        .padding(.horizontal, NativeAgentShellLayout.roomGutter)
        .padding(.bottom, ChatComposerTray.gap)
    }

    var body: some View {
        TurnCardRoom(shows: showThinkingRow, floor: MacChatTurnCardMetrics.floatingClearance,
                     store: store) { card }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            store.measuredHeight = height
        }
        .onChange(of: showThinkingRow, initial: true) { _, shows in
            store.showsCard = shows
        }
        .animation(
            NativeAgentMotion.respecting(NativeAgentMotion.standard, reduceMotion: reduceMotion),
            value: showThinkingRow)
    }
}

/// Her working card floats over the transcript's live edge and borrows its
/// room from the transcript's end (`ChatTranscriptBottomAnchor`), so the
/// viewport never changes size during a turn. The room opens when the card
/// shows, only grows while it is up, and closes once, after it has faded.
/// Main and detached windows share it.
struct TurnCardRoom<Card: View>: View {
    let shows: Bool
    let floor: CGFloat
    let store: ChatTurnCardClearance
    @ViewBuilder let card: () -> Card
    @State private var held: CGFloat = 0
    /// `shows`, read live: a disappearing card's closure holds the value from
    /// the last render it was in, which was still showing.
    @State private var showing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if shows {
                card()
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > held else { return }
                        held = height
                        lend(max(floor, height))
                    }
                    .transition(NativeAgentMotion.fade)
                    // Its fade has finished: now the room closes.
                    .onDisappear {
                        guard !showing else { return }
                        held = 0
                        lend(0)
                    }
            }
        }
        .onChange(of: shows, initial: true) { _, now in
            showing = now
            if now { lend(max(floor, held)) }
        }
    }

    /// One eased move per change, so the transcript glides with the card.
    private func lend(_ height: CGFloat) {
        guard height != store.room else { return }
        scrollMoveLog("card.room %.0f -> %.0f", store.room, height)
        withAnimation(NativeAgentMotion.standard) { store.room = height }
    }
}

extension View {
    /// One block of a transcript the reader's place can rest on.
    func readingBlock(_ id: String) -> some View {
        modifier(ReadingBlock(id: id))
    }
}

private struct ReadingBlock: ViewModifier {
    let id: String
    @Environment(\.readingPlace) private var place
    @State private var mount = UUID()

    func body(content: Content) -> some View {
        if let place {
            content
                .onGeometryChange(for: CGFloat.self) {
                    $0.frame(in: .named(ChatScrollFollow.readingSpace)).minY
                } action: { minY in
                    place.blockMoved(id, mount: mount, to: minY)
                }
                .onDisappear { place.blockGone(id, mount: mount) }
        } else {
            content
        }
    }
}
