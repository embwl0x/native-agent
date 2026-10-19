import AppKit
import Foundation
import Observation
import SwiftUI

/// Scroll offsets are deliberately excluded: following the bottom must not
/// trigger another layout-follow request merely because the viewport moved.
struct ChatScrollLayoutExtent: Equatable {
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
}

@Observable
@MainActor
final class ChatToastQueue {
    var current: String?

    private var queue: [String] = []
    private var recentKeys: [(key: String, at: Date)] = []
    private let displayDuration: TimeInterval
    @ObservationIgnored private let visibleEntryDidChange: @MainActor @Sendable (String?) -> Void

    init(
        displayDuration: TimeInterval = 2.0,
        visibleEntryDidChange: @escaping @MainActor @Sendable (String?) -> Void = { _ in }
    ) {
        self.displayDuration = max(0, displayDuration)
        self.visibleEntryDidChange = visibleEntryDidChange
    }

    /// `deduplicating: false` is for the chat composer sink: every call there
    /// is an independently actionable outcome, even when its human text has
    /// the same timestamp/UUID-normalized shape as a prior failure.
    func show(_ message: String, deduplicating: Bool = true) {
        let normalized = normalizedKey(message)
        if deduplicating {
            let normalizedCurrent = normalizedKey(current ?? "")
            if normalized == normalizedCurrent { return }

            let now = Date()
            recentKeys.removeAll { now.timeIntervalSince($0.at) > 10 }
            if recentKeys.contains(where: { $0.key == normalized }) { return }

            recentKeys.append((key: normalized, at: now))
            if recentKeys.count > 5 { recentKeys.removeFirst() }
        }

        if queue.count >= 10 { queue.removeFirst() }
        queue.append(message)
        if current == nil { advance() }
    }

    private func advance() {
        guard !queue.isEmpty else { return }
        setVisibleEntry(queue.removeFirst())
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration) {
            self.setVisibleEntry(nil)
            self.advance()
        }
    }

    private func setVisibleEntry(_ entry: String?) {
        current = entry
        visibleEntryDidChange(entry)
    }

    private func normalizedKey(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(
            of: "\u{1B}\\][^\u{07}]*\u{07}",
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: "\u{1B}\\[[0-?]*[ -/]*[@-~]",
            with: "",
            options: .regularExpression
        )
        output = output.replacing(/\b\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z?\b/, with: "<ts>")
        output = output.replacing(/\b\d{2}:\d{2}:\d{2}\b/, with: "<time>")
        output = output.replacing(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/, with: "<id>")
        return output
    }
}

/// The composer is the visible sink for ChatView.showToast.  It deliberately
/// retains every producer occurrence: pin persistence, voice, and slash
/// command outcomes may share normalized text while still requiring separate
/// acknowledgement by the user.
@MainActor
enum ChatComposerBottomToastPresentation {
    static func show(_ message: String, in queue: ChatToastQueue) {
        queue.show(message, deduplicating: false)
    }

