import Foundation
import MacControl
import NativeAgentCore
import PersistenceCore
import Testing
@testable import ChatOrchestration

private struct _FourVerbViewHost: MacFourVerbsHost {
    let output: JSONValue
    func dispatch(action: String, body: [String: JSONValue]) async throws -> MacControlResult {
        #expect(action == "view")
        #expect(body["semantic_raw_frame"] == .bool(true))
        #expect(body["semantic_focus_visual_surface"] == .bool(true))
        return MacControlResult(
            ok: true, action: action, output: output,
            error: nil, durationMs: 0, viaSwift: true
        )
    }
}

private func _viewMark(
    _ number: Int,
    role: String,
    label: String?,
    x: Double
) -> JSONValue {
    var object: [String: JSONValue] = [
        "mark": .int(Int64(number)),
        "role": .string(role),
        "enabled": .bool(true),
        "frame": .object([
            "x": .double(x), "y": .double(100), "w": .double(80), "h": .double(28),
        ]),
    ]
    if let label { object["label"] = .string(label) }
    else { object["label_source"] = .string("none") }
    return .object(object)
}

@Test
func fusedViewMakesInferredRowsAndUnnamedControlsAddressableWithoutLeakingViewIds() async {
    let marks: [JSONValue] = [
        _viewMark(1, role: "AXRow", label: "Screenshots", x: 10),
        _viewMark(2, role: "AXTextArea", label: nil, x: 100),
        _viewMark(3, role: "AXButton", label: "Back", x: 200),
        _viewMark(4, role: "AXButton", label: "Forward", x: 300),
        _viewMark(5, role: "AXButton", label: "Share", x: 400),
        _viewMark(6, role: "AXButton", label: "View", x: 500),
        _viewMark(7, role: "AXButton", label: "More", x: 600),
    ]
    let host = _FourVerbViewHost(output: .object([
        "view": .string("private-view-token"),
        "accessibility_trusted": .bool(true),
        "marks": .array(marks),
    ]))
    let supplement = await SwiftToolDispatcherFourVerbPerceptionSource(host: host).observe()

    #expect(supplement?.targets.contains(where: { $0.label?.display == "Screenshots" }) == true)
    #expect(supplement?.targets.contains(where: { $0.label?.display == "text area 1" }) == true)
    #expect(supplement?.controls.contains(where: { $0.label.display == "text area 1" }) == true)
    #expect(supplement?.targets.allSatisfy { $0.viewId == "private-view-token" } == true)
}
