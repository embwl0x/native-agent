import Foundation
import Testing
import NativeAgentCore
import PersistenceCore
@testable import Dispatcher

// MARK: - Wave 34 W06: native persona/system connector-action tests
//
// Exercises the 4 ported read-only persona/system connector actions directly
// (PersonaSystemActions.*). Parity targets are the Python handlers in
// the retired daemon: _exec_persona_read (3549), _exec_persona_list_skills
// (3757), _exec_workspace_list (3872), _exec_time_now (205).

// MARK: - Test fixtures

private func makeSandbox() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("PersonaSys-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
}

private func writeFile(_ url: URL, _ contents: String) {
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? contents.write(to: url, atomically: true, encoding: .utf8)
}

private func okObj(_ v: JSONValue) -> [String: JSONValue]? {
    guard case .object(let o) = v else { return nil }
    return o
}
private func str(_ v: JSONValue?) -> String? {
    if case .string(let s)? = v { return s }
    return nil
}
private func int(_ v: JSONValue?) -> Int? {
    switch v ?? .null {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return nil
    }
}
private func bool(_ v: JSONValue?) -> Bool? {
    if case .bool(let b)? = v { return b }
    return nil
}
private func arr(_ v: JSONValue?) -> [JSONValue]? {
    if case .array(let a)? = v { return a }
    return nil
}

/// A context with persona + data + workspace roots pinned to a sandbox so no
/// host env / global root resolution leaks into the test.
private func ctx(
    persona: URL? = nil, data: URL? = nil, workspace: URL? = nil, repo: URL? = nil
) -> ConnectorActionContext {
    ConnectorActionContext(
        repoRoot: repo?.path ?? "",
        dataRoot: data?.path,
        personaRoot: persona?.path,
        workspaceRoot: workspace?.path
    )
}

// MARK: - persona_read

@Test func personaReadSoulReturnsContent() {
    let persona = makeSandbox()
    writeFile(persona.appendingPathComponent("SOUL.md"), "I am the soul.")
    let res = PersonaSystemActions.personaRead(["kind": .string("soul")], ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    #expect(str(o["kind"]) == "soul")
    #expect(str(o["content"]) == "I am the soul.")
    #expect(int(o["size_bytes"]) == 14)
    #expect(str(o["path"]) == persona.appendingPathComponent("SOUL.md").path)
}

@Test func personaReadUnknownKindIsBadInput() {
    let persona = makeSandbox()
    let res = PersonaSystemActions.personaRead(["kind": .string("nope")], ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "bad_input")
}

@Test func personaReadSkillRequiresName() {
    let persona = makeSandbox()
    let res = PersonaSystemActions.personaRead(["kind": .string("skill")], ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "bad_input")
}

@Test func personaReadSkillRejectsTraversal() {
    let persona = makeSandbox()
    let res = PersonaSystemActions.personaRead(
        ["kind": .string("skill"), "skill_name": .string("../secrets")],
        ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "bad_input")
}

@Test func personaReadSkillFromPersonaBodies() {
    let persona = makeSandbox()
    let body = persona.appendingPathComponent("skills")
        .appendingPathComponent("bodies").appendingPathComponent("my-skill.md")
    writeFile(body, "# Skill\nbody here")
    let res = PersonaSystemActions.personaRead(
        ["kind": .string("skill"), "skill_name": .string("my-skill")],
        ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    #expect(str(o["content"]) == "# Skill\nbody here")
    #expect(str(o["path"]) == body.path)
}

@Test func personaReadSkillRejectsDirtyBody() {
    let persona = makeSandbox()
    let body = persona.appendingPathComponent("skills")
        .appendingPathComponent("bodies").appendingPathComponent("dirty.md")
    writeFile(body, "# Dirty\nUse this when the python daemon is needed.")
    let res = PersonaSystemActions.personaRead(
        ["kind": .string("skill"), "skill_name": .string("dirty")],
        ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "skill_hygiene_failed")
}

@Test func personaReadMissingFile() {
    let persona = makeSandbox()
    let res = PersonaSystemActions.personaRead(["kind": .string("user")], ctx(persona: persona))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "persona_not_found")
}

// MARK: - persona_list_skills

@Test func listSkillsSlimDefault() {
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/alpha.md"),
              "# Alpha\nThe alpha skill description.")
    writeFile(persona.appendingPathComponent("skills/bodies/beta.md"),
              "# Beta\nThe beta skill.")
    let res = PersonaSystemActions.personaListSkills([:], ctx(persona: persona, data: data))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    #expect(int(o["count"]) == 2)
    #expect(int(o["returned"]) == 2)
    // skills list is sorted.
    let names = arr(o["skills"])!.compactMap { str($0) }
    #expect(names == ["alpha", "beta"])
    // Slim manifest: name + description + source only.
    let manifest = arr(o["manifest"])!
    let first = okObj(manifest[0])!
    #expect(str(first["name"]) == "alpha")
    #expect(str(first["description"]) == "The alpha skill description.")
    #expect(str(first["source"]) == "persona")
    #expect(first["path"] == nil)  // slim: no path
}

