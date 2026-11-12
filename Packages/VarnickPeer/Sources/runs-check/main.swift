import Foundation
import VarnickPeer

// `make check-runs`: the runs file (`TaskRunFile`, `TaskRunList`, `RunState`; Packages/VarnickPeer) over a table of cases, with no Varnick, no clock, no
// model and no network. An automation's Run is the record the file holds, and a Run an earlier build's Tasks wrote is still read and written back
// unchanged. Neither Varnick nor this package has a test target; this is how `check-slots` checks the slot function. One `error:` line a failed case,
// exit 1 if there was any.

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-runs: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

let clock = Date(timeIntervalSince1970: 1_792_000_000)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("runs-check-\(getpid())", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scratch) }

// MARK: The runs file

let automation = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
let panes = (UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
let slot = Date(timeIntervalSince1970: 1_792_000_000)
let launch = RunLaunch(folder: "/work/x", agent: "reviewer", skipPermissions: false, dontAsk: true, allowedTools: ["Bash(git status)", "Edit"])
let going = TaskRun(id: panes.0, task: "Claude prompt", input: ["prompt": .text("Say hello"), "folder": .text("/work/x")],
                    trigger: TaskRunTrigger(automation: automation, slot: slot, late: true, manual: false), state: .running, startedAt: slot,
                    steps: [TaskRunStep(name: "claude", capability: "claude", pane: panes.0, conversation: "moved", launch: launch, worked: 90)])
let message = TaskRun(id: panes.1, task: "Claude prompt", input: ["prompt": .text("Say hello")],
                      trigger: TaskRunTrigger(automation: automation, slot: slot.addingTimeInterval(900), manual: true), state: .message, detail: "Found 3",
                      startedAt: slot.addingTimeInterval(900), endedAt: slot.addingTimeInterval(1200), opened: true,
                      steps: [TaskRunStep(name: "claude", capability: "claude", pane: panes.1)])
var skipped = TaskRun(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, task: "Claude prompt", input: ["prompt": .text("Say hello")],
                      trigger: TaskRunTrigger(automation: automation, slot: slot.addingTimeInterval(1800)), state: .skipped, detail: "The last run was still going")
skipped.count = 3
let written = String(decoding: (try? TaskRunFile.encoded([going, message, skipped])) ?? Data(), as: UTF8.self)
expect("an automation's Run is written byte for byte as slice 1 wrote it (the file's version apart)",
       written.replacingOccurrences(of: "\"version\" : 2", with: "\"version\" : 1") == sliceOneRuns + "\n", "got:\n\(written)")
expect("the runs file is at version 2", written.contains("\"version\" : 2") && TaskRunFile.currentVersion == 2)

let folder = scratch.appendingPathComponent("files", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let file = TaskRunFile.url(in: folder)
try? Data((sliceOneRuns + "\n").utf8).write(to: file)
if case .loaded(let runs) = TaskRunFile.read(at: file) {
    expect("a version 1 file reads", runs == [going, message, skipped], "\(runs.count) runs")
} else {
    expect("a version 1 file reads", false, "\(TaskRunFile.read(at: file))")
}
try? Data(written.utf8).write(to: file)
expect("a version 2 file reads the same Runs", TaskRunFile.read(at: file) == .loaded([going, message, skipped]))
try? Data("{\"version\": 3, \"runs\": []}".utf8).write(to: file)
expect("a version 3 file is read as newer and never written over", TaskRunFile.read(at: file) == .newer(3) && TaskRunFile.read(at: file).problem != nil)
try? Data("not json".utf8).write(to: file)
if case .unreadable = TaskRunFile.read(at: file) {} else { expect("an unreadable file stays unreadable", false) }

// A Run a Task wrote (no automation, a copy of the Task, steps with states and results) is no longer shown or run, but the file still reads it and
// writes it back as it was, so an earlier build's file isn't lost.
let taskText = #"""
{"version": 2, "runs": [{"id": "55555555-5555-5555-5555-555555555555", "task": "Haiku", "input": {"topic": "x"}, "opened": false, "state": "failed", "detail": "Failed at check: no",
  "startedAt": "2026-10-14T17:46:40Z", "endedAt": "2026-10-14T17:47:40Z", "result": {"text": "hi"}, "definition": {"name": "Haiku", "start": "write"}, "depth": 1, "awake": 12,
  "steps": [{"name": "write", "capability": "claude", "state": "done", "outcome": "ok", "actor": "Claude", "probability": 0.5, "result": {"text": "hi"}, "child": "66666666-6666-6666-6666-666666666666"}],
  "trigger": {"slot": "2026-10-14T17:46:40Z", "late": false, "manual": false, "origin": "session", "session": "Planning", "parent": "77777777-7777-7777-7777-777777777777", "parentStep": "sub"}}]}
"""#
try? Data(taskText.utf8).write(to: file)
if case .loaded(let runs) = TaskRunFile.read(at: file), runs.count == 1 {
    let own = runs[0]
    expect("a Task's own Run reads, with its copy of the Task, its steps and who started it",
           own.task == "Haiku" && own.state == .failed && own.trigger.automation == nil && own.trigger.session == "Planning" && own.definition != nil
           && own.steps[0].actor == "Claude" && own.steps[0].child != nil && own.result == .object(["text": .text("hi")]))
    do {
        try TaskRunFile.write([own], to: TaskRunFile.url(in: folder))
        expect("and writes back the same Run", TaskRunFile.read(at: TaskRunFile.url(in: folder)) == .loaded([own]))
    } catch {
        expect("the Run can be written", false, "\(error)")
    }
} else {
    expect("a Task's own Run reads", false, "\(TaskRunFile.read(at: file))")
}

// MARK: The list

var list = TaskRunList()
func owned(_ task: String, going: Bool = false) -> TaskRun {
    TaskRun(task: task, trigger: TaskRunTrigger(automation: nil, slot: clock), state: going ? .running : .done, startedAt: clock, endedAt: going ? nil : clock)
}
let running = owned("Haiku", going: true)
list.record(running)
for _ in 0..<25 { list.record(owned("Haiku")) }
list.record(owned("Other"))
expect("each Task keeps its last 20 of the Runs no automation started, and a Run still going is never dropped",
       list.runs.filter { $0.task == "Haiku" }.count == 20 && list.runs.contains { $0.id == running.id } && list.runs.filter { $0.task == "Other" }.count == 1)
list.record(going)
expect("an automation's Runs are not counted with them", list.runs(of: automation).count == 1 && list.runs.filter { $0.task == "Haiku" }.count == 20)

// A state a newer build wrote is read as done, and the states are words.
expect("the states are words", RunState.failed.text == "Failed" && RunState.stopped.text == "Stopped" && !RunState.failed.isGoing && RunState.failed.ran)
expect("a state this build doesn't know is read as done", (try? JSONDecoder().decode(RunState.self, from: Data("\"nonsense\"".utf8))) == .done)

if failures > 0 {
    FileHandle.standardError.write(Data("error: check-runs: \(failures) of \(cases) checks failed\n".utf8))
    exit(1)
}
print("check-runs: \(cases) checks passed")
