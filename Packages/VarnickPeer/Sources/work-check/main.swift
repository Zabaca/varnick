import Foundation
import VarnickPeer

// `make check-work`: the work-link hooks (`WorkHooks`) and the `/work` script's two commands, run as shell scripts in each shell found here
// (sh, bash, zsh, dash), on scratch pane folders and a scratch repository. No Varnick, no claude and no network; it touches nothing outside its
// scratch folder. One `error:` line a failed case, exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-work: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

// MARK: Scratch

let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("check-work-\(UUID().uuidString)")
try! fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }
let repo = scratch.appendingPathComponent("repo")

struct Ran {
    var status: Int32
    var out: String
}

func run(_ exe: String, _ args: [String], env: [String: String] = [:], stdin: String = "", cwd: URL? = nil) -> Ran {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: exe)
    process.arguments = args
    process.currentDirectoryURL = cwd
    var environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": scratch.path, "GIT_CONFIG_NOSYSTEM": "1"]
    environment.merge(env) { _, new in new }
    process.environment = environment
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    do { try process.run() } catch { fatalError("cannot run \(exe): \(error)") }
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return Ran(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self))
}

func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }
func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// A pane folder with a new id, as the app makes one: the hooks find it from the session file's folder.
struct Pane {
    let folder: URL
    var id: String { folder.lastPathComponent }
    var env: [String: String] { ["VARNICK_SESSION_FILE": folder.appendingPathComponent(".varnick-session.json").path] }
    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    var log: [[Substring]] {
        (text(file("work-log")) ?? "").split(whereSeparator: \.isNewline).map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
    }
    var kinds: [String] { log.map { $0.count > 3 ? String($0[3]) : "?" } }
}

func freshPane() -> Pane {
    let folder = scratch.appendingPathComponent("panes").appendingPathComponent(UUID().uuidString.lowercased())
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    return Pane(folder: folder)
}

// A repository with one problem and its first option, on main with no commit: enough for the script's checks.
func git(_ args: [String]) { _ = run("/usr/bin/git", args, cwd: repo) }
try! fm.createDirectory(at: repo.appendingPathComponent("docs/problems/p/options"), withIntermediateDirectories: true)
try! "---\ntitle: P\n---\n".write(to: repo.appendingPathComponent("docs/problems/p/problem.md"), atomically: true, encoding: .utf8)
try! "---\nstatus: accepted\n---\n".write(to: repo.appendingPathComponent("docs/problems/p/options/01-x.md"), atomically: true, encoding: .utf8)
git(["init", "-q", "-b", "main"])

let shells: [String] = {
    var found: [String] = []
    var names: Set<String> = []
    for path in ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/usr/bin/dash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash"] where fm.isExecutableFile(atPath: path) {
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if names.insert(real).inserted { found.append(path) }
    }
    return found
}()
expect("shells: sh is found", shells.contains("/bin/sh"))

let skill = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".claude/skills/work/work.sh")
expect("the script is found at \(skill.path)", exists(skill))

// MARK: The hooks

func hook(_ script: String, _ shell: String, _ pane: Pane?, _ input: [String: Any]) -> Ran {
    run(shell, ["-c", script], env: pane?.env ?? [:], stdin: json(input))
}

let root = "/scratch/main-checkout"
func marker(_ pane: Pane, kind: String, value: String, nonce: String) -> String {
    try! "".write(to: pane.file(".work-mark.\(nonce)"), atomically: true, encoding: .utf8)
    return "VARNICK-WORK|\(pane.id)|\(nonce)|\(kind)|\(value)|\(root)|"
}

func bashCall(_ output: String, agent: String? = nil) -> [String: Any] {
    var input: [String: Any] = ["session_id": "s1", "hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_response": ["stdout": output]]
    if let agent { input["agent_id"] = agent; input["agent_type"] = "builder" }
    return input
}

func agentCall(_ event: String, _ agent: String?) -> [String: Any] {
    var input: [String: Any] = ["session_id": "s1", "hook_event_name": event, "transcript_path": "/x/s1.jsonl"]
    if let agent { input["agent_id"] = agent; input["agent_type"] = "builder" }
    return input
}

let record = "option p/03\nrepo \(root)\nagent builder\n"

