import CoreGraphics
import AppKit
import Foundation
import NativeAgentShared
import SwiftUI
// Blueprint: | `BoardGeometry.swift` | The Mac board editor's system font at the current camera scale |

extension BoardGeometry {
    static func editorFont(_ element: BoardDocument.Element, zoom: CGFloat, table: Bool, textScale: CGFloat) -> Font {
        element.boardEditorFont(table: table, textScale: textScale, zoom: zoom)
    }
}
