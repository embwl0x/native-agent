import Foundation
import NativeAgentCore
import PersistenceCore
// Blueprint: | `AgentRecipeStore+Schema.swift` | Writes require the exact Codable recipe shape. |

extension AgentRecipeStore {
    /// The document write decodes exactly; optional fields also accept null, as Codable does.
    public static let writeArgumentSchema: JSONValue = {
        let text = ToolSchema.strSchema(), flag = ToolSchema.boolSchema(), integer = ToolSchema.intSchema()
        func list(_ item: JSONValue) -> JSONValue { .object(["type": .string("array"), "items": item]) }
        func map(_ value: JSONValue) -> JSONValue { .object(["type": .string("object"), "additionalProperties": value]) }
        func object(_ fields: [String: JSONValue], optional: [String: JSONValue] = [:]) -> JSONValue {
            .object(["type": .string("object"), "properties": .object(fields.merging(optional.mapValues(ToolSchema.nullable)) { _, value in value }),
                "required": .array(fields.keys.sorted().map(JSONValue.string)), "additionalProperties": .bool(false)])
        }
        func enumeration<T: RawRepresentable & CaseIterable>(_ type: T.Type) -> JSONValue where T.RawValue == String {
            ToolSchema.enumStringSchema(T.allCases.map(\.rawValue))
        }
        let strings = list(text)
        let control = object(["roles": strings], optional: ["label": text, "subrole": text])
        let action = enumeration(AgentHostRow.GrokRoutine.Step.Action.self)
        let dismissal = object(["control": control, "action": action, "ifPresent": flag])
        let step = object(["name": text, "scope": enumeration(AgentHostRow.GrokRoutine.Step.Scope.self),
            "control": control, "action": action], optional: ["alreadyOpen": control, "dismissal": dismissal])
        let routine = object(["mainChat": text, "routines": text, "webhookURL": text, "webhookKey": text], optional: [
            "list": control, "pause": control, "navigation": list(step), "copyURL": text, "copyKey": text])
        let desktop = object(Dictionary(uniqueKeysWithValues: ["newChat", "backToMain", "chatsButton", "chatsPanel", "log", "composerCore",
            "userPrefix", "assistantPrefix", "userLabel", "assistantMarker", "stop", "unreadSuffix", "actionsSuffix", "current", "currentValue"]
                .map { ($0, text) }),
            optional: ["contentRole": text])
        let card = object(["endpoint": text, "version": text, "binding": text, "auth": strings,
            "streaming": flag, "pushNotifications": flag, "extendedCard": flag,
            "skills": strings, "extensions": strings, "digest": text], optional: ["tenant": text])
        let a2a = object(["card": text], optional: ["credential": text, "read": card])
        let command = object(["executable": text, "arguments": strings, "continuation": strings,
            "capturesThreadID": flag, "jsonResultReply": flag, "automaticMCPProbe": flag,
            "timeoutSeconds": integer, "documentation": text], optional: ["replyFileName": text,
            "resultFields": map(text), "stream": enumeration(AgentHostCommandLine.Stream.self),
            "permissionFlags": enumeration(AgentHostCommandLine.PermissionFlags.self), "minimumVersion": text])
        let acp = object(["executable": text, "arguments": strings, "documentation": text, "permissionMode": text,
            "referenceVersion": text, "environment": map(text)], optional: ["protocolVersion": integer,
            "modes": strings, "supportsLoad": flag, "supportsResume": flag])
        let host = object(["id": text, "displayName": text, "description": text, "aliases": strings,
            "installMarkers": strings, "configPath": text, "format": enumeration(AgentHostRow.Format.self),
            "restartRequired": flag, "restartNote": text, "documentation": text, "requiresWorkspace": flag,
            "settingsSupported": flag, "bundleIDs": strings, "a2aPorts": list(integer), "searchPaths": strings], optional: [
            "declaredRoute": enumeration(AgentHostRow.Route.self), "configPaths": strings, "commandLine": command,
            "acp": acp, "a2a": a2a, "executables": strings, "discoveryWords": strings,
            "messagingPermissionsPath": text, "messagingPermissionSyntax": enumeration(AgentHostRow.MessagingPermissionSyntax.self),
            "desktopChat": desktop, "grokRoutine": routine])
        return object(["recipeVersion": ToolSchema.intSchema(minimum: 1, maximum: Int.max - 1),
            "seededFrom": text, "updatedAt": text, "source": text, "digest": text, "host": host],
            optional: ["seedHost": host, "authoredFields": strings])
    }()
}