    static func visibleEntry(from queue: ChatToastQueue) -> String? {
        queue.current
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

/// One transcript's viewport owner: the main chat, the detached panel and
/// Simple's threads each hold one, and `TranscriptScrollView` is the scroll
/// view all of them read through.
///
/// The reader's place. Following is one place: the live edge, which the
/// scroll view's bottom anchor holds by itself. Anywhere else the place is the
/// block under the reader's reading line (a row, a card, a reply's notes or
/// answer) and how far its top sits from the top of the viewport, and every
/// layout change puts that block back where it was: a reply settling, a card
/// moving under its reply, an image decoding, a window resize, the window of
/// rows sliding. A kept scroll offset could not do this — anything above the
/// reader that changed height moved their words. Only the reader moves the
/// place: a scroll, a press on something (that thing is where they are), a
/// jump they asked for.
@Observable
@MainActor
final class ChatScrollCoordinator {
    var autoFollow: Bool
    /// The live edge is in view. Read by the re-arm and the Latest pill.
    private(set) var atBottom = true
    /// The transcript is pinned to an earlier page (a page anchor is set), so
    /// its bottom is not the live bottom. Read by the re-arm and the Latest
    /// pill's own gate, never by ChatView.body.
    var transcriptPagedBack = false

    private var serial = 0
    /// True only while the request holding the CURRENT serial is pending.
    /// Every serial bump supersedes that request, so every bump also clears
    /// the latch: a superseded block returns on the serial guard before it
    /// reaches its own `scheduled = false`, and a latch left standing behind
    /// it turned off ordinary auto-follow for the life of the view
    /// (2026-09-06).
    private var scheduled = false
    private var lastScrollAt = Date.distantPast
    /// Bumped every time the reader scrolls away from the bottom. A scroll
    /// scheduled before that gesture is stale, `force` or not — the old code
    /// let a forced repair fire seconds later and yank the viewport out from
    /// under someone reading upward (2026-09-06).
    private var disarmCount = 0

    /// A transcript that opens on its newest follows it; one read from the top
    /// (a crew's findings) starts in place.
    init(following: Bool = true) {
        autoFollow = following
    }

    func markViewDisappeared() {
        serial &+= 1
        scheduled = false
    }

    func forceFollow() {
        autoFollow = true
    }

    func disarmFollow() {
        if autoFollow { pickPlace() }
        autoFollow = false
        disarmCount &+= 1
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

    /// A press on the transcript: what was pressed is where the reader is, so
    /// a disclosure opening there grows downward instead of pushing it away.
    func pressed(atY y: CGFloat) {
        guard y >= viewport.top, y <= viewport.top + viewport.visible else { return }
        pressedAt = y
        if autoFollow { disarmFollow() } else { pickPlace() }
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

    func scrollToBottom(
        _ proxy: ScrollViewProxy,
        bottomAnchor: String,
        animated: Bool,
        delay: TimeInterval,
        force: Bool = false
    ) {
        guard force || autoFollow else { return }
        if force {
            serial &+= 1
            scheduled = false
        } else if scheduled {
            return
        }

        let minInterval: TimeInterval = animated ? 0.12 : 0.16
        let elapsed = Date().timeIntervalSince(lastScrollAt)
        let effectiveDelay = force ? delay : max(delay, max(0, minInterval - elapsed))
        let expectedSerial = serial
        let expectedDisarm = disarmCount
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDelay) {
            guard expectedSerial == self.serial else { return }
            self.scheduled = false
            guard expectedDisarm == self.disarmCount else { return }
            guard force || self.autoFollow else { return }
            self.lastScrollAt = Date()
            if animated {
                // No SwiftUI Environment here, so Reduce Motion is read from
                // the system: for that reader the follow is an instant jump.
                withAnimation(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? nil : NativeAgentMotion.quick
                ) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchor, anchor: .bottom)
            }
        }
    }
}

extension EnvironmentValues {
    /// The transcript viewport a block reports to; nil outside a transcript.
    @Entry var readingPlace: ChatScrollCoordinator?
}

/// The one transcript scroll view. The main chat, the detached panel and
/// Simple's threads scroll through it, so the reader's place is kept the same
/// way in all of them (ChatScrollCoordinator).
struct TranscriptScrollView<Content: View>: View {
    let coordinator: ChatScrollCoordinator
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
                .coordinateSpace(.named(ChatScrollCoordinator.readingSpace))
        }
        .scrollPosition($position)
        // User, 2026-09-13: while the reader is at the bottom the scroll view
        // keeps the bottom pinned itself — no scroll command per token. Away
        // from it the offset is left alone (`.top`, the system default) and
        // the reader's place is put back by `blockMoved` instead.
        .defaultScrollAnchor(coordinator.autoFollow ? .bottom : .top, for: .sizeChanges)
        .onScrollPhaseChange { _, phase in coordinator.scrolling = phase.isScrolling }
        .onScrollGeometryChange(for: TranscriptViewportReading.self) { geometry in
            TranscriptViewportReading(
                offset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                top: geometry.contentInsets.top,
                visible: geometry.containerSize.height - geometry.contentInsets.top - geometry.contentInsets.bottom
            )
        } action: { old, new in
            coordinator.viewportChanged(from: old, to: new)
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
                    // Scrolling back DOWN to the bottom re-arms follow
                    // (2026-06-12). No snap: the reader is already there and
                    // still scrolling, and a forced jump moved the transcript
                    // under them as the pill left.
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
                    $0.frame(in: .named(ChatScrollCoordinator.readingSpace)).minY
                } action: { minY in
                    place.blockMoved(id, mount: mount, to: minY)
                }
                .onDisappear { place.blockGone(id, mount: mount) }
        } else {
            content
        }
    }
}