@Test func listSkillsSkipsDirtyBodies() {
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/clean.md"),
              "# Clean\nClean skill description.")
    writeFile(persona.appendingPathComponent("skills/bodies/dirty.md"),
              "# Dirty\nUse this when the python daemon is needed.")
    let dirtyRegistryBody = data.appendingPathComponent("skills/bodies/dirty-registry.md")
    writeFile(dirtyRegistryBody, "# Dirty Registry\nUse this when the python daemon is needed.")
    writeFile(data.appendingPathComponent("skills/registry.json"), """
    [{"name": "dirty-registry", "bodyPath": "\(dirtyRegistryBody.path)"}]
    """)
    let res = PersonaSystemActions.personaListSkills([:], ctx(persona: persona, data: data))
    let o = okObj(res)!
    let names = arr(o["skills"])!.compactMap { str($0) }
    #expect(names == ["clean"])
    #expect(int(o["count"]) == 1)
}

@Test func listSkillsPersonaWinsOnCollision() {
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/dup.md"), "# Dup\npersona version")
    writeFile(data.appendingPathComponent("skills/bodies/dup.md"), "# Dup\ndata version")
    let res = PersonaSystemActions.personaListSkills([:], ctx(persona: persona, data: data))
    let o = okObj(res)!
    #expect(int(o["count"]) == 1)
    let manifest = arr(o["manifest"])!
    let first = okObj(manifest[0])!
    #expect(str(first["source"]) == "persona")  // persona/ claimed it
    #expect(str(first["description"]) == "persona version")
}

@Test func listSkillsVerboseIncludesPath() {
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/gamma.md"), "# Gamma\nGamma desc.")
    let res = PersonaSystemActions.personaListSkills(
        ["verbose": .bool(true)], ctx(persona: persona, data: data))
    let o = okObj(res)!
    let manifest = arr(o["manifest"])!
    let first = okObj(manifest[0])!
    #expect(str(first["path"])?.hasSuffix("gamma.md") == true)
    #expect(str(first["source"]) == "persona")
}

@Test func listSkillsPagination() {
    let persona = makeSandbox()
    let data = makeSandbox()
    for n in ["a", "b", "c", "d"] {
        writeFile(persona.appendingPathComponent("skills/bodies/\(n).md"), "# \(n)\ndesc \(n)")
    }
    let res = PersonaSystemActions.personaListSkills(
        ["offset": .int(1), "limit": .int(2)], ctx(persona: persona, data: data))
    let o = okObj(res)!
    #expect(int(o["count"]) == 4)   // total before paging
    #expect(int(o["returned"]) == 2)
    let names = arr(o["skills"])!.compactMap { str($0) }
    #expect(names == ["b", "c"])    // sorted a,b,c,d → offset 1, limit 2
}