for shell in shells {
    let tag = "[\(shell)] "
    let pane = freshPane()
    var ran: Ran

    // The marker makes the subagent's record.
    ran = hook(WorkHooks.mark, shell, pane, bashCall("ok\n" + marker(pane, kind: "option", value: "p/03", nonce: "aa11") + "\n", agent: "a1"))
    expect(tag + "mark: prints nothing, exits 0", ran.status == 0 && ran.out.isEmpty, "\(ran.status) \(ran.out)")
    expect(tag + "mark: writes the subagent's record", text(pane.file("work.a1")) == record, "\(String(describing: text(pane.file("work.a1"))))")
    expect(tag + "mark: takes the nonce", !exists(pane.file(".work-mark.aa11")))
    expect(tag + "mark: logs the link", pane.kinds == ["option"], "\(pane.kinds)")

    // The same marker printed again links nothing.
    try? fm.removeItem(at: pane.file("work.a1"))
    _ = hook(WorkHooks.mark, shell, pane, bashCall("VARNICK-WORK|\(pane.id)|aa11|option|p/03|\(root)|", agent: "a1"))
    expect(tag + "mark: a replayed marker links nothing", !exists(pane.file("work.a1")))
    // Put the record back for what follows.
    _ = hook(WorkHooks.mark, shell, pane, bashCall(marker(pane, kind: "option", value: "p/03", nonce: "bb22"), agent: "a1"))
    expect(tag + "mark: the record is back", text(pane.file("work.a1")) == record)

    // SubagentStop holds the record; it no longer counts as live.
    ran = hook(WorkHooks.subagentStop, shell, pane, agentCall("SubagentStop", "a1"))
    expect(tag + "stop: prints nothing, exits 0", ran.status == 0 && ran.out.isEmpty, "\(ran.status) \(ran.out)")
    expect(tag + "stop: the record is gone from the live name", !exists(pane.file("work.a1")))
    expect(tag + "stop: the record is held", text(pane.file(".work-held.a1")) == record)
    expect(tag + "stop: logs the end", pane.kinds.last == "end", "\(pane.kinds)")
    expect(tag + "stop: the board's reader finds no live link", PaneFolder.work(in: pane.folder).live.isEmpty)

    // SubagentStart gives it back, under the same agent id.
    let before = pane.kinds.count
    ran = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", "a1"))
    expect(tag + "start: prints nothing, exits 0", ran.status == 0 && ran.out.isEmpty, "\(ran.status) \(ran.out)")
    expect(tag + "start: the record is back", text(pane.file("work.a1")) == record)
    expect(tag + "start: nothing is held", !exists(pane.file(".work-held.a1")))
    expect(tag + "start: logs the link again", pane.kinds.count == before + 1 && pane.kinds.last == "option", "\(pane.kinds)")
    expect(tag + "start: the reader finds the link", PaneFolder.work(in: pane.folder).live.map(\.agentID) == ["a1"])

    // A start with nothing held changes nothing, and not even the log.
    let logBefore = text(pane.file("work-log"))
    _ = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", "a1"))
    _ = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", "zz9"))
    expect(tag + "start: nothing held, nothing done", text(pane.file("work-log")) == logBefore && !exists(pane.file("work.zz9")))

    // A start does not replace a record the subagent already has.
    try! "problem q\nrepo \(root)\nagent builder\n".write(to: pane.file(".work-held.a1"), atomically: true, encoding: .utf8)
    _ = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", "a1"))
    expect(tag + "start: its own record stands", text(pane.file("work.a1")) == record)
    try? fm.removeItem(at: pane.file(".work-held.a1"))

    // A stop with no record of its own holds nothing, and a call with no agent id touches the session's record.
    let stopLog = text(pane.file("work-log"))
    _ = hook(WorkHooks.subagentStop, shell, pane, agentCall("SubagentStop", "nobody"))
    expect(tag + "stop: no record, nothing held", !exists(pane.file(".work-held.nobody")) && text(pane.file("work-log")) == stopLog)
    _ = hook(WorkHooks.mark, shell, pane, bashCall(marker(pane, kind: "problem", value: "p", nonce: "cc33")))
    expect(tag + "mark: the session's record", text(pane.file("work")) == "problem p\nrepo \(root)\n", "\(String(describing: text(pane.file("work"))))")
    _ = hook(WorkHooks.subagentStop, shell, pane, agentCall("SubagentStop", nil))
    _ = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", nil))
    expect(tag + "stop and start with no agent id leave the session's record", text(pane.file("work")) == "problem p\nrepo \(root)\n")

    // A held record whose id is not safe to name a file is never read.
    ran = hook(WorkHooks.subagentStart, shell, pane, agentCall("SubagentStart", "../x"))
    expect(tag + "start: an unsafe id is ignored", ran.status == 0 && ran.out.isEmpty)

    // Outside a Varnick pane the hooks do nothing.
    ran = hook(WorkHooks.subagentStop, shell, nil, agentCall("SubagentStop", "a1"))
    expect(tag + "stop: outside a pane", ran.status == 0 && ran.out.isEmpty)
    ran = hook(WorkHooks.subagentStart, shell, nil, agentCall("SubagentStart", "a1"))
    expect(tag + "start: outside a pane", ran.status == 0 && ran.out.isEmpty)
}

