import Foundation
// Blueprint: | `WorkPaneFace.swift` | Shared Work pages: Steps, Screen, version-bound Make controls and owner-resolved preview leaves |

public enum WorkPaneFace {
    public static func make(_ version: FaceMakeVersion, versions: [FaceMakeVersion], title: String,
                            preview: MakePreviewFace?) -> PartFace {
        let args: [String: PartFace.Value] = ["reference": .string(version.reference), "version": .string(version.version)]
        var sections: [PartFace.Section] = [.init(id: "version", rows: [
            .init(id: "version", title: title, actions: [
                .init(id: "use", label: "Use this", call: .init("exportMake", args))
            ], control: .choice(versions.map { .init(id: $0.version, label: $0.version) }, selected: version.version,
                               call: .init("selectMakeVersion", args)))
        ])]
        if let preview, preview.state == .ready {
            if let text = preview.text {
                sections.append(.init(id: "text", rows: [], block: .init(key: "make-text", text: text, copy: true)))
            }
            let leaf = preview.kind == "file" ? "preview" : preview.kind
            if let leaf, ["image", "preview", "web"].contains(leaf) {
                sections.append(.init(id: "preview", rows: [], block: .init(kind: "leaf", key: "make-preview", revision: preview.revision,
                    leaf: leaf, ref: version.reference, alt: title + " · version " + version.version)))
            }
        }
        if version.kind == "image", let prompt = version.prompt {
            sections.append(.init(id: "prompt", rows: [
                .init(id: "prompt", title: prompt, actions: [
                    .init(id: "again", label: "Try again", call: .init("make_again", args)),
                    .init(id: "variations", label: "Variations", call: .init("makeVariations", args))
                ])
            ]))
        }
        return PartFace(sections: sections)
    }

    public static func sense(_ presentation: SenseViewFace) -> PartFace {
        guard presentation.state == .ready else { return PartFace(sections: []) }
        guard let id = presentation.senseID, presentation.html != nil, let revision = presentation.revision else {
            return PartFace(sections: [.init(id: "sense", rows: [.init(id: "empty", title: "No sense view is open.", tone: .quiet)])])
        }
        return PartFace(title: presentation.title, sections: [.init(id: "sense", rows: [],
            block: .init(kind: "leaf", key: "sense-view", revision: revision, leaf: "web", ref: id,
                         alt: presentation.title ?? "Sense"))])
    }

    public static func steps(_ turn: TurnFace?) -> PartFace {
        let steps = turn?.steps ?? []
        let line: String
        if let turn, turn.isRunning { line = turn.liveLine ?? "Working" }
        else if turn == nil { line = "Waiting for turn status…" }
        else if steps.isEmpty { line = "When I'm working on something, my steps show up here." }
        else { line = "Here's what I did last time." }
        let rows = steps.enumerated().map { index, step in
            let symbol: String?
            switch step.outcome {
            case .ok?: symbol = "checkmark"
            case .failed?, .refused?: symbol = "xmark"
            case nil: symbol = nil
            }
            return PartFace.Row(id: String(index), title: step.text, symbol: symbol,
                                tone: step.outcome == .ok ? .quiet : step.outcome == nil ? .plain : .failed)
        }
        return PartFace(line: line, sections: [.init(id: "steps", style: .list, rows: rows)])
    }

    public static func screen(_ preview: TurnFace.Preview) -> PartFace {
        var rows = [PartFace.Row(id: "caption", title: preview.caption)]
        if preview.imageData != nil {
            rows.append(.init(id: "privacy", title: "Secure fields are painted out, and this picture is not saved.", tone: .quiet))
        } else if preview.readText != nil {
            rows.append(.init(id: "privacy", title: "The first screenful of the returned read. Secure field values are hidden; this preview is not saved.",
                              tone: .quiet))
        }
        return PartFace(sections: [.init(id: "screen", style: .note, rows: rows)])
    }
}