@Test func listSkillsRegistryMetadataMerge() {
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/withreg.md"), "# WithReg\nBody desc.")
    let reg = """
    [{"name": "withreg", "triggers": ["t1", "t2"], "kind": "tool", "useCount": 5}]
    """
    writeFile(data.appendingPathComponent("skills/registry.json"), reg)
    let res = PersonaSystemActions.personaListSkills(
        ["verbose": .bool(true)], ctx(persona: persona, data: data))
    let o = okObj(res)!
    let manifest = arr(o["manifest"])!
    let first = okObj(manifest[0])!
    #expect(str(first["kind"]) == "tool")
    #expect(int(first["use_count"]) == 5)
    let triggers = arr(first["triggers"])!.compactMap { str($0) }
    #expect(triggers == ["t1", "t2"])
}

@Test func listSkillsRegistryOnlyStub() {
    let persona = makeSandbox()
    let data = makeSandbox()
    // No body file; registry references a missing skill.
    let reg = """
    [{"name": "ghost", "description": "I have no body file."}]
    """
    writeFile(data.appendingPathComponent("skills/registry.json"), reg)
    let res = PersonaSystemActions.personaListSkills([:], ctx(persona: persona, data: data))
    let o = okObj(res)!
    #expect(int(o["count"]) == 1)
    let manifest = arr(o["manifest"])!
    let first = okObj(manifest[0])!
    #expect(str(first["name"]) == "ghost")
    #expect(str(first["source"]) == "registry")
    #expect(str(first["description"]) == "I have no body file.")
    let sources = okObj(o["sources"] ?? .null)!
    #expect(int(sources["registry_only"]) == 1)
}

// MARK: - workspace_list

@Test func workspaceListEmptyWhenAbsent() {
    let ws = makeSandbox().appendingPathComponent("nonexistent-ws")
    let res = PersonaSystemActions.workspaceList([:], ctx(workspace: ws))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    #expect(int(o["count"]) == 0)
    #expect(arr(o["items"])!.isEmpty)
}

@Test func workspaceListDirsBeforeFiles() {
    let ws = makeSandbox()
    writeFile(ws.appendingPathComponent("zfile.txt"), "z")
    writeFile(ws.appendingPathComponent("afile.txt"), "aa")
    try? FileManager.default.createDirectory(
        at: ws.appendingPathComponent("subdir"), withIntermediateDirectories: true)
    let res = PersonaSystemActions.workspaceList([:], ctx(workspace: ws))
    let o = okObj(res)!
    let items = arr(o["items"])!.map { okObj($0)! }
    // Sort: dirs first (by name), then files (by name).
    #expect(str(items[0]["path"]) == "subdir")
    #expect(bool(items[0]["is_dir"]) == true)
    #expect(str(items[1]["path"]) == "afile.txt")
    #expect(int(items[1]["size_bytes"]) == 2)
    #expect(str(items[2]["path"]) == "zfile.txt")
    #expect(int(items[2]["size_bytes"]) == 1)
    #expect(int(o["count"]) == 3)
}

@Test func workspaceListSkipsGitkeep() {
    let ws = makeSandbox()
    writeFile(ws.appendingPathComponent(".gitkeep"), "")
    writeFile(ws.appendingPathComponent("real.txt"), "x")
    let res = PersonaSystemActions.workspaceList([:], ctx(workspace: ws))
    let o = okObj(res)!
    let items = arr(o["items"])!.map { okObj($0)! }
    #expect(items.count == 1)
    #expect(str(items[0]["path"]) == "real.txt")
}

@Test func workspaceListSubdirEscapeRejected() {
    let ws = makeSandbox()
    let res = PersonaSystemActions.workspaceList(
        ["subdir": .string("../../etc")], ctx(workspace: ws))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "path_not_allowed")
}

@Test func workspaceListSubdirRelativePaths() {
    let ws = makeSandbox()
    writeFile(ws.appendingPathComponent("sub/nested.txt"), "n")
    let res = PersonaSystemActions.workspaceList(
        ["subdir": .string("sub")], ctx(workspace: ws))
    let o = okObj(res)!
    let items = arr(o["items"])!.map { okObj($0)! }
    #expect(items.count == 1)
    // rel is computed against the WORKSPACE ROOT, so it includes the subdir.
    #expect(str(items[0]["path"]) == "sub/nested.txt")
}