// Clearing, as a pane starting claude does it: live and held records go, the session's stays, the log says so.
do {
    let pane = freshPane()
    try! "problem p\nrepo \(root)\n".write(to: pane.file("work"), atomically: true, encoding: .utf8)
    try! record.write(to: pane.file("work.a2"), atomically: true, encoding: .utf8)
    try! record.write(to: pane.file(".work-held.a3"), atomically: true, encoding: .utf8)
    PaneFolder.clearSubagentWork(in: pane.folder)
    expect("clear: removes the live record", !exists(pane.file("work.a2")))
    expect("clear: removes the held record", !exists(pane.file(".work-held.a3")))
    expect("clear: keeps the session's record", exists(pane.file("work")))
    expect("clear: logs the end", pane.kinds == ["end"], "\(pane.kinds)")
    PaneFolder.clearSubagentWork(in: pane.folder)
    expect("clear: nothing to clear logs nothing", pane.kinds == ["end"], "\(pane.kinds)")
    let onlyHeld = freshPane()
    try! record.write(to: onlyHeld.file(".work-held.a4"), atomically: true, encoding: .utf8)
    PaneFolder.clearSubagentWork(in: onlyHeld.folder)
    expect("clear: a held record alone is removed and logged", !exists(onlyHeld.file(".work-held.a4")) && onlyHeld.kinds == ["end"], "\(onlyHeld.kinds)")
}

// MARK: The /work script: two commands

/// The first command's last line, which is the second command, run as the agent would run it.
func lines(_ ran: Ran) -> [String] { ran.out.split(whereSeparator: \.isNewline).map(String.init) }

func work(_ shell: String, _ arguments: [String], _ pane: Pane?, in directory: URL = repo) -> Ran {
    run(shell, [skill.path] + arguments, env: pane?.env ?? [:], cwd: directory)
}

