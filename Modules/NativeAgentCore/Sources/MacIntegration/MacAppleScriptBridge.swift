import Foundation
import PersistenceCore
// Blueprint: | `MacAppleScriptBridge.swift` | integration executor namespace; OSA remains in AppleScriptExecution |

// MARK: - MacAppleScriptBridge
// MacControl owns execution and the bundle carries TCC descriptors; the upstream permission store owns admission.
public enum MacAppleScriptBridge {}
