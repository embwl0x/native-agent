import MacNerves
import NativeAgentCore
import NativeAgentShared
import PersistenceCore
import DeskCore
import SenseCore
import Foundation
import ProviderRouting
import MindCore
// Blueprint: | `AppActions+FilesGroup.swift` | Files action declarations |

extension AppActions {
    static func filesGroup() throws -> [AppAction] {
        try [
        .fold("image_generate", "chat"),

        .fold("read_file", "files", """
            Read a workspace/approved file or image pixels; query searches the whole text. Continue with returned next arguments, including version
            """, read: true),
        .fold("list_dir", "files", """
            List names/dates in an approved folder. sort:newest orders by added then modified date; sort:added by date added, including app bundles; \
            sort:size reads allocated disk usage within a time budget and names partial results
            """, read: true),
        .fold("file_info", "files", "Read name, directory/regular flags, size and modified date without following the final symbolic link", read: true),
        .fold("file_excerpt", "files", read: true),
        .fold("grep", "files", read: true),
        .fold("mac_spotlight_search", "files", read: true),
        .fold("write_file", "files"),
        .fold("move_file", "files"),
        .fold("copy_file", "files"),
        .fold("trash_file", "files", resultSchema: trashResultSchema),
        .fold("apply_patch", "files", "Apply a unified diff with paths relative to cwd",
              warn: #"Example app {action:"files.patch",args:{cwd:"/absolute/path/to/repo",patch:"--- a/note.txt\n+++ b/note.txt\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"}}; supply actual content/ranges; the marker is only for missing final newlines"#),
        .fold("git_status", "shell", """
            Read parsed branch and changes; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("git_diff", "shell", "Read changes; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd", read: true),
        .fold("git_log", "shell", """
            Read commits and changed files; omitted path uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("repo_dirty_summary", "shell", """
            Read branch, changes and recent commits; omitted cwd uses the app's verified source checkout, or workspace when none exists; returns cwd
            """, read: true),
        .fold("shell", "shell", """
            Run a command with sh; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd
            """,
              warn: """
                  Requires Full Mac file access. Only a literal command certified by the shell owner reads (including pwd, df and simple git \
                  log/status/diff/show); shell syntax and all other commands remain writes. Certified reads run under read-only confinement. Invalid cwd or \
                  another pre-launch refusal returns execution:not_run, effect:none.
                  """),
        .fold("bash", "shell", """
            Run a command with bash; cwd defaults to your workspace, relative cwd starts there; select the source checkout with explicit cwd
            """,
              warn: """
                  Requires Full Mac file access. The same read certification and confinement as shell.run applies; all other commands remain writes. \
                  Pre-launch refusals return execution:not_run, effect:none.
                  """),
        .fold("swift_build", "shell"),
        .fold("swift_test", "shell"),
        .fold("remote_node_list", "shell", read: true),
        .fold("remote_node_execute", "shell"),
        .fold("restart_app", "shell"),
        .fold("install_app", "shell"),
        .fold("read_page", "web", read: true,
              warn: """
                  find reads matching paragraphs with surroundings; without find the whole extracted text is read. raw:true bypasses the sense view; \
                  wrong:true reads the original view and offers repair guidance after success (why is an optional explanation). Every successful fetch \
                  retains a source receipt with its path and purpose. Thin JavaScript pages use Chrome in another background tab through the same browser \
                  gates, say used_browser:true and retain the HTTP receipt separately. text_reader names browser only when it has more readable content; \
                  otherwise HTTP text stays at the top with the browser result and cause attached. \
                  Chrome may use the signed-in session. Consent is never dismissed.
                  """),
        .fold("web_search", "web", read: true),
        .fold("maps_route", "web", "Read a route, distance and driving time between places", read: true,
              warn: """
                  traffic: not_included; time assumes ideal conditions. Every step is returned; step distance covers its path segment, not just its turn/exit.
                  """),
        .fold("maps_search", "web", "Find nearby places and addresses in Maps", read: true,
              warn: "near is optional when query includes near/in/around plus a place, for example coffee near Tampa airport; the result says what was split."),
        ]
    }
}
