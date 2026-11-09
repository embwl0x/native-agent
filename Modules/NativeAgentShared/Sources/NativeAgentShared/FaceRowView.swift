import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
// Blueprint: | `FaceRowView.swift` | Quiet native rows, drawn-call submission and row-local pending, failure and undo |

struct FaceRowView: View {
    let row: PartFace.Row
    let item: FaceItemID
    let door: any FaceDoor
    let session: FacePageSession
    let focus: FocusState<FaceFocus?>.Binding
    let move: (FaceItemID, Int) -> Void
    let sectionStyle: PartFace.Style
    let waiting: Bool
    let connectsTimeline: Bool
    @Environment(\.faceStyle) private var style
    @Environment(\.faceInList) private var inList
    @State private var confirming: PartFace.Action?
    @State private var pendingSet: String?
    @State private var pendingCall: PartFace.Call?
    @State private var hovering = false
    @State private var width: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    private var actions: [PartFace.Action] { row.actions ?? [] }
    private var operation: FacePageSession.Operation? { session.operations[item.row] }
    private var pendingOperation: FacePageSession.Operation? { operation?.outcome == nil || operation?.checking == true ? operation : nil }
    private var sent: String? { operation?.outcome == nil ? operation?.submission.value : nil }
    private var compact: Bool {
        let given = inList ? width + style.insets.leading + style.insets.trailing : width
        return given > 0 && given < 420
    }
    private var focused: Bool { focus.wrappedValue?.item == item }
    private var handlesRowKeys: Bool { focused && focus.wrappedValue != .control(item) }
    private var primary: PartFace.Action? {
        let primaries = actions.filter { $0.role == .primary }
        return primaries.count == 1 ? primaries.first : actions.count == 1 ? actions.first : nil
    }
    /// A page's commands, a row that is only its one action, and what asks for the person stay drawn; the rest come on hover or focus.
    private var keepsActions: Bool {
        sectionStyle == .flow || row.tone == .attention || actions.contains { $0.role == .primary }
            || (row.open == nil && row.control == nil && actions.count == 1)
    }
    private var pill: Bool { sectionStyle == .flow && !inList && row.control == nil && (row.open != nil || actions.count <= 1) }
    private var text: String {
        [row.title, row.detail, row.value, controlWords, row.at].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
    private var controlWords: String? {
        guard let control = row.control else { return nil }
        if let text = control.text { return session.drafts.value(key, seed: text) }
        if let number = control.number { return sent ?? String(number.value) }
        if let date = control.date { return sent ?? date }
        if let on = control.on { return (sent.map { $0 == "on" } ?? on) ? "on" : "off" }
        let selected = sent ?? control.selected
        return control.options?.first { $0.id == selected }?.label
    }
    private var key: String { session.draftKey(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            surface
            outcomeView
        }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .contextMenu { menu }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(text))
            .accessibilityActions { accessibleActions }
            .confirmationDialog(confirming.map { $0.label + " — " + row.title } ?? "", isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
                if let action = confirming {
                    Button(action.label, role: .destructive) { run(action); confirming = nil }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
            #if os(macOS)
            .focusable().focused(focus, equals: .row(item))
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard handlesRowKeys else { return .ignored }
                move(item, press.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onKeyPress(.return) {
                if case .action(let focusedItem, let id)? = focus.wrappedValue, focusedItem == item,
                   let action = actions.first(where: { $0.id == id }) {
                    perform(action); return .handled
                }
                guard focus.wrappedValue == .row(item) else { return .ignored }
                return activate() ? .handled : .ignored
            }
            .onKeyPress(.space) {
                guard focus.wrappedValue == .row(item), let control = row.control, let on = control.on else { return .ignored }
                set((sent.map { $0 == "on" } ?? on) ? "off" : "on", control)
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "c")) { press in
                guard press.modifiers == .command, handlesRowKeys else { return .ignored }
                copy(); return .handled
            }
            #else
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                ForEach(actions) { action in
                    Button(action.label) { perform(action) }
                        .foregroundStyle(action.role == .destructive ? Color.red : .primary)
                        .buttonStyle(.automatic)
                        .disabled(session.held(item) || action.unavailable != nil)
                }
            }
            #endif
    }

    @ViewBuilder private var surface: some View {
        if pill {
            // A command that can't run now still reads as one of the page's commands, greyed.
            Button { _ = activate() } label: {
                Text(row.title).font(.callout).lineLimit(1)
                    .foregroundStyle(primary?.role == .destructive ? Color.red : .primary)
                    .opacity(pendingOperation == nil ? 1 : 0)
                    .overlay { if pendingOperation != nil { ProgressView().controlSize(.mini) } }
                    .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(.quaternary))
            }
            .buttonStyle(.plain)
            .disabled(row.open == nil && (primary == nil || primary?.unavailable != nil || session.held(item)))
        } else {
            rowBody
                .frame(maxWidth: .infinity, minHeight: max(0, style.minimumHeight - style.insets.top - style.insets.bottom), alignment: .leading)
                .padding(inList ? EdgeInsets() : style.insets)
                .background(hovering || focused ? style.elevation : .clear)
                .overlay(alignment: compact && row.control != nil ? .topTrailing : .trailing) {
                    #if os(macOS)
                    if let pendingOperation {
                        // A pending act moves nothing on the page, however quick it turns out to be.
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.mini)
                            Button(door.cancellationLabel) { session.cancel(item) }.disabled(pendingOperation.cancelling).buttonStyle(.plain)
                        }
                        .font(style.detail).padding(4).background(style.actionSurface, in: RoundedRectangle(cornerRadius: 6))
                        .padding(.trailing, style.insets.trailing)
                    } else if !keepsActions, !actions.isEmpty, hovering || focused, row.control == nil || trailingWidth > 0 {
                        actionStrip.padding(4).background(style.actionSurface, in: RoundedRectangle(cornerRadius: 6))
                            .frame(maxWidth: max(0, width - style.insets.leading - style.insets.trailing
                                - (!compact && row.control != nil ? trailingWidth + 12 : 0)), alignment: .trailing)
                            .padding(.trailing, style.insets.trailing + (!compact && row.control != nil ? trailingWidth + 12 : 0))
                            .padding(.top, compact && row.control != nil ? style.insets.top : 0)
                    }
                    #endif
                }
        }
    }

    private var rowBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact {
                titleAndDetail
                trailing.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 12) {
                    titleAndDetail
                        .frame(width: sectionStyle == .values ? max(0, width * 0.45) : nil, alignment: .leading)
                        .frame(maxWidth: sectionStyle == .values ? nil : .infinity, alignment: .leading)
                    trailing
                        .frame(maxWidth: row.control?.text != nil || sectionStyle == .values ? .infinity : nil, alignment: .trailing)
                }
            }
            if keepsActions { actionStrip }
        }
        .background(alignment: .topLeading) {
            if connectsTimeline && !inList {
                GeometryReader { geometry in
                    Rectangle().fill(.quaternary)
                        .frame(width: 1, height: max(0, geometry.size.height + style.insets.top + style.insets.bottom - 7))
                        .offset(x: 3, y: 13)
                }
            }
        }
    }

    private var titleAndDetail: some View {
        HStack(alignment: .top, spacing: 8) {
            if waiting { ProgressView().controlSize(.small) }
            if sectionStyle == .timeline { Circle().fill(FaceTone.color(row.tone)).frame(width: 7, height: 7).padding(.top, 6) }
            if let symbol = row.symbol, !symbol.isEmpty {
                Image(systemName: symbol).foregroundStyle(FaceTone.color(row.tone)).frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                FaceWordTitle(title: row.title).font(style.title)
                    .foregroundStyle(row.tone == .quiet || sectionStyle == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if let detail = row.detail, !detail.isEmpty { Text(detail).font(style.detail).foregroundStyle(.secondary).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focus.wrappedValue = .row(item)
            if let link = row.open { door.open(link) }
        }
    }

    private var trailing: some View {
        VStack(alignment: compact ? .leading : .trailing, spacing: 2) {
            if let control = row.control { controlView(control) }
            if let value = row.value, !value.isEmpty {
                Text(value).font(style.value).foregroundStyle(row.tone.map(FaceTone.color) ?? .secondary).lineLimit(1)
            }
            if let at = row.at {
                Text(FaceTime.short(at) ?? at).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            } else if row.open != nil && row.control == nil && row.value == nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
    }

    private func controlView(_ control: PartFace.Control) -> some View {
        controlBody(control).modifier(FaceSetConfirmation(question: control.confirm, pending: $pendingSet, send: { value in
            submit("set", value, pendingCall)
            pendingCall = nil
        }))
    }

    @ViewBuilder private func controlBody(_ control: PartFace.Control) -> some View {
        if let text = control.text {
            FaceFieldInput.line(row.title, placeholder: control.placeholder ?? "", text: Binding(
                get: { session.drafts.value(key, seed: text) }, set: { session.drafts.set($0, for: key, baseline: text) }))
                .frame(maxWidth: .infinity).focused(focus, equals: .control(item))
                .onSubmit {
                    let value = session.drafts.value(key, seed: text)
                    submit("set", value, control.settingCall(value))
                }
        } else if let number = control.number {
            FaceFieldInput.number(row.title, words: sent ?? String(number.value),
                                  increment: { changeNumber(number, direction: 1, control: control) },
                                  decrement: { changeNumber(number, direction: -1, control: control) })
            .focused(focus, equals: .control(item))
            .disabled(session.held(item))
        } else if let iso = control.date {
            switch parsedDate(sent ?? iso) {
            case .success(let date):
                FaceFieldInput.date(row.title, value: Binding(get: { date }, set: { set($0.ISO8601Format(), control) }))
                    .focused(focus, equals: .control(item)).disabled(session.held(item))
            case .failure(let failure): Text("The date is unreadable: " + failure.localizedDescription).foregroundStyle(.red)
            }
        } else if let on = control.on {
            FaceFieldInput.toggle(row.title, value: Binding(get: { sent.map { $0 == "on" } ?? on }, set: { set($0 ? "on" : "off", control) }))
                .focused(focus, equals: .control(item))
                .disabled(session.held(item))
        } else if let options = control.options {
            FaceFieldInput.choice(row.title, options: options,
                                  value: Binding(get: { sent ?? control.selected ?? "" }, set: { set($0, control) }), allowsEmpty: false)
            .focused(focus, equals: .control(item))
            .disabled(session.held(item))
        }
    }

    private func parsedDate(_ iso: String) -> Result<Date, any Error> {
        Result { try Date.ISO8601FormatStyle().parse(iso) }
    }

    private func changeNumber(_ number: PartFace.Control.Number, direction: Double, control: PartFace.Control) {
        let current: Double
        if let sent {
            guard let value = Double(sent), value.isFinite else { return }
            current = value
        } else { current = number.value }
        let value = current + direction * (number.step ?? 1)
        guard value.isFinite, number.min.map({ value >= $0 }) != false, number.max.map({ value <= $0 }) != false else { return }
        set(String(value), control)
    }

    private var actionStrip: some View {
        ViewThatFits(in: .horizontal) {
            stripButtons.fixedSize()
            Menu { ForEach(actions) { action in actionButton(action) } } label: { Image(systemName: "ellipsis") }
                .fixedSize().accessibilityLabel(Text("More"))
                .focused(focus, equals: .actionMenu(item))
        }
        .font(.callout)
    }

    private var stripButtons: some View {
        HStack(spacing: 8) {
            ForEach(compact ? Array(actions.prefix(2)) : actions) { action in
                actionButton(action).focused(focus, equals: .action(item, action.id))
            }
            if compact && actions.count > 2 {
                Menu { ForEach(Array(actions.dropFirst(2))) { action in actionButton(action) } } label: {
                    Image(systemName: "ellipsis")
                }.fixedSize().accessibilityLabel(Text("More"))
                    .focused(focus, equals: .actionMenu(item))
            }
        }
        .lineLimit(1)
    }

    private func actionButton(_ action: PartFace.Action) -> some View {
        Button(action.label + (action.unavailable.map { " (unavailable: " + $0 + ")" } ?? "")) { perform(action) }
            .buttonStyle(.plain)
            .foregroundStyle(action.role == .destructive ? Color.red : .primary)
            .disabled(session.held(item) || action.unavailable != nil)
    }

    @ViewBuilder private var menu: some View {
        if let link = row.open { Button(row.title) { door.open(link) } }
        ForEach(actions) { action in actionButton(action) }
        if pendingOperation != nil { Button(door.cancellationLabel) { session.cancel(item) } }
        Divider()
        Button("Copy") { copy() }
    }

    @ViewBuilder private var accessibleActions: some View {
        if let link = row.open { Button(row.title) { door.open(link) } }
        ForEach(actions) { action in actionButton(action) }
        if pendingOperation != nil { Button(door.cancellationLabel) { session.cancel(item) } }
        Button("Copy") { copy() }
    }

    @discardableResult private func activate() -> Bool {
        if let link = row.open { door.open(link); return true }
        if let primary { perform(primary); return true }
        return false
    }

    private func perform(_ action: PartFace.Action) {
        guard !session.held(item), action.unavailable == nil else { return }
        if action.role == .destructive { confirming = action } else { run(action) }
    }

    private func run(_ action: PartFace.Action) {
        if let link = action.open { door.open(link) }
        else { submit(action.id, nil, action.call) }
    }

    private func set(_ value: String, _ control: PartFace.Control) {
        guard !session.held(item) else { return }
        if control.confirm?.isEmpty == false { pendingCall = control.settingCall(value); pendingSet = value }
        else { submit("set", value, control.settingCall(value)) }
    }

    private func submit(_ action: String, _ value: String?, _ call: PartFace.Call?) {
        session.submit(item, row: row.id, action: action, value: value, call: call, door: door)
    }

    @ViewBuilder private var outcomeView: some View {
        if pill, let reason = primary?.unavailable { Text(reason).font(style.detail).foregroundStyle(.secondary) }
        if let refusal = session.refusals[item.row] { Text(refusal.localizedDescription).foregroundStyle(.red).textSelection(.enabled) }
        if let operation {
            if let outcome = operation.outcome, !operation.checking {
                if let failure = outcome.failure {
                    Text(failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    ForEach((failure.fields ?? [:]).keys.sorted(), id: \.self) { field in
                        if let words = failure.fields?[field] { Text(field + ": " + words).foregroundStyle(.red) }
                    }
                }
                if outcome.unresolved {
                    Text(outcome.effects == .unknown ? "This may have happened. Read its current state before repeating it."
                        : "The owner has not confirmed a terminal outcome. Read its current state before repeating it.")
                        .foregroundStyle(.secondary)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Read current state") { session.check(item, door: door) }.buttonStyle(.plain)
                }
                if let undo = outcome.undo, !session.held(item) {
                    Button("Undo") {
                        session.submit(item, row: row.id, action: "undo", value: nil, call: undo, door: door,
                                       undoOf: operation.submission.id)
                    }.buttonStyle(.plain)
                }
            } else {
                #if !os(macOS)
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operation.cancelling ? "Waiting on cancellation — " + row.title
                        : "Waiting on " + (operation.checking ? "current state — " : "") + row.title)
                    Button(door.cancellationLabel) { session.cancel(item) }.disabled(operation.cancelling).buttonStyle(.plain)
                }
                #endif
            }
        }
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

/// Independent words avoid constructing every possible prefix of a long title.
private struct FaceWordTitle: View {
    let title: String

    var body: some View {
        FaceTitleLine {
            ForEach(Array(title.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, word in Text(word).fixedSize() }
            Text(" ").fixedSize()
            Text("…")
        }
        .clipped().accessibilityElement(children: .ignore).accessibilityLabel(Text(title))
    }
}

private struct FaceTitleLine: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let words = subviews.dropLast(2)
        let space = subviews.dropLast().last?.sizeThatFits(.unspecified).width ?? 0
        let sizes = words.map { $0.sizeThatFits(.unspecified) }
        let width = sizes.reduce(CGFloat.zero) { $0 + $1.width } + CGFloat(max(0, words.count - 1)) * space
        let height = sizes.map(\.height).max() ?? subviews.last?.sizeThatFits(.unspecified).height ?? 0
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let words = subviews.dropLast(2)
        let space = subviews.dropLast().last?.sizeThatFits(.unspecified).width ?? 0
        let ellipsis = subviews.last?.sizeThatFits(.unspecified) ?? .zero
        let total = words.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            + CGFloat(max(0, words.count - 1)) * space
        let limit = total > bounds.width ? bounds.maxX - ellipsis.width : bounds.maxX
        var x = bounds.minX
        var clipped = false
        for word in words {
            let size = word.sizeThatFits(.unspecified)
            if !clipped, x + size.width <= limit {
                word.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(size))
                x += size.width + space
            } else {
                clipped = true
                word.place(at: CGPoint(x: bounds.maxX + 1, y: bounds.minY), proposal: ProposedViewSize(size))
            }
        }
        subviews.dropLast().last?.place(at: CGPoint(x: bounds.maxX + 1, y: bounds.minY), proposal: .zero)
        subviews.last?.place(at: CGPoint(x: clipped ? max(bounds.minX, x - space) : bounds.maxX + 1, y: bounds.minY),
                             proposal: ProposedViewSize(ellipsis))
    }
}

private struct FaceSetConfirmation: ViewModifier {
    let question: String?
    @Binding var pending: String?
    let send: (String) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(question ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Change") { if let value = pending { send(value) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        }
    }
}
