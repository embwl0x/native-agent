import Foundation
import NativeAgentCore
import PersistenceCore
import ChatTurnContracts
import AgentWorkspace
import MemoryV2
import ProviderRouting
import ToolRegistry
import NativeAgentShared
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import Dispatcher
import MacControl
import Senses
import StandingBots
// Blueprint: | `BuiltInToolSchemaFactory+FileSchemas.swift` | `BuiltInToolSchemaFactory`: `fileSchemas`, canonical `context_expand` descriptor |

extension BuiltInToolSchemaFactory {
    private static let canonicalContextExpandSchema = LLMToolSchema(
        name: "context_expand",
        toolClass: .read, capabilities: ["tool_call"],
        description: "Read deeper context by its offered atom id or a history: id from a replayed receipt. Context atoms are pinned to this turn's generation; history receipts are read from the current conversation.",
        parametersJSON: (try? JSONValue.object([
            "type": .string("object"),
            "properties": .object([
                "atom_id": .object([
                    "type": .string("string"),
                    "description": .string("Offered context atom id or history: id from a replayed receipt."),
                ]),
                "max_characters": .object([
                    "type": .string("integer"),
                    "description": .string("Optional bounded character limit."),
                ]),
                "offset": .object([
                    "type": .string("integer"),
                    "description": .string("Optional character offset, default 0. Continue with next_offset until null."),
                ]),
            ]),
            "required": .array([.string("atom_id")]),
        ]).serializedData(pretty: false)) ?? Data("{}".utf8)
    )

