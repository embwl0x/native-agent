import NativeAgentShared
import NativeAgentCore

// Blueprint: | `ModuleLogging.swift` | `nativeLog`: module-local `ModuleLog` category for WorkshopExecution diagnostics |

@usableFromInline
let nativeLog = ModuleLog(category: "WorkshopExecution")