@Test func workspaceListFileAsTargetIsError() {
    // gpt-5.5 review #5: an existing-but-not-a-directory target must surface
    // ok=false (NotADirectoryError), NOT an empty ok=true list.
    let ws = makeSandbox()
    writeFile(ws.appendingPathComponent("afile.txt"), "x")
    let res = PersonaSystemActions.workspaceList(
        ["subdir": .string("afile.txt")], ctx(workspace: ws))
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
}

@Test func listSkillsVerboseOmitsEmptyTriggersAndKind() {
    // gpt-5.5 review #3: an empty triggers list / empty kind string must NOT
    // add the key (retired truthiness).
    let persona = makeSandbox()
    let data = makeSandbox()
    writeFile(persona.appendingPathComponent("skills/bodies/empt.md"), "# Empt\nEmpt desc.")
    let reg = """
    [{"name": "empt", "triggers": [], "kind": ""}]
    """
    writeFile(data.appendingPathComponent("skills/registry.json"), reg)
    let res = PersonaSystemActions.personaListSkills(
        ["verbose": .bool(true)], ctx(persona: persona, data: data))
    let o = okObj(res)!
    let first = okObj(arr(o["manifest"])![0])!
    #expect(first["triggers"] == nil)
    #expect(first["kind"] == nil)
}

@Test func listSkillsNegativeOffsetSlicesFromEnd() {
    // gpt-5.5 review #4: Python sorted_names[offset:] honours a negative offset.
    let persona = makeSandbox()
    let data = makeSandbox()
    for n in ["a", "b", "c", "d"] {
        writeFile(persona.appendingPathComponent("skills/bodies/\(n).md"), "# \(n)\nd")
    }
    let res = PersonaSystemActions.personaListSkills(
        ["offset": .int(-2)], ctx(persona: persona, data: data))
    let o = okObj(res)!
    let names = arr(o["skills"])!.compactMap { str($0) }
    #expect(names == ["c", "d"])  // last 2 of sorted a,b,c,d
}

// MARK: - time_now

@Test func timeNowDefaultLocalShape() {
    let res = PersonaSystemActions.timeNow([:], ctx())
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    // date YYYY-MM-DD, time HH:MM:SS
    #expect(str(o["date"])?.count == 10)
    #expect(str(o["time"])?.count == 8)
    #expect(str(o["dayOfWeek"]) != nil)
    #expect(int(o["epochSeconds"]) != nil)
    // iso carries an offset (ends with Z-equivalent +HH:MM or -HH:MM)
    let iso = str(o["iso"])!
    #expect(iso.contains("T"))
}

@Test func timeNowExplicitTimezone() {
    let res = PersonaSystemActions.timeNow(["timezone": .string("UTC")], ctx())
    let o = okObj(res)!
    #expect(bool(o["ok"]) == true)
    #expect(str(o["timezone"]) == "UTC")
    #expect(str(o["utcOffset"]) == "+0000")
    #expect(str(o["iso"])?.hasSuffix("+00:00") == true)
    // utcIso always +00:00
    #expect(str(o["utcIso"])?.hasSuffix("+00:00") == true)
}

@Test func timeNowUnknownTimezoneIsBadInput() {
    let res = PersonaSystemActions.timeNow(["timezone": .string("Mars/Olympus")], ctx())
    let o = okObj(res)!
    #expect(bool(o["ok"]) == false)
    #expect(str(o["error_code"]) == "bad_input")
}

@Test func timeNowTzAliasField() {
    // Python: inp.get("timezone") or inp.get("tz") — tz used when timezone absent.
    let res = PersonaSystemActions.timeNow(["tz": .string("UTC")], ctx())
    let o = okObj(res)!
    #expect(str(o["timezone"]) == "UTC")
}

// MARK: - registry wiring