    func fileSchemas() -> [LLMToolSchema?] {
        [
            requestedSchema(name: "read_file", toolClass: .read,
                description: "Read a regular workspace/user-approved file; pipes/devices/sockets return unsupported_file_type. Text: byte windows (bytes=source size; offset/returned_bytes=current window; max_bytes=limit); follow next/has_more. Images: PNG/JPEG/WebP/GIF/HEIC/TIFF/BMP pixels, not OCR; ≤8 MiB/40 MP, first frame oriented/resized to 2048 px. Folder+match: ≤8 files. Read image paths to view; names/consult refs are not viewing. Relative paths use the canonical workspace; verified development checkouts also allow repo-relative paths. Full Mac file access admits absolute Mac paths except NativeAgent trust/secrets/provider paths; /documents/... maps to ~/Documents/.... Long handoff Markdown defaults to a compact leading window unless max_bytes is explicit.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("Workspace-relative path such as 'project/file.txt', a repo-relative path only when a verified source checkout exists, or an absolute/~/ path under a Trust workspace root. Persona files must use app persona.doc or persona.read. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>.")),
                        ("match", ToolSchema.strSchema("Glob for a folder path, e.g. '*-r4-*.png'.")),
                        ("query", ToolSchema.strSchema("Search the whole text source for complete lines containing every whitespace-separated term, case-insensitively. Returns records with line positions and full-source coverage, in source order. Pages fit 24000 serialized bytes; a larger single record is refused, never split. Continue only with next; max_bytes and offset are byte-mode arguments.")),
                        ("start_line", ToolSchema.intSchema("Search continuation's 1-based source line; omit initially and copy next unchanged.")),
                        ("max_lines", ToolSchema.intSchema("Matching lines per search page, default 80, capped at 240.")),
                        ("max_bytes", ToolSchema.intSchema("Optional source byte window: capped at 200,000 bytes; long handoff Markdown defaults to 12,000 bytes when omitted. This is a file-read limit, not a one-response guarantee: large results are delivered through result.page. UTF-8 characters stay whole; use at least 4 bytes to ensure progress.")),
                        ("offset", ToolSchema.intSchema("Byte offset, default 0. Continue with returned next arguments; positive offsets require version and a UTF-8 boundary.")),
                        ("version", ToolSchema.strSchema("Omit initially; copy next unchanged. file_changed means restart without version at offset 0 (bytes) or start_line 1 (search); never combine versions.")),
                    ],
                    required: ["path"]
                )
            ),
            requestedNames?.contains("context_expand") != false
                ? Self.canonicalContextExpandSchema
                : nil,
            requestedSchema(name: "list_dir", toolClass: .read,
                description: "List/filter immediate names in an approved folder. sort:size reads allocated disk usage for the folder and its children within a time budget, naming partial paths and lower bounds. Ordinary listings return bounded pages and next arguments; read selected text with files.excerpt. Public/app-only relative paths use the canonical workspace; verified development checkouts also accept repo-relative paths. Full Mac permits absolute paths except NativeAgent trust/secrets/provider paths.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("Directory path; omitted or empty lists the folder relative paths start from, as '.' does. In Full Mac mode, /documents/<name> maps to the current user's ~/Documents/<name>; a file_not_found result is a path miss, not a trust denial.")),
                        ("name_contains", ToolSchema.strSchema("Optional literal filename substring, not glob or regex; empty means all names.")),
                        ("sort", ToolSchema.enumStringSchema(["name", "newest", "added", "size"], "Ordering: name (default, folders first), newest (added then modified date), added (date added only to this folder, for install/download recency, including app bundles; rows include added_at; unknown dates sort last), or size (observed allocated bytes descending). Size scans return total allocated_bytes, size_complete, per-child sizes and partial_paths; incomplete sizes are lower bounds. Size scans cannot be paged; narrow path for more detail.")),
                        ("time_budget_seconds", ToolSchema.intSchema("Disk usage scan budget for sort:size, default 5, range 1–20 seconds; checked between metadata reads.")),
                        ("case_sensitive", ToolSchema.boolSchema("Whether filename matching is case-sensitive; default false (case-insensitive).")),
                        ("max_entries", ToolSchema.intSchema("Entries per page, default and maximum 200; minimum 1.")),
                        ("offset", ToolSchema.intSchema("Start at 0. For continuation pass the returned next arguments unchanged.")),
                        ("snapshot", ToolSchema.strSchema("Omit or empty on first page. Required with positive offset; copied from next. directory_changed means restart at offset 0 without snapshot.")),
                    ],
                    required: []
                )
            ),
            requestedSchema(name: "file_info", toolClass: .read,
                description: "Read one approved path's name, directory and regular flags, size in bytes and modified ISO 8601 date. Does not follow the final symbolic link. Uses the same file access as files.list.",
                parametersJSON: ToolSchema.params(properties: [("path", ToolSchema.strSchema("File or folder path, under the same approved roots as files.list."))], required: ["path"])
            ),
            requestedSchema(name: "write_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Create or write a UTF-8 file, creating missing parent folders automatically; append is optional. Ordinary project work belongs in NativeAgent's canonical workspace/ (public installs: ~/Library/Application Support/NativeAgent/workspace). Without Full Mac, stay within that workspace or a user-added Trust workspace root. Active Full Mac file access permits broader Mac writes except NativeAgent trust/secrets/provider paths and protected system mutations.",
                parametersJSON: ToolSchema.params(
                    properties: [
                        ("path", ToolSchema.strSchema("A relative path such as project/file.txt (resolved inside the canonical NativeAgent workspace), workspace/project/file.txt, or an absolute/~/ path inside another Trust workspace root. Full Mac mode also accepts broader Mac paths, but intentional build/project artifacts belong in the canonical workspace rather than /tmp.")),
                        ("content", ToolSchema.strSchema("Content to write.")),
                        ("append", ToolSchema.boolSchema("Append instead of replacing the file.")),
                        ("expected_content_sha256", ToolSchema.strSchema("Optional SHA-256 of the complete existing UTF-8 file, up to 64 KiB. Before replacement, refuse a missing or changed file with file_changed. Not supported with append.")),
                    ],
                    required: ["path", "content"]
                )
            ),
            requestedSchema(name: "trash_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Move a file or folder to the Trash for delete, remove or clean-up requests. Reversible: returns the original path and trash_path; restore from the Trash if needed. Uses the same workspace or Full Mac file access as writing files.",
                parametersJSON: ToolSchema.params(properties: [("path", ToolSchema.strSchema("File or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths."))], required: ["path"])
            ),
            requestedSchema(name: "move_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Move or rename a file or folder on the same filesystem, creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; no screen or Finder interaction needed.",
                parametersJSON: ToolSchema.params(properties: [
                    ("path", ToolSchema.strSchema("Existing file or folder path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", ToolSchema.strSchema("Complete new path including the filename or folder name, not just its containing folder. Missing parent folders are created.")),
                    ("overwrite", ToolSchema.boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
            requestedSchema(name: "copy_file",
                toolClass: .write, capabilities: ["filesystem_write", "outside_app_data_write", "tool_call"],
                description: "Copy a regular file, preserving its data and metadata and creating missing destination parent folders. Uses the same writable roots and guards as files.write. Refuses an existing destination unless overwrite:true was explicitly requested; folder copies are not supported. No screen or Finder interaction needed.",
                parametersJSON: ToolSchema.params(properties: [
                    ("path", ToolSchema.strSchema("Existing regular file path; relative paths use NativeAgent's workspace. Full Mac also accepts absolute/~/ paths.")),
                    ("destination", ToolSchema.strSchema("Complete new file path including the filename. Missing parent folders are created.")),
                    ("overwrite", ToolSchema.boolSchema("Replace an existing destination only when explicitly requested. Default false.")),
                ], required: ["path", "destination"])
            ),
        ]
    }
}
