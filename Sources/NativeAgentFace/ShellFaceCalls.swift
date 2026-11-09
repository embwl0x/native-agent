import AppKit
import Foundation
import NativeAgentShared
// Blueprint: | `ShellFaceCalls.swift` | Scene, Desk, Work pane and clipboard reverse presentations |

@MainActor enum ShellFaceCalls {
    static func install(on router: FaceCallRouter, appModel: AppModel) {
        router.register({ call in
            switch call {
            case .copyText(let text):
                NSPasteboard.general.clearContents()
                guard NSPasteboard.general.setString(text, forType: .string) else {
                    throw PartCallError(code: "clipboard_unavailable", message: "The Mac clipboard did not accept this text.")
                }
                return .acknowledged
            case .navigate(let request): return try await ApplicationLifetime.shared.navigate(request)
            case .readScene: return .scene(try ApplicationLifetime.shared.sceneReport())
            case .desk(let request):
                _ = try await DeskWindowPresentation.shared.present(request)
                return .acknowledged
            case .showWorkPane(let name, let reference, let turn):
                let tab: WorkPaneTab
                switch name {
                case "steps": tab = .steps
                case "screen": tab = .screen
                case "make": tab = .make(ref: reference)
                case "sense": tab = .sense
                default: throw PartCallError(code: "work_tab_invalid", message: "The Work pane has no tab named " + name + ".")
                }
                guard !WorkPaneState.shared.userClosed(turnID: turn) else {
                    return .refused(.init(code: "work_pane_closed", message: "The person closed the Work pane for this turn.",
                                          cause: nil, effects: .none))
                }
                WorkPaneState.shared.agentShow(tab)
                return .workPane(WorkPaneState.shared.snapshot(appModel: appModel))
            case .hideWorkPane:
                WorkPaneState.shared.agentHide()
                return .workPane(WorkPaneState.shared.snapshot(appModel: appModel))
            case .readWorkPane:
                return .workPane(WorkPaneState.shared.snapshot(appModel: appModel))
            default: return nil
            }
        }, disconnect: { DeskWindowPresentation.shared.receiver = nil })
    }
}