@Test func registryKnowsWave34Actions() {
    let reg = LocalConnectorActions.fileSystemDefault
    #expect(reg.canHandle("persona_read"))
    #expect(reg.canHandle("persona_list_skills"))
    #expect(reg.canHandle("workspace_list"))
    #expect(reg.canHandle("time_now"))
    // All read-only — none side-effecting.
    #expect(reg.isSideEffecting("persona_read") == false)
    #expect(reg.isSideEffecting("persona_list_skills") == false)
    #expect(reg.isSideEffecting("workspace_list") == false)
    #expect(reg.isSideEffecting("time_now") == false)
}

// MARK: - Wave 36 W11 (§6.138): persona_read NFKC kind canonicalization parity

/// The daemon canonicalizes `kind` with NFKC+strip+lower
///, so cased / whitespace-padded / fullwidth-
/// confusable variants of a valid kind must ALL resolve to the canonical file
/// — matching the write side. The original wave-34 W06 port only trimmed, so
/// these inputs would have wrongly returned bad_input on the native flip path.
@Test func personaReadKindNFKCCanonicalizationParity() {
    let persona = makeSandbox()
    writeFile(persona.appendingPathComponent("SOUL.md"), "soul body")
    // (label, raw kind) — every one MUST canonicalize to "soul" and read SOUL.md.
    let variants: [(String, String)] = [
        ("upper", "SOUL"),
        ("mixed-case", "SoUl"),
        ("leading/trailing space", "  soul  "),
        ("tab+newline", "\tsoul\n"),
        ("fullwidth confusable", "\u{FF33}\u{FF2F}\u{FF35}\u{FF2C}"),  // ＳＯＵＬ
        ("nbsp padded", "\u{00A0}soul\u{00A0}"),
    ]
    for (label, raw) in variants {
        let res = PersonaSystemActions.personaRead(["kind": .string(raw)], ctx(persona: persona))
        let o = okObj(res)!
        #expect(bool(o["ok"]) == true, "\(label): expected ok for raw kind \(raw.debugDescription)")
        // Returned kind is the CANONICAL lowercased form (matches daemon: "kind": kind).
        #expect(str(o["kind"]) == "soul", "\(label): expected canonical kind 'soul'")
        #expect(str(o["content"]) == "soul body", "\(label): expected SOUL.md content")
    }
}

// MARK: - Wave 36 W11 (§6.138): scoped .personaReadOnly registry + trivial-verify

@Test func personaReadOnlyRegistryIsScopedToPersonaRead() {
    let reg = LocalConnectorActions.personaReadOnly
    // Exactly ONE action — persona_read — is native here. The other 13
    // file/system actions stay DORMANT (HTTP-proxied) under this scoped flip.
    #expect(reg.canHandle("persona_read"))
    #expect(reg.toolNames == ["persona_read"])
    #expect(reg.canHandle("read_file") == false)
    #expect(reg.canHandle("write_file") == false)
    #expect(reg.canHandle("persona_list_skills") == false)
    #expect(reg.canHandle("time_now") == false)
    // persona_read is read-only + TRIVIAL_VERIFY (daemon: side_effects=False,
    // verify=Tool.TRIVIAL_VERIFY → verify_passed=True on a successful read).
    #expect(reg.isSideEffecting("persona_read") == false)
    #expect(reg.isTrivialVerify("persona_read") == true)
}

// MARK: - Wave 37 W08 (§6.159): scoped .workspaceListReadOnly registry + trivial-verify

