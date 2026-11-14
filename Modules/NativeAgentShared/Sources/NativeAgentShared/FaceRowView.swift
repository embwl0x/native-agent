import SwiftUI
import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
// Blueprint: | `FaceRowView.swift` | Quiet native rows, inline control groups, drawn-call submission and row-local pending, failure and undo |

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
    /// The section's inline-group columns (one child per word), so every row's group lines up under every other.
    var columns: [PartFace.Row] = []
    /// Set when this row is one control of its parent's inline group: the parent's title, drawn as the word and its control alone.
    var cellOf: String? = nil
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
    /// A page's commands, a row that is only its one action, and what asks for the person stay drawn; the rest come on hover or focus. A row
    /// that already says its state (a value such as "Granted") is not only its action, so it stays one line.
    private var keepsActions: Bool {
        sectionStyle == .flow || row.tone == .attention || actions.contains { $0.role == .primary }
            || (row.open == nil && row.control == nil && actions.count == 1 && (row.value ?? "").isEmpty)
    }
    /// A row with an inline group is never a pill: it draws as a line with its group in every section style.
    private var pill: Bool {
        sectionStyle == .flow && !inList && row.control == nil && row.group.isEmpty && (row.open != nil || actions.count <= 1)
    }
    private var text: String {
        [row.title, row.detail, row.value, controlWords, groupWords, row.at].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }
    /// A control's name where it is read aloud: an inline group's child is "<parent>, <word>"; its visible word stays short.
    private var label: String { cellOf.map { $0 + ", " + row.title } ?? row.title }
    private var groupWords: String? {
        guard !row.group.isEmpty else { return nil }
        return row.group.map { child in
            let operation = session.operations[child.id]
            let sent = operation?.outcome == nil ? operation?.submission.value : nil
            guard let on = child.control?.on else { return child.title }
            return child.title + ((sent.map { $0 == "on" } ?? on) ? " on" : " off")
        }.joined(separator: ", ")
    }
    private func childItem(_ child: PartFace.Row) -> FaceItemID { FaceItemID(section: item.section, row: child.id) }
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
        if cellOf != nil { cell } else { line }
    }

    private var line: some View {
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
            #if os(macOS)
            .help(row.detail ?? "")
            #endif
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
            if !row.group.isEmpty {
                // The group is placed by what fits, not by a width threshold: beside the title when both fit, beneath it otherwise.
                FaceBesideOrBeneath(spacing: 12, lineSpacing: 4) {
                    titleAndDetail
                    trailing
                }
            } else if compact {
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
            Group {
                if stacksDetail {
                    VStack(alignment: .leading, spacing: 2) { titleWords; detailWords }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        titleWords.layoutPriority(1)
                        if detailFitsBeside { detailWords }
                    }
                    #if os(macOS)
                    .help(row.detail ?? "")
                    #endif
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focus.wrappedValue = .row(item)
            if let link = row.open { door.open(link) }
        }
    }

    private var titleWords: some View {
        FaceWordTitle(title: row.title).font(style.title)
            .foregroundStyle(row.tone == .quiet || sectionStyle == .note ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
    }

    @ViewBuilder private var detailWords: some View {
        if let detail = row.detail, !detail.isEmpty {
            Text(detail).font(style.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
    }

    /// A row is one line. What asks for the person or went wrong keeps its second line, and so does a narrow door.
    private var stacksDetail: Bool {
        compact || waiting || sectionStyle == .waiting || row.tone == .attention || row.tone == .failed
    }

    /// The detail sits beside the title when real room is left for it; otherwise the title has the line and the detail is its tooltip.
    private var detailFitsBeside: Bool {
        let room = width - style.insets.leading - style.insets.trailing - trailingWidth - 24
        return room - CGFloat(row.title.count) * 7.5 > 120
    }

    private var trailing: some View {
        VStack(alignment: compact ? .leading : .trailing, spacing: 2) {
            if !row.group.isEmpty { group }
            if let control = row.control { controlView(control) }
            if row.meter != nil || row.value?.isEmpty == false {
                HStack(spacing: 8) {
                    if let meter = row.meter { FaceMeterBar(meter: meter, color: row.tone.map(FaceTone.color) ?? .secondary) }
                    if let value = row.value, !value.isEmpty {
                        Text(value).font(style.value).foregroundStyle(row.tone.map(FaceTone.color) ?? .secondary).lineLimit(1)
                    }
                }
            }
            if let at = row.at {
                Text(FaceTime.short(at) ?? at).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            } else if row.open != nil && row.control == nil && row.value == nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trailingWidth = $0 }
    }

    /// The row's inline group: each child's word then its control, in the section's columns, so a missing child leaves its column empty.
    /// Side by side when the cells fit the width they are given; stacked one under another, each with its word, when they do not.
    private var group: some View {
        FaceGroupCells(spacing: style.insets.trailing, lineSpacing: 4) {
            ForEach(columns.isEmpty ? row.group : columns) { column in
                let child = row.group.first(where: { $0.title == column.title })
                Group {
                    if let child {
                        // A cell is its child: another child in the same column is a new view with fresh confirmation state.
                        groupCell(child).id(child.id)
                    } else {
                        // Unseen, it holds the column's width: the same word and control another row draws here, under an item and an
                        // identity of its own so it never shares that child's focus or state.
                        groupCell(column, item: FaceItemID(section: item.section, row: "unseen:" + row.id + "/" + column.id))
                            .disabled(true).hidden().accessibilityHidden(true).id("unseen:" + column.id)
                    }
                }
                .layoutValue(key: FaceUnseenCell.self, value: child == nil)
            }
        }
    }

    private func groupCell(_ child: PartFace.Row, item: FaceItemID? = nil) -> FaceRowView {
        FaceRowView(row: child, item: item ?? childItem(child), door: door, session: session, focus: focus, move: move, sectionStyle: sectionStyle,
                    waiting: false, connectsTimeline: false, cellOf: row.title)
    }

    /// One control of an inline group: its short word, then its control. Its confirmation is this view's own; its pending and failure are
    /// its own row's in the session, keyed by its own id, as a stacked row's are. The parent draws its failure beneath the line.
    private var cell: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(row.title).font(style.detail).foregroundStyle(.secondary).lineLimit(1).fixedSize().accessibilityHidden(true)
            if let control = row.control {
                // A pending set moves nothing on the line: the control gives way to a spinner in its own place.
                controlView(control).controlSize(.small)
                    .opacity(pendingOperation == nil ? 1 : 0)
                    .overlay { if pendingOperation != nil { ProgressView().controlSize(.mini) } }
            }
        }
        #if os(macOS)
        .help(row.detail ?? "")
        #endif
    }

    private func controlView(_ control: PartFace.Control) -> some View {
        controlBody(control).modifier(FaceSetConfirmation(question: control.confirm, pending: $pendingSet, send: { value in
            submit("set", value, pendingCall)
            pendingCall = nil
        }))
    }

    @ViewBuilder private func controlBody(_ control: PartFace.Control) -> some View {
        if let text = control.text {
            FaceFieldInput.line(label, placeholder: control.placeholder ?? "", text: Binding(
                get: { session.drafts.value(key, seed: text) }, set: { session.drafts.set($0, for: key, baseline: text) }))
                .frame(maxWidth: .infinity).focused(focus, equals: .control(item))
                .onSubmit {
                    let value = session.drafts.value(key, seed: text)
                    submit("set", value, control.settingCall(value))
                }
        } else if let number = control.number {
            FaceFieldInput.number(label, words: sent ?? String(number.value),
                                  increment: { changeNumber(number, direction: 1, control: control) },
                                  decrement: { changeNumber(number, direction: -1, control: control) })
            .focused(focus, equals: .control(item))
            .disabled(session.held(item))
        } else if let iso = control.date {
            switch parsedDate(sent ?? iso) {
            case .success(let date):
                FaceFieldInput.date(label, value: Binding(get: { date }, set: { set($0.ISO8601Format(), control) }))
                    .focused(focus, equals: .control(item)).disabled(session.held(item))
            case .failure(let failure): Text("The date is unreadable: " + failure.localizedDescription).foregroundStyle(.red)
            }
        } else if let on = control.on {
            FaceFieldInput.toggle(label, value: Binding(get: { sent.map { $0 == "on" } ?? on }, set: { set($0 ? "on" : "off", control) }))
                .focused(focus, equals: .control(item))
                .disabled(session.held(item))
        } else if let options = control.options {
            FaceFieldInput.choice(label, options: options,
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
        groupCancels
        Divider()
        Button("Copy") { copy() }
    }

    @ViewBuilder private var accessibleActions: some View {
        if let link = row.open { Button(row.title) { door.open(link) } }
        ForEach(actions) { action in actionButton(action) }
        if pendingOperation != nil { Button(door.cancellationLabel) { session.cancel(item) } }
        groupCancels
        Button("Copy") { copy() }
    }

    /// A pending inline child is cancelled from its parent's menu, named by its word.
    @ViewBuilder private var groupCancels: some View {
        ForEach(row.group.filter { session.held(childItem($0)) }) { child in
            Button(door.cancellationLabel + " — " + child.title) { session.cancel(childItem(child)) }
        }
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
        outcome(row, item, word: nil)
        // An inline child's refusal, failure and undo are its own, drawn beneath the line it sits on and named by its word.
        ForEach(row.group) { child in outcome(child, childItem(child), word: child.title) }
    }

    @ViewBuilder private func outcome(_ row: PartFace.Row, _ item: FaceItemID, word: String?) -> some View {
        let named = word.map { $0 + ": " } ?? ""
        let name = word.map { self.row.title + " · " + $0 } ?? row.title
        if let refusal = session.refusals[item.row] { Text(named + refusal.localizedDescription).foregroundStyle(.red).textSelection(.enabled) }
        if let operation = session.operations[item.row] {
            if let outcome = operation.outcome, !operation.checking {
                if let failure = outcome.failure {
                    Text(named + failure.localizedDescription).foregroundStyle(.red).textSelection(.enabled)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    ForEach((failure.fields ?? [:]).keys.sorted(), id: \.self) { field in
                        if let words = failure.fields?[field] { Text(field + ": " + words).foregroundStyle(.red) }
                    }
                }
                if outcome.unresolved {
                    Text(named + (outcome.effects == .unknown ? "This may have happened. Read its current state before repeating it."
                        : "The owner has not confirmed a terminal outcome. Read its current state before repeating it."))
                        .foregroundStyle(.secondary)
                    if let words = outcome.words { Text(words).foregroundStyle(.secondary).textSelection(.enabled) }
                    Button("Read current state") { session.check(item, door: door) }.buttonStyle(.plain)
                }
                if let undo = outcome.undo, !session.held(item) {
                    Button(word.map { "Undo " + $0 } ?? "Undo") {
                        session.submit(item, row: row.id, action: "undo", value: nil, call: undo, door: door,
                                       undoOf: operation.submission.id)
                    }.buttonStyle(.plain)
                }
            } else {
                #if !os(macOS)
                HStack {
                    ProgressView().controlSize(.small)
                    Text(operation.cancelling ? "Waiting on cancellation — " + name
                        : "Waiting on " + (operation.checking ? "current state — " : "") + name)
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

/// One line, cut by the system at its tail. A plain Text is measured once and cached, so a title as long as a whole prompt costs the
/// same as a short one however deeply its row is nested; only the part a line could ever show is handed over.
private struct FaceWordTitle: View {
    let title: String

    var body: some View {
        Text(title.prefix(400)).lineLimit(1).truncationMode(.tail)
            .accessibilityLabel(Text(title))
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

/// A row's length as a bar: its share of the whole, set where it begins. The value's words say the amount; the bar is not read aloud.
struct FaceMeterBar: View {
    let meter: PartFace.Row.Meter
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let whole = meter.max > 0 ? meter.max : 1
            let start = min(max((meter.start ?? 0) / whole, 0), 1)
            let length = min(max(meter.value / whole, 0), 1 - start)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(2, geometry.size.width * length)).offset(x: geometry.size.width * start)
            }
        }
        .frame(width: 72, height: 6)
        .accessibilityHidden(true)
    }
}

/// Marks a cell drawn unseen only to hold its column's width; a stacked group leaves it out.
private struct FaceUnseenCell: LayoutValueKey {
    static let defaultValue = false
}

/// A row's title and its inline group, placed by what fits: the group beside the title at the trailing edge when both fit the width
/// offered, beneath the title otherwise. One set of views is measured and placed (where `ViewThatFits` would keep a live copy of every
/// switch per arrangement, each with its own confirmation and the same focus value), so every control keeps one identity and one state.
private struct FaceBesideOrBeneath: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private func beside(_ width: CGFloat?, _ subviews: Subviews) -> Bool {
        guard subviews.count == 2, let width else { return true }
        return subviews[0].sizeThatFits(.unspecified).width + spacing + subviews[1].sizeThatFits(.unspecified).width <= width + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return subviews.first?.sizeThatFits(proposal) ?? .zero }
        let lead = subviews[0], trail = subviews[1]
        if beside(proposal.width, subviews) {
            let trailSize = trail.sizeThatFits(.unspecified)
            let leadSize = lead.sizeThatFits(ProposedViewSize(width: proposal.width.map { max(0, $0 - spacing - trailSize.width) }, height: nil))
            return CGSize(width: proposal.width ?? leadSize.width + spacing + trailSize.width, height: max(leadSize.height, trailSize.height))
        }
        let column = ProposedViewSize(width: proposal.width, height: nil)
        let leadSize = lead.sizeThatFits(column), trailSize = trail.sizeThatFits(column)
        return CGSize(width: proposal.width ?? max(leadSize.width, trailSize.width), height: leadSize.height + lineSpacing + trailSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else {
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            return
        }
        let lead = subviews[0], trail = subviews[1]
        if beside(bounds.width, subviews) {
            let trailSize = trail.sizeThatFits(.unspecified)
            lead.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                       proposal: ProposedViewSize(width: max(0, bounds.width - spacing - trailSize.width), height: bounds.height))
            trail.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: ProposedViewSize(trailSize))
        } else {
            let column = ProposedViewSize(width: bounds.width, height: nil)
            let leadSize = lead.sizeThatFits(column)
            lead.place(at: bounds.origin, proposal: column)
            trail.place(at: CGPoint(x: bounds.minX, y: bounds.minY + leadSize.height + lineSpacing), proposal: column)
        }
    }
}

/// An inline group's cells: side by side when they fit the width offered, otherwise stacked one under another, each cell still its
/// word then its control. A cell drawn unseen to hold a column takes no line when the cells stack.
private struct FaceGroupCells: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    private func across(_ sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + spacing * CGFloat(max(0, sizes.count - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let wide = across(sizes)
        if proposal.width.map({ wide <= $0 + 0.5 }) ?? true { return CGSize(width: wide, height: sizes.map(\.height).max() ?? 0) }
        let seen = zip(subviews, sizes).filter { !$0.0[FaceUnseenCell.self] }.map(\.1)
        return CGSize(width: seen.map(\.width).max() ?? 0,
                      height: seen.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, seen.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if across(sizes) <= bounds.width + 0.5 {
            var x = bounds.minX
            for (subview, size) in zip(subviews, sizes) {
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        } else {
            var y = bounds.minY
            for (subview, size) in zip(subviews, sizes) {
                if subview[FaceUnseenCell.self] {
                    subview.place(at: bounds.origin, proposal: .zero)
                    continue
                }
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(size))
                y += size.height + lineSpacing
            }
        }
    }
}
