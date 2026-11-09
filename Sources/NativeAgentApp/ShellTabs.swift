import Foundation
// Blueprint: | `ShellTabs.swift` | Stable page tab identities used by body routing and search |

struct ShellTab<Key: Hashable>: Identifiable {
    let key: Key
    let title: String
    var id: Key { key }
}