for shell in shells where URL(fileURLWithPath: shell).lastPathComponent != "zsh" {
    // zsh is a hook shell (above); the script is run as `sh <script>`, so the shells tried here are the ones that can be `sh`.
    let tag = "[\(shell) work.sh] "

    // Outside a Varnick pane the first command already knows.
    var ran = work(shell, ["option", "p/01"], nil)
    expect(tag + "outside a pane: fails", ran.status != 0, "\(ran.status) \(ran.out)")
    expect(tag + "outside a pane: says no record is written", ran.out.contains("no record is written"), ran.out)
    expect(tag + "outside a pane: no 'Linked to'", !ran.out.contains("Linked to"), ran.out)
    ran = work(shell, ["confirm", "aa11", "option", "p/01"], nil)
    expect(tag + "confirm outside a pane: fails", ran.status != 0, "\(ran.status) \(ran.out)")

    // The first command, in a pane: a marker and the second command, and no claim of a link.
    var pane = freshPane()
    ran = work(shell, ["option", "p/01"], pane)
    var out = lines(ran)
    expect(tag + "first: exits 0", ran.status == 0, "\(ran.status) \(ran.out)")
    expect(tag + "first: does not say Linked", !ran.out.contains("Linked to"), ran.out)
    expect(tag + "first: prints one marker", out.filter { $0.hasPrefix("VARNICK-WORK|") }.count == 1, ran.out)
    expect(tag + "first: the last line is the second command", out.last?.contains(" confirm ") == true && out.last?.contains("option p/01") == true, ran.out)
    let nonce = out.first { $0.hasPrefix("VARNICK-WORK|") }.map { String($0.split(separator: "|")[2]) } ?? "?"
    expect(tag + "first: leaves the nonce's file", exists(pane.file(".work-mark.\(nonce)")))
    expect(tag + "first: the nonce is in the second command", out.last?.contains(nonce) == true, ran.out)
    let second = out.last ?? "false"

    // The second command with no hook having taken the marker: it fails, names the cause, and removes the file.
    let failed = run("/bin/sh", ["-c", second], env: pane.env, cwd: repo)
    expect(tag + "confirm without a hook: exits non-zero", failed.status != 0, "\(failed.status) \(failed.out)")
    expect(tag + "confirm without a hook: names the cause and the remedy", failed.out.contains("work hooks") && failed.out.contains("Restart"), failed.out)
    expect(tag + "confirm without a hook: does not say Linked", !failed.out.contains("Linked to"), failed.out)
    expect(tag + "confirm without a hook: removes the file, so a replay links nothing", !exists(pane.file(".work-mark.\(nonce)")))
    let replay = run("/bin/sh", ["-c", second], env: pane.env, cwd: repo)
    expect(tag + "confirm again: still fails", replay.status != 0 && !replay.out.contains("Linked to"), replay.out)

    // The hook takes the marker: the second command succeeds.
    pane = freshPane()
    ran = work(shell, ["option", "p/01"], pane)
    _ = hook(WorkHooks.mark, "/bin/sh", pane, bashCall(ran.out, agent: "a1"))
    let confirmed = run("/bin/sh", ["-c", lines(ran).last ?? "false"], env: pane.env, cwd: repo)
    expect(tag + "confirm after the hook: exits 0", confirmed.status == 0, "\(confirmed.status) \(confirmed.out)")
    expect(tag + "confirm after the hook: says Linked to the option", confirmed.out.contains("Linked to option p/01"), confirmed.out)
    expect(tag + "confirm after the hook: the record is there", text(pane.file("work.a1"))?.hasPrefix("option p/01\n") == true)

    // A problem and a clear go the same way.
    for (arguments, linked) in [(["problem", "p"], "Linked to problem p"), (["none"], "Work link cleared")] {
        pane = freshPane()
        ran = work(shell, arguments, pane)
        expect(tag + "\(arguments[0]): first exits 0 and claims nothing", ran.status == 0 && !ran.out.contains("Linked to") && !ran.out.contains("cleared"), ran.out)
        _ = hook(WorkHooks.mark, "/bin/sh", pane, bashCall(ran.out))
        let done = run("/bin/sh", ["-c", lines(ran).last ?? "false"], env: pane.env, cwd: repo)
        expect(tag + "\(arguments[0]): confirm after the hook", done.status == 0 && done.out.contains(linked), "\(done.status) \(done.out)")
        pane = freshPane()
        ran = work(shell, arguments, pane)
        let none = run("/bin/sh", ["-c", lines(ran).last ?? "false"], env: pane.env, cwd: repo)
        expect(tag + "\(arguments[0]): confirm without a hook fails", none.status != 0 && !none.out.contains(linked), none.out)
    }

    // The nonce's file gone but no record names the link: the hook took the marker and wrote nothing, or someone deleted the file.
    pane = freshPane()
    ran = work(shell, ["option", "p/01"], pane)
    let spentNonce = String(lines(ran).first { $0.hasPrefix("VARNICK-WORK|") }!.split(separator: "|")[2])
    try? fm.removeItem(at: pane.file(".work-mark.\(spentNonce)"))
    let unrecorded = run("/bin/sh", ["-c", lines(ran).last ?? "false"], env: pane.env, cwd: repo)
    expect(tag + "confirm with the file gone and no record: fails", unrecorded.status != 0 && !unrecorded.out.contains("Linked to"), unrecorded.out)

    // Arguments the second command refuses.
    pane = freshPane()
    for bad in [["confirm"], ["confirm", "../x", "option", "p/01"], ["confirm", "aa11"], ["confirm", "aa11", "bogus", "p"], ["confirm", "", "none"]] {
        ran = work(shell, bad, pane)
        expect(tag + "confirm \(bad): refused", ran.status != 0 && !ran.out.contains("Linked to"), "\(ran.status) \(ran.out)")
    }

    // The first command's own refusals stand.
    expect(tag + "unknown problem fails", work(shell, ["option", "nope/01"], freshPane()).status != 0)
    expect(tag + "unknown option fails", work(shell, ["option", "p/07"], freshPane()).status != 0)

    // On a branch other than main the tie is made and the failure says so.
    git(["symbolic-ref", "HEAD", "refs/heads/feat"])
    pane = freshPane()
    ran = work(shell, ["option", "p/01"], pane)
    expect(tag + "branch: the first command ties it", ran.out.contains("branch feat tied"), ran.out)
    let tiedFailure = run("/bin/sh", ["-c", lines(ran).last ?? "false"], env: pane.env, cwd: repo)
    expect(tag + "branch: a failed confirm says the branch is tied anyway", tiedFailure.status != 0 && tiedFailure.out.contains("branch feat is tied"), tiedFailure.out)
    git(["symbolic-ref", "HEAD", "refs/heads/main"])
    git(["config", "--remove-section", "branch.feat"])
}

print("check-work: \(cases) cases, \(failures) failed")
exit(failures == 0 ? 0 : 1)