@Test func workspaceListReadOnlyRegistryIsScopedToWorkspaceList() {
    let reg = LocalConnectorActions.workspaceListReadOnly
    // Exactly ONE action — workspace_list — is native here. Every other
    // file/system/persona action stays DORMANT (HTTP-proxied) under this scoped
    // flip, INCLUDING persona_read (which is flipped by the SEPARATE, independent
    // .dispatchPersonaRead leash, not this one).
    #expect(reg.canHandle("workspace_list"))
    #expect(reg.toolNames == ["workspace_list"])
    #expect(reg.canHandle("persona_read") == false)
    #expect(reg.canHandle("read_file") == false)
    #expect(reg.canHandle("write_file") == false)
    #expect(reg.canHandle("persona_list_skills") == false)
    #expect(reg.canHandle("time_now") == false)
    // workspace_list is read-only + TRIVIAL_VERIFY (daemon: side_effects=False,
    // verify=Tool.TRIVIAL_VERIFY → verify_passed=True on a successful list).
    #expect(reg.isSideEffecting("workspace_list") == false)
    #expect(reg.isTrivialVerify("workspace_list") == true)
}

// MARK: - Wave 38 W07 (§6.180): scoped .timeNowReadOnly registry + trivial-verify

@Test func timeNowReadOnlyRegistryIsScopedToTimeNow() {
    let reg = LocalConnectorActions.timeNowReadOnly
    // Exactly ONE action — time_now — is native here. Every other
    // file/system/persona action stays DORMANT (HTTP-proxied) under this scoped
    // flip, INCLUDING persona_read + workspace_list (each flipped by its OWN
    // SEPARATE, independent leash, not this one).
    #expect(reg.canHandle("time_now"))
    #expect(reg.toolNames == ["time_now"])
    #expect(reg.canHandle("persona_read") == false)
    #expect(reg.canHandle("workspace_list") == false)
    #expect(reg.canHandle("persona_list_skills") == false)
    #expect(reg.canHandle("read_file") == false)
    #expect(reg.canHandle("write_file") == false)
    // time_now is read-only + TRIVIAL_VERIFY (daemon: side_effects=False,
    // verify=Tool.TRIVIAL_VERIFY → verify_passed=True on a successful read).
    #expect(reg.isSideEffecting("time_now") == false)
    #expect(reg.isTrivialVerify("time_now") == true)
}

// MARK: - Wave 39 W08 (§6.201): scoped .personaListSkillsReadOnly registry + trivial-verify

@Test func personaListSkillsReadOnlyRegistryIsScopedToPersonaListSkills() {
    let reg = LocalConnectorActions.personaListSkillsReadOnly
    // Exactly ONE action — persona_list_skills — is native here. Every other
    // file/system/persona action stays DORMANT (HTTP-proxied) under this scoped
    // flip, INCLUDING persona_read + workspace_list + time_now (each flipped by
    // its OWN SEPARATE, independent leash, not this one).
    #expect(reg.canHandle("persona_list_skills"))
    #expect(reg.toolNames == ["persona_list_skills"])
    #expect(reg.canHandle("persona_read") == false)
    #expect(reg.canHandle("workspace_list") == false)
    #expect(reg.canHandle("time_now") == false)
    #expect(reg.canHandle("read_file") == false)
    #expect(reg.canHandle("write_file") == false)
    // persona_list_skills is read-only + TRIVIAL_VERIFY (daemon: side_effects=False,
    // verify=Tool.TRIVIAL_VERIFY → verify_passed=True on a successful list).
    #expect(reg.isSideEffecting("persona_list_skills") == false)
    #expect(reg.isTrivialVerify("persona_list_skills") == true)
}

@Test func fileSystemDefaultTrivialVerifyMarkings() {
    let reg = LocalConnectorActions.fileSystemDefault
    // All 13 read-only actions are TRIVIAL_VERIFY (daemon registrations).
    for t in ["read_file", "file_excerpt", "list_dir", "system_info", "grep",
              "git_status", "git_diff", "git_log", "repo_dirty_summary",
              "persona_read", "persona_list_skills", "workspace_list", "time_now"] {
        #expect(reg.isTrivialVerify(t) == true, "\(t) should be TRIVIAL_VERIFY")
    }
    // write_file is side-effecting with a REAL verify (_verify_write_file) — NOT
    // a trivial-verify; the native receipt must not blanket verify_passed=true.
    #expect(reg.isTrivialVerify("write_file") == false)
    #expect(reg.isSideEffecting("write_file") == true)
}
