import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `MakeSheetView.swift` | A Make table version drawn as a native table; a changed cell is laid as the next version by the person's tap |

/// A CSV or TSV version of a Make ref drawn as a table: a header row and rows, columns as wide as their words, numbers to the right. A
/// click on a cell edits it in place; Return saves the whole table as the next version of the ref, the person's own act, and Escape leaves
/// the cell as it was. Adding a row or a column is one save too. Find marks the rows that hold the words; Copy takes the file's text.
struct MakeSheetView: View {
    let file: URL
    let delimiter: Unicode.Scalar
    let reference: String
    let version: String
    /// A table already read, for a picture of the page: it is drawn as it is, with nothing loaded and nothing to change.
    var read: SheetTable? = nil
    @Environment(AppModel.self) private var appModel
    @State private var table: SheetTable?
    @State private var tooLarge = false
    @State private var issue: String?
    @State private var editing: MakeSheetCell?
    @State private var saving = false
    /// A saved table waits for its new version to be drawn in its place; a second change before then would be made from the old version.
    @State private var saved = false
    @State private var finding = false
    @State private var query = ""

    /// What is drawn stays quick: at most this many rows and columns. A larger table is drawn in part and changed only as a file.
    static let shownRows = 100
    static let shownColumns = 20

    var body: some View {
        Group {
            if let issue { Text(issue).foregroundStyle(.red).textSelection(.enabled) }
            else if tooLarge {
                Text("This table is over 2 MB, too large to draw here. The whole file is in Make.").foregroundStyle(.secondary)
            } else if let table = table ?? read { drawn(table) }
            else { Text("Reading the table…").foregroundStyle(.secondary) }
        }
        .task(id: file) {
            guard read == nil else { return }
            do {
                if let read = try await MakeSheetFile.table(file, delimiter: delimiter) { table = read } else { tooLarge = true }
            } catch { issue = "I couldn't read this table: " + error.localizedDescription }
        }
    }

    private func drawn(_ table: SheetTable) -> some View {
        let rows = table.rows.map { $0.fields.map(\.value) }
        let width = table.width
        let whole = rows.count <= Self.shownRows && width <= Self.shownColumns
        let shown = Array(rows.prefix(Self.shownRows))
        let columns = min(width, Self.shownColumns)
        let changeable = whole && !saving && !saved && read == nil
        let words = query.trimmingCharacters(in: .whitespaces)
        let found = Set(shown.indices.filter { row in !words.isEmpty && shown[row].contains { $0.localizedCaseInsensitiveContains(words) } })
        return VStack(alignment: .leading, spacing: 8) {
            if let said = MakeSheetWords.shared.said[reference] {
                Text(said).font(ShellType.label).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                if finding {
                    TextField("Find in this table", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    if !words.isEmpty { Text(Self.foundLine(found.count)).foregroundStyle(.secondary) }
                }
                Spacer()
                Button("Find", systemImage: "magnifyingglass") {
                    finding.toggle()
                    if !finding { query = "" }
                }
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(table.text, forType: .string)
                }
            }.buttonStyle(.borderless).font(.caption)
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(shown.indices, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { column in
                                cell(shown[row], row: row, column: column, editable: changeable, found: found.contains(row))
                            }
                            if row == 0, whole {
                                Button { change { $0.addColumn() } } label: { Image(systemName: "plus") }
                                    .buttonStyle(.borderless).disabled(!changeable).help("Add a column").padding(.horizontal, 6)
                            }
                        }
                    }
                }
            }
            if rows.isEmpty { Text("This table is empty.").foregroundStyle(.secondary) }
            if whole {
                Button("Add a row") { change { $0.addRow() } }.buttonStyle(.borderless).disabled(!changeable)
            } else {
                Text(Self.leftOut(rows: rows.count - shown.count, columns: width - columns)).font(ShellType.label).foregroundStyle(.secondary)
            }
            if saving { Text("Saving…").font(ShellType.label).foregroundStyle(.secondary) }
        }
        .padding(12)
    }

    @ViewBuilder private func cell(_ fields: [String], row: Int, column: Int, editable: Bool, found: Bool) -> some View {
        let text = fields.indices.contains(column) ? fields[column] : ""
        let at = MakeSheetCell(row: row, column: column)
        Group {
            if editing == at {
                MakeSheetCellEditor(text: text) { edited in
                    editing = nil
                    if let edited, edited != text { change { $0.set(row: row, column: column, to: edited) } }
                }
            } else {
                Text(text.isEmpty ? " " : text)
                    .font(row == 0 ? ShellType.labelSemibold : ShellType.label.monospacedDigit())
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 320, alignment: Self.isNumber(text) ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if editable { editing = at } }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(found ? Color.accentColor.opacity(0.18) : row == 0 ? Color.secondary.opacity(0.08) : Color.clear)
        .overlay(alignment: .bottom) { Divider() }
    }

    /// The whole changed table goes as one new version made from the version on screen; Make refuses it if a newer one was laid meanwhile.
    /// Only what changed is written anew: every other field and line break keeps the file's own bytes.
    private func change(_ edit: (inout SheetTable) -> Void) {
        guard let before = table else { return }
        var changed = before
        edit(&changed)
        table = changed
        saving = true
        MakeSheetWords.shared.said[reference] = nil
        Task {
            let words: String?
            do {
                let reply = try await appModel.client.act(.deskCommand(.init(command: "save_sheet", handle: reference, arguments: [
                    "version": .string(version), "name": .string(file.lastPathComponent), "content": .string(changed.text)])))
                words = try FaceWindowReply.message(reply)
                saved = true
            } catch {
                table = before
                words = error.localizedDescription
            }
            saving = false
            // What the save said belongs to the piece: it stays above whichever version is drawn next, the one just laid or the newer one
            // the save was refused for, until the person changes something or leaves the table.
            MakeSheetWords.shared.said[reference] = words
            WorkPaneState.shared.selectedMakeVersions[reference] = nil
        }
    }

    private static func foundLine(_ rows: Int) -> String {
        rows == 0 ? "No row holds these words." : rows == 1 ? "One row holds them." : "\(rows) rows hold them."
    }

    private static func leftOut(rows: Int, columns: Int) -> String {
        let parts = [rows > 0 ? "\(rows) more \(rows == 1 ? "row" : "rows")" : nil,
                     columns > 0 ? "\(columns) more \(columns == 1 ? "column" : "columns")" : nil].compactMap { $0 }
        return parts.joined(separator: " and ") + " aren't shown, so I don't change this table here. The whole file is in Make."
    }

    /// A number reads right-aligned: digits with an optional sign, decimal point, grouping commas, a leading currency sign or a trailing %.
    private static func isNumber(_ text: String) -> Bool {
        var plain = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        if let first = plain.first, "$€£¥".contains(first) { plain.removeFirst() }
        if plain.hasSuffix("%") { plain.removeLast() }
        return !plain.isEmpty && Double(plain) != nil
    }
}

/// What a table's last save said, held for its Make ref rather than one version's view, so a refusal stays readable above the newer
/// version drawn in place of the refused one. The drawing that holds a piece lets it go when the person leaves (`PageMakePreview`,
/// `WorkPaneMakeView`).
@MainActor @Observable final class MakeSheetWords {
    static let shared = MakeSheetWords()
    var said: [String: String] = [:]
}

struct MakeSheetCell: Hashable {
    let row: Int
    let column: Int
}

/// One cell's words being changed: Return gives the new words, Escape or leaving the cell gives nil. It settles once.
private struct MakeSheetCellEditor: View {
    let text: String
    let end: (String?) -> Void
    @State private var draft = ""
    @State private var ended = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .font(ShellType.label)
            .frame(minWidth: 80, maxWidth: 320)
            .focused($focused)
            .onSubmit { settle(draft) }
            .onKeyPress(.escape) {
                settle(nil)
                return .handled
            }
            .onExitCommand { settle(nil) }
            .onChange(of: focused) { _, now in if !now { settle(nil) } }
            .onAppear {
                draft = text
                DispatchQueue.main.async { focused = true }
            }
    }

    private func settle(_ words: String?) {
        guard !ended else { return }
        ended = true
        end(words)
    }
}

/// The table file is read off the main actor, and only when its size is within what Make takes in hand: nil says it is larger, and nothing
/// of it was read.
enum MakeSheetFile {
    @concurrent static func table(_ file: URL, delimiter: Unicode.Scalar) async throws -> SheetTable? {
        guard let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw CocoaError(.fileReadUnknown) }
        guard size <= MakePreviewFace.wordsLimit else { return nil }
        guard let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return SheetTable(text, delimiter: delimiter)
    }
}
