import Foundation
import VarnickPeer

// `make check-slots`: the slot function (`AutomationSlot`) over a table of cases, with no Varnick, no clock and no files. Neither Varnick nor
// this package has a test target; this is how `check-mcp` checks the MCP server. One `error:` line a failed case, exit 1 if there was any.

let utc = TimeZone(identifier: "UTC")!
let pacific = TimeZone(identifier: "America/Los_Angeles")!
let tokyo = TimeZone(identifier: "Asia/Tokyo")!
let kolkata = TimeZone(identifier: "Asia/Kolkata")!

/// A wall-clock time ("2026-10-15 09:00" or with seconds) in a zone.
func at(_ text: String, _ zone: TimeZone = utc) -> Date {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = text.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
    guard let date = formatter.date(from: text) else { fatalError("bad date in the table: \(text)") }
    return date
}

func show(_ date: Date?, _ zone: TimeZone = utc) -> String {
    guard let date else { return "none" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = zone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
    return formatter.string(from: date)
}

var failures = 0
var cases = 0

func expect(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    cases += 1
    guard !ok else { return }
    failures += 1
    FileHandle.standardError.write(Data("error: check-slots: \(name)\(detail().isEmpty ? "" : ": " + detail())\n".utf8))
}

/// The check at `now` after `last`: the due slot and the missed ones.
func run(_ cadence: AutomationCadence, _ zone: TimeZone, last: Date, now: Date) -> AutomationSlot.Check {
    AutomationSlot.check(cadence, zone: zone, after: last, now: now)
}

func due(_ name: String, _ cadence: AutomationCadence, _ zone: TimeZone, last: Date, now: Date, is expected: Date?) {
    let got = run(cadence, zone, last: last, now: now)
    expect(name, got.due == expected, "due \(show(got.due, zone)), wanted \(show(expected, zone))")
}

// MARK: Every preset

// Every 15 and 30 minutes: slots on the quarter and the half hour of the zone's clock.
due("every 15 minutes, a minute before the slot", .minutes(15), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:14:59"), is: nil)
due("every 15 minutes, a slot exactly at the check's minute", .minutes(15), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:15:00"),
    is: at("2026-10-15 09:15"))
due("every 15 minutes, a minute late", .minutes(15), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:16:00"), is: at("2026-10-15 09:15"))
due("every 30 minutes skips the quarter", .minutes(30), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:29:59"), is: nil)
due("every 30 minutes", .minutes(30), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:30:20"), is: at("2026-10-15 09:30"))

// Every n hours from midnight of the zone.
for step in AutomationCadence.hourSteps {
    var expected: Date?
    // From 00:00 the next slot is at `step` o'clock, and a check one minute before it finds nothing.
    expected = at(String(format: "2026-10-15 %02d:00", step % 24))
    let now = step == 24 ? at("2026-10-16 00:00") : expected!
    due("every \(step) hours, the first slot of the day", .hours(step), utc, last: at("2026-10-15 00:00"), now: now.addingTimeInterval(20), is: expected)
    due("every \(step) hours, a minute before it", .hours(step), utc, last: at("2026-10-15 00:00"), now: now.addingTimeInterval(-60), is: nil)
}
due("every 4 hours is on the zone's clock", .hours(4), pacific, last: at("2026-10-15 00:00", pacific), now: at("2026-10-15 04:00:10", pacific),
    is: at("2026-10-15 04:00", pacific))

// Daily, weekdays and weekly at a time.
due("daily, just after", .daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 09:00:20"), is: at("2026-10-15 09:00"))
due("daily, an hour before", .daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 08:00"), is: nil)
// 2026-10-16 is a Friday.
due("weekdays on a Friday", .weekdays(hour: 9, minute: 0), utc, last: at("2026-10-15 09:00"), now: at("2026-10-16 09:00:05"), is: at("2026-10-16 09:00"))
due("weekdays: Saturday has no slot", .weekdays(hour: 9, minute: 0), utc, last: at("2026-10-16 09:00"), now: at("2026-10-17 12:00"), is: nil)
due("weekdays: Sunday has no slot", .weekdays(hour: 9, minute: 0), utc, last: at("2026-10-16 09:00"), now: at("2026-10-18 12:00"), is: nil)
due("weekdays: Monday", .weekdays(hour: 9, minute: 0), utc, last: at("2026-10-16 09:00"), now: at("2026-10-19 09:00:30"), is: at("2026-10-19 09:00"))
// 2026-10-14 is a Wednesday (weekday 4).
due("weekly on its day", .weekly(weekday: 4, hour: 9, minute: 30), utc, last: at("2026-10-07 09:30"), now: at("2026-10-14 09:30:30"),
    is: at("2026-10-14 09:30"))
due("weekly the day before", .weekly(weekday: 4, hour: 9, minute: 30), utc, last: at("2026-10-07 09:30"), now: at("2026-10-13 12:00"), is: nil)
due("weekly the day after is the same slot, late", .weekly(weekday: 4, hour: 9, minute: 30), utc, last: at("2026-10-07 09:30"),
    now: at("2026-10-14 18:00"), is: at("2026-10-14 09:30"))

// MARK: The zone is the automation's, not the host's

// Daily at 9:00 in Tokyo is 00:00 UTC; the same wall time in Los Angeles is 16:00 UTC (PDT in October).
due("daily 9:00 in Tokyo", .daily(hour: 9, minute: 0), tokyo, last: at("2026-10-14 00:00"), now: at("2026-10-15 00:00:30"), is: at("2026-10-15 00:00"))
due("daily 9:00 in Tokyo, not at 9:00 UTC", .daily(hour: 9, minute: 0), tokyo, last: at("2026-10-14 00:00"), now: at("2026-10-14 09:00:30"), is: nil)
due("daily 9:00 in Los Angeles", .daily(hour: 9, minute: 0), pacific, last: at("2026-10-14 16:00"), now: at("2026-10-15 16:00:30"),
    is: at("2026-10-15 16:00"))
due("a half-hour zone", .daily(hour: 9, minute: 0), kolkata, last: at("2026-10-14 03:30"), now: at("2026-10-15 03:30:30"), is: at("2026-10-15 03:30"))
due("weekly in Tokyo: Wednesday there is Tuesday evening in UTC", .weekly(weekday: 4, hour: 5, minute: 0), tokyo,
    last: at("2026-10-07 05:00", tokyo), now: at("2026-10-13 20:00:30"), is: at("2026-10-14 05:00", tokyo))

// MARK: Daylight saving

// 2026-03-08: Los Angeles skips 02:00 to 03:00. 2026-11-01: it repeats 01:00.
let beforeSpring = at("2026-03-07 09:00", pacific), afterSpring = at("2026-03-08 09:00", pacific)
expect("a day of spring-forward is 23 hours between two 9:00 slots", afterSpring.timeIntervalSince(beforeSpring) == 23 * 3600)
due("daily 9:00 across spring forward keeps the wall clock", .daily(hour: 9, minute: 0), pacific, last: beforeSpring,
    now: at("2026-03-08 09:00:30", pacific), is: afterSpring)
due("daily 2:30 on the day 2:30 does not exist moves to 3:00", .daily(hour: 2, minute: 30), pacific, last: at("2026-03-07 02:30", pacific),
    now: at("2026-03-08 03:05", pacific), is: at("2026-03-08 03:00", pacific))
let springDay = AutomationSlot.slots(.hours(2), zone: pacific, after: at("2026-03-07 23:00", pacific), through: at("2026-03-08 23:30", pacific), limit: 100)
expect("every 2 hours on spring forward leaves out the hour that does not exist", springDay.count == 11, "\(springDay.count) slots")
let springHourly = AutomationSlot.slots(.hours(1), zone: pacific, after: at("2026-03-07 23:00", pacific), through: at("2026-03-08 23:30", pacific), limit: 100)
expect("every hour on spring forward has 23 slots", springHourly.count == 23, "\(springHourly.count) slots")
let fallHourly = AutomationSlot.slots(.hours(1), zone: pacific, after: at("2026-10-31 23:00", pacific), through: at("2026-11-01 23:30", pacific), limit: 100)
expect("every hour on fall back runs the repeated hour once", fallHourly.count == 24, "\(fallHourly.count) slots")
let repeated = AutomationSlot.slots(.daily(hour: 1, minute: 30), zone: pacific, after: at("2026-10-31 12:00", pacific),
                                    through: at("2026-11-01 12:00", pacific), limit: 10)
expect("daily 1:30 on fall back is the first 1:30", repeated == [Date(timeIntervalSince1970: at("2026-11-01 08:30").timeIntervalSince1970)],
       repeated.map { show($0, utc) }.joined(separator: ", "))
due("daily 9:00 across fall back keeps the wall clock", .daily(hour: 9, minute: 0), pacific, last: at("2026-10-31 09:00", pacific),
    now: at("2026-11-01 09:00:30", pacific), is: at("2026-11-01 09:00", pacific))
expect("fall back day is 25 hours between two 9:00 slots",
       at("2026-11-02 09:00", pacific).timeIntervalSince(at("2026-11-01 09:00", pacific)) == 24 * 3600 && at("2026-11-01 09:00", pacific).timeIntervalSince(at("2026-10-31 09:00", pacific)) == 25 * 3600)

// MARK: Catching up

due("a slot 11 hours 59 minutes old still runs", .daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 20:59"),
    is: at("2026-10-15 09:00"))
due("a slot exactly 12 hours old does not", .daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 21:00"), is: nil)
let stale = run(.daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 22:00"))
expect("a slot over 12 hours old is recorded missed", stale.due == nil && stale.missed == [at("2026-10-15 09:00")], "\(stale)")
let weekend = run(.weekdays(hour: 9, minute: 0), utc, last: at("2026-10-16 09:00"), now: at("2026-10-19 08:00"))
expect("a weekend away gives Friday's run nothing on Monday", weekend.due == nil && weekend.missed.isEmpty, "\(weekend)")

// Many missed slots give one due slot, the newest, and the rest missed, newest first and capped.
let days = run(.minutes(15), utc, last: at("2026-10-12 09:00"), now: at("2026-10-15 09:07"))
expect("three days of 15-minute slots give the newest as due", days.due == at("2026-10-15 09:00"), show(days.due))
expect("and twenty missed, newest first", days.missed.count == AutomationSlot.missedLimit && days.missed.first == at("2026-10-15 08:45")
       && zip(days.missed, days.missed.dropFirst()).allSatisfy { $0.0 > $0.1 }, "\(days.missed.count) missed")
expect("none of them is the due slot", !days.missed.contains(at("2026-10-15 09:00")))
let few = run(.minutes(15), utc, last: at("2026-10-15 08:00"), now: at("2026-10-15 09:07"))
expect("a short gap lists the missed slots between", few.due == at("2026-10-15 09:00")
       && few.missed == [at("2026-10-15 08:45"), at("2026-10-15 08:30"), at("2026-10-15 08:15")], "\(few)")
// A slot equal to the last one is already fired for.
due("the slot last fired for is not due again", .minutes(15), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:00:40"), is: nil)
// A catch-up of a late slot says it was late; a normal run does not.
expect("a normal run is not late", !run(.daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 09:00:30")).late)
expect("a run at the slot's own minute is not late", !run(.daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 09:00")).late)
expect("a run after the Mac slept is late", run(.daily(hour: 9, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-15 09:40")).late)
expect("no slot is not late", !run(.daily(hour: 9, minute: 0), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 09:40")).late)

// MARK: Not valid, next, Codable

due("a cadence outside the presets never fires", .minutes(7), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 12:00"), is: nil)
due("neither does five minutes, below the floor", .minutes(5), utc, last: at("2026-10-15 09:00"), now: at("2026-10-15 12:00"), is: nil)
due("a time that is not a time", .daily(hour: 25, minute: 0), utc, last: at("2026-10-14 09:00"), now: at("2026-10-16 12:00"), is: nil)
expect("the shortest gap is 15 minutes", AutomationCadence.minuteSteps.min() == 15 && AutomationCadence.shortest == 900)

func nextSlot(_ cadence: AutomationCadence, _ zone: TimeZone, after: Date, is expected: Date?, _ name: String) {
    let got = AutomationSlot.next(cadence, zone: zone, after: after)
    expect("next: " + name, got == expected, "\(show(got, zone)), wanted \(show(expected, zone))")
}
nextSlot(.minutes(15), utc, after: at("2026-10-15 09:07"), is: at("2026-10-15 09:15"), "15 minutes")
nextSlot(.minutes(15), utc, after: at("2026-10-15 09:15"), is: at("2026-10-15 09:30"), "a slot is not after itself")
nextSlot(.hours(12), utc, after: at("2026-10-15 13:00"), is: at("2026-10-16 00:00"), "12 hours rolls to midnight")
nextSlot(.weekdays(hour: 9, minute: 0), utc, after: at("2026-10-16 10:00"), is: at("2026-10-19 09:00"), "weekdays skips the weekend")
nextSlot(.weekly(weekday: 4, hour: 9, minute: 0), utc, after: at("2026-10-14 09:00"), is: at("2026-10-21 09:00"), "weekly is a week on")
nextSlot(.minutes(9), utc, after: at("2026-10-15 09:00"), is: nil, "an invalid cadence has none")

let presets: [AutomationCadence] = AutomationCadence.minuteSteps.map { .minutes($0) } + AutomationCadence.hourSteps.map { .hours($0) }
    + [.daily(hour: 9, minute: 5), .weekdays(hour: 23, minute: 59), .weekly(weekday: 1, hour: 0, minute: 0), .weekly(weekday: 7, hour: 12, minute: 30)]
for cadence in presets {
    expect("\(cadence.label) is valid", cadence.isValid)
    let data = try JSONEncoder().encode(cadence)
    let back = try? JSONDecoder().decode(AutomationCadence.self, from: data)
    expect("\(cadence.label) survives its file", back == cadence, String(decoding: data, as: UTF8.self))
}

// MARK: The command line of a run

func arguments(skip: Bool = false, dontAsk: Bool = false, tools: [String] = []) -> [String] {
    ClaudeCommand.arguments(skipPermissions: skip, agent: "reviewer", resuming: nil, sessionID: "11111111-2222-4333-8444-555555555555",
                            prompt: "Say hello", problems: false, mcpConfig: "{}", dontAsk: dontAsk, allowedTools: tools)
}
func allowed(_ arguments: [String]) -> [String] {
    guard let at = arguments.firstIndex(of: "--settings"), let data = arguments[at + 1].data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let permissions = json["permissions"] as? [String: Any] else { return [] }
    return permissions["allow"] as? [String] ?? []
}
let plain = arguments()
expect("a pane with no override has neither flag", !plain.contains("--permission-mode") && !plain.contains("--dangerously-skip-permissions"), "\(plain.prefix(4))")
expect("a plain pane allows notify alone", allowed(plain) == [NotifyTool.qualifiedName], "\(allowed(plain))")
let strict = arguments(dontAsk: true, tools: ["Bash(git status)", "Edit"])
expect("Allowed tools only is --permission-mode dontAsk, before the agent and the prompt",
       strict.firstIndex(of: "--permission-mode").map { strict[$0 + 1] == "dontAsk" && $0 < strict.firstIndex(of: "--agent")! && $0 < strict.firstIndex(of: "--")! } == true,
       "\(strict)")
expect("the allowed tools join notify's allowance", allowed(strict) == [NotifyTool.qualifiedName, "Bash(git status)", "Edit"], "\(allowed(strict))")
expect("skip never goes with dontAsk", !arguments(skip: true, dontAsk: true).contains("--permission-mode"))
expect("skip is the existing flag", arguments(skip: true).contains("--dangerously-skip-permissions"))
expect("the prompt stays the last operand after --", strict.suffix(2) == ["--", "Say hello"], "\(strict.suffix(2))")

// MARK: The file

// A throwaway folder: nothing here touches the support folder.
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-\(getpid())", isDirectory: true)
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let file = AutomationFile.url(in: folder)
expect("no file reads as missing, which is not a problem", AutomationFile.read(at: file) == .missing && AutomationFile.read(at: file).problem == nil)
var sample = Automation(name: "Morning summary", prompt: "Say hello", folder: "/work/x", agent: "reviewer", cadence: .weekdays(hour: 9, minute: 0),
                        timeZone: "America/Los_Angeles", permissions: .allowedOnly, allowedTools: ["Bash(git status)", "Edit"], createdAt: at("2026-10-15 09:00"))
sample.lastSlot = at("2026-10-15 16:00")
expect("an automation names the Claude prompt Task, with its prompt, folder and agent as the input",
       sample.task == "Claude prompt" && sample.input == ["prompt": .text("Say hello"), "folder": .text("/work/x"), "agent": .text("reviewer")], "\(sample.input)")
sample.folder = nil
sample.agent = nil
expect("a folder or an agent set to nil leaves the input", sample.input == ["prompt": .text("Say hello")] && sample.folder == nil && sample.agent == nil)
sample.folder = "/work/x"

/// A Claude prompt Run of an automation, as a start records it: its pane's id is its own.
func claudeRun(_ automation: UUID, slot: Date, state: RunState, ended: Bool = false, manual: Bool = false, detail: String? = nil) -> TaskRun {
    let pane = UUID()
    return TaskRun(id: pane, trigger: TaskRunTrigger(automation: automation, slot: slot, manual: manual), state: state, detail: detail, startedAt: slot,
                   endedAt: ended ? slot : nil, steps: [TaskRunStep(name: "claude", capability: "claude", pane: pane)])
}
/// A slot that did not run: no steps, a fresh id.
func notRun(_ automation: UUID, slot: Date, _ state: RunState, _ detail: String) -> TaskRun {
    TaskRun(trigger: TaskRunTrigger(automation: automation, slot: slot), state: state, detail: detail)
}

var list = TaskRunList()
for index in 0..<(TaskRunList.limit + 5) {
    list.record(claudeRun(sample.id, slot: at("2026-10-15 16:00").addingTimeInterval(Double(index) * 60), state: .done, ended: true))
}
let shown = list.runs(of: sample.id)
expect("a run list keeps twenty, newest first", shown.count == 20 && shown.first!.trigger.slot > shown.last!.trigger.slot, "\(shown.count)")
let other = Automation(name: "Other", prompt: "x", cadence: .minutes(15), createdAt: at("2026-10-15 09:00"))
list.record(claudeRun(other.id, slot: at("2026-10-15 18:00"), state: .done, ended: true))
expect("each automation keeps its own twenty", list.runs(of: sample.id).count == 20 && list.runs(of: other.id).count == 1)

// A run that may still have a pane is never the one dropped, and slots that did not run fold.
var goingList = TaskRunList()
let oldest = claudeRun(other.id, slot: at("2026-10-15 09:00"), state: .running)
goingList.record(oldest)
for index in 1...30 {
    goingList.record(claudeRun(other.id, slot: at("2026-10-15 09:00").addingTimeInterval(Double(index) * 900), state: .done, ended: true))
}
expect("a run still going outlives twenty newer ones", goingList.runs(of: other.id).count == 20 && goingList.runs.contains { $0.id == oldest.id },
       "\(goingList.runs.count) runs")
var flood = TaskRunList()
for index in 0..<40 {
    flood.record(notRun(other.id, slot: at("2026-10-15 09:00").addingTimeInterval(Double(index) * 900), .skipped, "The last run was still going"))
}
expect("40 skipped slots are one record that counts them", flood.runs.count == 1 && flood.runs[0].count == 40
       && flood.runs[0].trigger.slot == at("2026-10-15 09:00").addingTimeInterval(39 * 900), "\(flood.runs.count) records")
flood.record(notRun(other.id, slot: at("2026-10-16 09:00"), .missed, "Over 12 hours old at the next check"))
flood.record(notRun(other.id, slot: at("2026-10-16 09:15"), .skipped, "The last run was still going"))
expect("a different state or reason is another record", flood.runs.count == 3, "\(flood.runs.count) records")
flood.record(claudeRun(other.id, slot: at("2026-10-16 09:30"), state: .running))
flood.record(notRun(other.id, slot: at("2026-10-16 09:45"), .skipped, "The last run was still going"))
expect("a run between two skipped slots splits them", flood.runs.count == 5, "\(flood.runs.count) records")
var foldedTwice = TaskRunList()
foldedTwice.record(notRun(sample.id, slot: at("2026-10-16 09:00"), .skipped, "The last run was still going"))
foldedTwice.record(notRun(other.id, slot: at("2026-10-16 09:00"), .skipped, "The last run was still going"))
foldedTwice.record(notRun(sample.id, slot: at("2026-10-16 09:15"), .skipped, "The last run was still going"))
expect("slots of one automation fold across another's records", foldedTwice.runs.count == 2 && foldedTwice.runs(of: sample.id).first?.count == 2)

// A run's pane and conversation are found through its step.
var stepped = claudeRun(sample.id, slot: at("2026-10-15 16:00"), state: .running)
expect("a Claude prompt Run's pane is its own id and its step's", stepped.pane == stepped.id && stepped.steps.count == 1)
expect("its conversation is the pane's id until the pane moves", stepped.conversationID == stepped.id.uuidString.lowercased())
stepped.conversation = "moved-conversation"
stepped.worked = 90
expect("a moved conversation and the time worked live on the step", stepped.steps[0].conversation == "moved-conversation" && stepped.conversationID == "moved-conversation"
       && stepped.steps[0].worked == 90 && stepped.worked == 90)
var twoPanes = stepped
twoPanes.steps.append(TaskRunStep(name: "again", capability: "claude", pane: UUID(), conversation: "second-conversation"))
expect("a conversation of any step finds its step", twoPanes.step(conversation: "second-conversation")?.name == "again"
       && twoPanes.step(conversation: "moved-conversation")?.name == "claude" && twoPanes.step(conversation: "none") == nil)
let skippedRun = notRun(sample.id, slot: at("2026-10-15 16:00"), .skipped, "x")
expect("a slot that did not run has no step, pane or conversation", skippedRun.steps.isEmpty && skippedRun.pane == nil && skippedRun.conversationID == nil)

// The anchor: a Run newer than the last slot (a crash between the two writes) is judged from, and a Run now is not a slot.
var anchored = TaskRunList()
var behind = sample
behind.lastSlot = at("2026-10-15 09:00")
anchored.record(claudeRun(behind.id, slot: at("2026-10-15 09:15"), state: .running))
expect("the anchor is the newer of the last slot and the newest Run's slot", anchored.anchor(for: behind) == at("2026-10-15 09:15"), show(anchored.anchor(for: behind)))
expect("so a slot a Run was written for is not due again", AutomationSlot.check(.minutes(15), zone: utc, after: anchored.anchor(for: behind), now: at("2026-10-15 09:15:30")).due == nil
       && AutomationSlot.check(.minutes(15), zone: utc, after: behind.anchor, now: at("2026-10-15 09:15:30")).due == at("2026-10-15 09:15"))
expect("nor recorded missed again", AutomationSlot.check(.minutes(15), zone: utc, after: anchored.anchor(for: behind), now: at("2026-10-15 09:40")).missed.isEmpty
       && AutomationSlot.check(.minutes(15), zone: utc, after: behind.anchor, now: at("2026-10-15 09:40")).missed == [at("2026-10-15 09:15")])
anchored.record(claudeRun(behind.id, slot: at("2026-10-15 09:20"), state: .running, manual: true))
expect("a Run now is not a slot of the clock", anchored.anchor(for: behind) == at("2026-10-15 09:15"), show(anchored.anchor(for: behind)))
expect("an older Run leaves the last slot as it is", TaskRunList().anchor(for: sample) == sample.anchor && anchored.anchor(for: sample) == sample.anchor)

// The automations file is at version 2.
do {
    try AutomationFile.write([sample], to: file)
    let back = AutomationFile.read(at: file)
    expect("an automation survives its file", back == .loaded([sample]), "\(back)")
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
    expect("the file is owner-only", mode == 0o600, String(mode, radix: 8))
    let version = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any])?["version"] as? Int
    expect("it is written as version 2", version == 2, "\(version ?? 0)")
    let written = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
    expect("an automation in it has no runs and names its Task", !written.contains("\"runs\"") && written.contains("\"task\" : \"Claude prompt\""))
} catch {
    expect("the file can be written", false, "\(error)")
}
try? Data("{\"version\": 3, \"automations\": []}".utf8).write(to: file)
expect("a version 3 file is read as newer and never written over", AutomationFile.read(at: file) == .newer(3) && AutomationFile.read(at: file).problem != nil)
try? Data("not json".utf8).write(to: file)
if case .unreadable = AutomationFile.read(at: file) {} else { expect("garbage is unreadable", false) }
try? Data("{\"version\": 2, \"automations\": [{\"name\": 3}]}".utf8).write(to: file)
if case .unreadable = AutomationFile.read(at: file) {} else { expect("a record that doesn't decode is unreadable", false) }
expect("an unreadable file fires nothing", AutomationFile.read(at: file).automations.isEmpty)

// Version 1: a prompt, a folder, an agent and the runs. Read as Claude prompt triggers, the runs not carried over, and read without a write.
let versionOne = """
{"version": 1, "automations": [{"id": "5E1A6C0E-4A0B-4F43-9A0B-6B8A0C2D9E01", "name": "Old", "prompt": "Say hello", "folder": "/work/x", "agent": "reviewer",
 "cadence": {"kind": "daily", "hour": 9, "minute": 0}, "timeZone": "UTC", "permissions": "ask", "allowedTools": ["Edit"], "workingLimitMinutes": 30,
 "enabled": true, "lastSlot": "2026-10-14T09:00:00Z", "createdAt": "2026-10-01T09:00:00Z",
 "runs": [{"id": "6E1A6C0E-4A0B-4F43-9A0B-6B8A0C2D9E02", "slot": "2026-10-14T09:00:00Z", "late": false, "manual": false, "state": "done", "opened": false}],
 "mark": {"what": "Made", "by": "Planning", "at": "2026-10-01T09:00:00Z"}}]}
"""
try? Data(versionOne.utf8).write(to: file)
let readOne = AutomationFile.read(at: file).automations
expect("a version 1 file reads as Claude prompt triggers", readOne.count == 1 && readOne[0].task == "Claude prompt"
       && readOne[0].input == ["prompt": .text("Say hello"), "folder": .text("/work/x"), "agent": .text("reviewer")], "\(readOne)")
expect("with the rest of the record as it was", readOne.first.map { $0.name == "Old" && $0.permissions == .ask && $0.allowedTools == ["Edit"] && $0.workingLimitMinutes == 30
       && $0.lastSlot == at("2026-10-14 09:00") && $0.mark?.what == "Made" && $0.cadence == .daily(hour: 9, minute: 0) } == true, "\(readOne)")
expect("a version 1 file is runnable as it reads", readOne.first?.isRunnable == true)
let versionKept = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any])?["version"] as? Int
expect("reading it writes nothing: the file is still version 1", versionKept == 1)
let oneAndDefault = AutomationFile.giveFolder("/old/default", toThoseWithout: file)
expect("a version 1 file with every folder given is left alone", oneAndDefault == .nothingToMove && ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any])?["version"] as? Int == 1)
try? Data(versionOne.replacingOccurrences(of: "\"folder\": \"/work/x\", ", with: "").utf8).write(to: file)
expect("the Default folder move reads version 1", AutomationFile.giveFolder("/old/default", toThoseWithout: file) == .moved(1))
let movedOne = AutomationFile.read(at: file).automations
expect("and writes version 2 with the folder in the input", movedOne.first?.folder == "/old/default"
       && ((try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String: Any])?["version"] as? Int == 2)

// The input of the two built-in Tasks is checked in code.
let claudeInput: [String: TaskValue] = ["prompt": .text("Say hello")]
expect("Claude prompt takes a prompt alone", BuiltInTask.claudePrompt.problems(in: claudeInput).isEmpty)
expect("it takes a folder and an agent", BuiltInTask.claudePrompt.problems(in: claudeInput.merging(["folder": .text("/x"), "agent": .text("a")]) { $1 }).isEmpty)
expect("it needs a prompt", BuiltInTask.claudePrompt.problems(in: [:]) == ["prompt is missing"] && BuiltInTask.claudePrompt.problems(in: ["prompt": .text("  \n")]) == ["prompt is empty"])
expect("a field must be text", BuiltInTask.claudePrompt.problems(in: ["prompt": .number(3)]) == ["prompt must be text"])
expect("a field it doesn't have is a problem", BuiltInTask.claudePrompt.problems(in: claudeInput.merging(["site": .text("https://a.example")]) { $1 }) == ["site isn't a field of Claude prompt"])
expect("On this site needs a site and a goal", BuiltInTask.onThisSite.problems(in: [:]) == ["site is missing", "goal is missing"])
expect("a site is an http or https address", BuiltInTask.onThisSite.problems(in: ["site": .text("https://shop.example/x"), "goal": .text("Find the price")]).isEmpty
       && BuiltInTask.onThisSite.problems(in: ["site": .text("ftp://shop.example"), "goal": .text("x")]) == ["site must be an http or https address"]
       && BuiltInTask.onThisSite.problems(in: ["site": .text("not a site"), "goal": .text("x")]) == ["site must be an http or https address"])
expect("both are listed, Claude prompt first", BuiltInTask.all.map(\.name) == ["Claude prompt", "On this site"])
var emptyPrompt = sample
emptyPrompt.prompt = "  "
expect("an automation with a blank prompt, or a Task that isn't the Claude prompt, is not runnable", !emptyPrompt.isRunnable
       && { var site = sample; site.task = "On this site"; return !site.isRunnable }())

// A value round-trips as the JSON it is.
let valueCase: TaskValue = .object(["a": .list([.number(1.5), .bool(true), .null, .text("x")]), "b": .bool(false)])
let valueBack = (try? JSONEncoder().encode(valueCase)).flatMap { try? JSONDecoder().decode(TaskValue.self, from: $0) }
expect("a value survives JSON", valueBack == valueCase, "\(String(describing: valueBack))")

// The runs file is a file of its own at version 1, with the automations file's rules.
let runsFile = TaskRunFile.url(in: folder)
expect("the runs file is not the automations file", runsFile.lastPathComponent == "runs.json" && runsFile != AutomationFile.url(in: folder))
expect("no runs file reads as missing, which is not a problem", TaskRunFile.read(at: runsFile) == .missing && TaskRunFile.read(at: runsFile).problem == nil)
var stored = list.runs(of: sample.id)
stored[0].state = .message
stored[0].detail = "Found 3"
stored[0].input = ["prompt": .text("Say hello")]
do {
    try TaskRunFile.write(stored, to: runsFile)
    let back = TaskRunFile.read(at: runsFile)
    expect("Runs survive their file", back == .loaded(stored), "\(back)")
    let mode = (try? FileManager.default.attributesOfItem(atPath: runsFile.path)[.posixPermissions] as? Int) ?? 0
    expect("the runs file is owner-only", mode == 0o600, String(mode, radix: 8))
    let version = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: runsFile))) as? [String: Any])?["version"] as? Int
    expect("it is written as version 1", version == 1)
} catch {
    expect("the runs file can be written", false, "\(error)")
}
try? Data("{\"version\": 2, \"runs\": []}".utf8).write(to: runsFile)
expect("a version 2 runs file is read as newer and never written over", TaskRunFile.read(at: runsFile) == .newer(2) && TaskRunFile.read(at: runsFile).problem != nil)
try? Data("not json".utf8).write(to: runsFile)
if case .unreadable = TaskRunFile.read(at: runsFile) {} else { expect("garbage in the runs file is unreadable", false) }
expect("an unreadable runs file has a problem and reads no runs", TaskRunFile.read(at: runsFile).problem != nil && TaskRunFile.read(at: runsFile).runs.isEmpty)
try? Data("{\"version\": 1, \"runs\": [{\"task\": 3}]}".utf8).write(to: runsFile)
if case .unreadable = TaskRunFile.read(at: runsFile) {} else { expect("a Run that doesn't decode is unreadable", false) }
try? FileManager.default.removeItem(at: runsFile)
// A run state a newer build wrote reads as done, not as an unreadable file.
let strange = Data("\"somethingNew\"".utf8)
expect("an unknown run state reads as done", (try? JSONDecoder().decode(RunState.self, from: strange)) == .done)

// MARK: Sessions making, editing and switching automations (slice 3)

let toolsRoot = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-tools-\(getpid())")
let toolsFolder = toolsRoot.appendingPathComponent("repo").path
let otherFolder = toolsRoot.appendingPathComponent("other").path
try? FileManager.default.createDirectory(atPath: toolsFolder + "/.claude/agents", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: otherFolder, withIntermediateDirectories: true)
try? Data("---\nname: slot-check-reviewer\ndescription: x\n---\nbody\n".utf8).write(to: URL(fileURLWithPath: toolsFolder + "/.claude/agents/slot-check-reviewer.md"))

let toolsContext = AutomationTools.Context(sessionFolder: toolsFolder, homeFolder: otherFolder)
let dailyNine = "{\"kind\": \"daily\", \"hour\": 9, \"minute\": 0}"
let now = at("2026-10-15 09:07")

func fields(_ arguments: [String: String], creating: Bool = true, _ context: AutomationTools.Context = toolsContext) -> AutomationTools.Fields? {
    if case .success(let found) = AutomationTools.read(arguments, creating: creating, in: context) { return found }
    return nil
}

func problems(_ arguments: [String: String], creating: Bool = true, _ context: AutomationTools.Context = toolsContext) -> [String] {
    if case .failure(let found) = AutomationTools.read(arguments, creating: creating, in: context) { return found.lines }
    return []
}

let minimal = ["name": "Morning", "prompt": "Say hello", "cadence": dailyNine]
/// The minimal create with some arguments added or replaced.
func plus(_ more: [String: String]) -> [String: String] { minimal.merging(more) { $1 } }

let made = fields(minimal)
expect("a create with the three required fields reads", made?.name == "Morning" && made?.prompt == "Say hello" && made?.cadence == .daily(hour: 9, minute: 0))
let missing = problems([:])
expect("a create with nothing names name, prompt and cadence",
       missing.count == 3 && missing[0].hasPrefix("name") && missing[1].hasPrefix("prompt") && missing[2].hasPrefix("cadence"), "\(missing)")
expect("the cadence refusal lists the presets", missing.last?.contains("weekdays") == true && missing.last?.contains("15 or 30") == true, missing.last ?? "")

// Every wrong field is named in the one refusal.
let many = problems(["name": " ", "prompt": "x", "cadence": "{\"kind\": \"minutes\", \"every\": 5}", "folder": "/slot-check/no/such/folder",
                     "permissions": "skip", "working_limit_minutes": "4", "enabled": "maybe", "colour": "red"])
expect("a refusal names each wrong field", many.count == 7, "\(many.count): \(many)")
expect("every 5 minutes is refused with the steps", problems(plus(["cadence": "{\"kind\": \"minutes\", \"every\": 5}"])).first?.contains("15 or 30") == true)

// The cadence's forms.
func cadence(_ json: String) -> AutomationCadence? { fields(plus(["cadence": json]))?.cadence }
expect("every 30 minutes", cadence("{\"kind\":\"minutes\",\"every\":30}") == .minutes(30))
expect("every 12 hours, the number as text", cadence("{\"kind\":\"hours\",\"every\":\"12\"}") == .hours(12))
expect("daily with no minute is on the hour", cadence("{\"kind\":\"daily\",\"hour\":7}") == .daily(hour: 7, minute: 0))
expect("weekdays at 23:59", cadence("{\"kind\":\"weekdays\",\"hour\":23,\"minute\":59}") == .weekdays(hour: 23, minute: 59))
expect("weekly by a day's name", cadence("{\"kind\":\"weekly\",\"weekday\":\"Monday\",\"hour\":9}") == .weekly(weekday: 2, hour: 9, minute: 0))
expect("weekly by number", cadence("{\"kind\":\"weekly\",\"weekday\":7,\"hour\":9}") == .weekly(weekday: 7, hour: 9, minute: 0))
expect("weekly with no weekday is refused", cadence("{\"kind\":\"weekly\",\"hour\":9}") == nil)
expect("hour 24 is refused", cadence("{\"kind\":\"daily\",\"hour\":24}") == nil)
expect("every 2 minutes is refused", cadence("{\"kind\":\"minutes\",\"every\":2}") == nil)
expect("every 5 hours is refused", cadence("{\"kind\":\"hours\",\"every\":5}") == nil)
expect("a kind that is not a preset is refused", cadence("{\"kind\":\"cron\",\"every\":1}") == nil)
expect("a cadence that is not an object is refused", cadence("every day") == nil)

// Folders: the session's own when none is given; an existing one otherwise.
let withoutFolder = AutomationTools.make(made!, in: toolsContext, now: now)
expect("a create with no folder is the calling session's folder", withoutFolder.folder == toolsFolder, "\(withoutFolder.folder ?? "nil")")
expect("a folder that exists is taken, without a trailing slash", fields(plus(["folder": otherFolder + "/"]))?.folder == otherFolder)
expect("a folder from the home folder is expanded", fields(plus(["folder": "~"]))?.folder == NSHomeDirectory())
expect("a relative folder is refused", !problems(plus(["folder": "repo"])).isEmpty)
expect("a folder that is a file is refused", !problems(plus(["folder": toolsFolder + "/.claude/agents/slot-check-reviewer.md"])).isEmpty)

// Agents: of the folder the automation will have.
expect("an agent of the session's folder is taken", fields(plus(["agent": "slot-check-reviewer"]))?.agent == .some("slot-check-reviewer"))
let wrongAgent = problems(plus(["agent": "slot-check-nobody"]))
expect("an agent the folder doesn't have is refused and the folder's agents are listed", wrongAgent.count == 1 && wrongAgent[0].contains("slot-check-reviewer"), "\(wrongAgent)")
expect("the agent is judged against the folder given", !problems(plus(["agent": "slot-check-reviewer", "folder": otherFolder])).isEmpty)

// Permissions: never Skip.
expect("no permissions follows Varnick's setting", AutomationTools.make(made!, in: toolsContext, now: now).permissions == nil)
expect("ask", fields(plus(["permissions": "ask"]))?.permissions == .some(.ask))
expect("allowed tools only", fields(plus(["permissions": "allowed_tools_only"]))?.permissions == .some(.allowedOnly))
expect("an edit can go back to Varnick's setting", fields(["permissions": "varnick_setting"], creating: false)?.permissions == .some(nil))
for word in ["skip", "Skip", "skip_permissions"] {
    expect("\(word) is refused", problems(plus(["permissions": word])).first?.contains("may not set Skip") == true)
}
expect("a made-up permission is refused", !problems(plus(["permissions": "yolo"])).isEmpty)

// The rest of the fields.
expect("the name is one line, cut to 80", fields(plus(["name": "a\nb  " + String(repeating: "x", count: 100)]))?.name?.count == 80)
expect("allowed tools as a list", fields(plus(["allowed_tools": "[\"Bash(git status)\", \"Edit\"]"]))?.allowedTools == ["Bash(git status)", "Edit"])
expect("allowed tools as lines", fields(plus(["allowed_tools": "Edit\n\n WebSearch "]))?.allowedTools == ["Edit", "WebSearch"])
expect("allowed tools that aren't strings are refused", !problems(plus(["allowed_tools": "[1, 2]"])).isEmpty)
expect("a working limit of 4 is refused", !problems(plus(["working_limit_minutes": "4"])).isEmpty)
expect("5 and 1440 are the ends", fields(plus(["working_limit_minutes": "5"]))?.workingLimitMinutes == 5
       && fields(plus(["working_limit_minutes": "1440"]))?.workingLimitMinutes == 1440)
expect("1441 is refused", !problems(plus(["working_limit_minutes": "1441"])).isEmpty)
let defaulted = AutomationTools.make(made!, in: toolsContext, now: now)
expect("a create's working limit is 60 and it is on", defaulted.workingLimitMinutes == 60 && defaulted.enabled)
expect("a create may start off", !AutomationTools.make(fields(plus(["enabled": "false"]))!, in: toolsContext, now: now).enabled)
let inTokyo = AutomationTools.make(made!, in: toolsContext, now: now, zone: tokyo)
expect("a create's slots start from now, in this Mac's zone", inTokyo.lastSlot == now && inTokyo.createdAt == now && inTokyo.timeZone == "Asia/Tokyo")
expect("an edit takes id beside the fields", fields(["id": "x", "name": "New"], creating: false)?.name == "New")
expect("an edit with nothing to change is refused", problems(["id": "x"], creating: false).first?.hasPrefix("Nothing to change") == true)

// A JSON boolean is not a number (a cast would read true as 1, a valid hour step).
expect("a boolean is not a number", cadence("{\"kind\":\"hours\",\"every\":true}") == nil && cadence("{\"kind\":\"daily\",\"hour\":true}") == nil
       && cadence("{\"kind\":\"weekly\",\"weekday\":true,\"hour\":9}") == nil && cadence("{\"kind\":\"daily\",\"hour\":9,\"minute\":false}") == nil)
expect("1 and 9.0 still are", cadence("{\"kind\":\"hours\",\"every\":1}") == .hours(1) && cadence("{\"kind\":\"daily\",\"hour\":9.0}") == .daily(hour: 9, minute: 0))
expect("id is not a field of a create", !problems(plus(["id": "x"])).isEmpty)

// A session's folder that has gone is refused when it would be the automation's folder.
let goneContext = AutomationTools.Context(sessionFolder: toolsRoot.path + "/gone", homeFolder: otherFolder)
let goneProblems = problems(minimal, creating: true, goneContext)
expect("a gone session folder is refused when none is given", goneProblems.count == 1 && goneProblems[0].hasPrefix("folder"), "\(goneProblems)")
expect("but not when a folder is given", fields(plus(["folder": otherFolder]), creating: true, goneContext) != nil)

// The permission names are one table, Skip's included for a list.
expect("the permission names map both ways", AutomationTools.permissionName(nil) == "varnick_setting" && AutomationTools.permissionName(.ask) == "ask"
       && AutomationTools.permissionName(.allowedOnly) == "allowed_tools_only" && AutomationTools.permissionName(.skip) == "skip"
       && AutomationTools.permissionNames == ["varnick_setting", "ask", "allowed_tools_only"])

// A mark names the rules a session set: a broad one lets an unattended run do more than a typed prompt gets with Skip off.
let broad = AutomationTools.make(fields(plus(["allowed_tools": "Bash\nEdit"]))!, in: toolsContext, now: now)
expect("a create's mark names its allowed tools", AutomationTools.markText(made: broad) == "Made, with allowed tools: Bash, Edit", AutomationTools.markText(made: broad))
expect("a create without any says only Made", AutomationTools.markText(made: AutomationTools.make(made!, in: toolsContext, now: now)) == "Made")

// Edit: only the given fields change, onto the current copy.
var current = AutomationTools.make(fields(plus(["permissions": "ask"]))!, in: toolsContext, now: at("2026-10-01 08:00"), zone: utc)
current.lastSlot = at("2026-10-14 09:00")
let editContext = AutomationTools.Context(sessionFolder: toolsFolder, homeFolder: otherFolder, current: current)
func edited(_ arguments: [String: String], _ automation: Automation, zone: TimeZone = utc) -> (automation: Automation, changed: [String])? {
    guard let given = fields(arguments, creating: false, AutomationTools.Context(sessionFolder: toolsFolder, homeFolder: otherFolder, current: automation)) else { return nil }
    return AutomationTools.edit(automation, with: given, now: now, zone: zone)
}
let promptOnly = edited(["prompt": "Say goodbye"], current)
var promptReverted = promptOnly?.automation
promptReverted?.prompt = current.prompt
expect("a prompt edit changes the prompt alone", promptOnly?.automation.prompt == "Say goodbye" && promptOnly?.changed == ["prompt"] && promptReverted == current)
expect("it keeps the Task, the rest of the input and the last slot", promptOnly?.automation.task == current.task && promptOnly?.automation.folder == current.folder
       && promptOnly?.automation.lastSlot == current.lastSlot)
let moved = edited(["cadence": "{\"kind\":\"hours\",\"every\":2}"], current)
expect("a changed cadence starts the slots from now", moved?.automation.lastSlot == now && moved?.changed == ["cadence"])
expect("the same cadence changes nothing", edited(["cadence": dailyNine], current) == nil)
let zoned = edited(["name": "Evening"], current, zone: tokyo)
expect("an edit stamps this Mac's zone, and a changed zone starts the slots from now", zoned?.automation.timeZone == "Asia/Tokyo" && zoned?.automation.lastSlot == now)
var off = current
off.enabled = false
let turnedOn = edited(["enabled": "true"], off)
expect("an edit that turns it on starts the slots from now", turnedOn?.automation.enabled == true && turnedOn?.automation.lastSlot == now)
let cleared = edited(["permissions": "varnick_setting"], current)
expect("an edit can clear the override", cleared?.automation.permissions == nil && cleared?.changed == ["permissions"])
let toolsSet = edited(["allowed_tools": "Bash"], current)
expect("an edit of the allowed tools says so, naming the rules", toolsSet?.changed == ["allowed tools"]
       && toolsSet.map { AutomationTools.markText(edited: $0.changed, to: $0.automation) } == "Edited: allowed tools set to Bash")
let toolsGone = toolsSet.flatMap { edited(["allowed_tools": "[]"], $0.automation) }
expect("and clearing them says cleared", toolsGone.map { AutomationTools.markText(edited: $0.changed, to: $0.automation) } == "Edited: allowed tools cleared")
expect("other fields are named by name", AutomationTools.markText(edited: ["prompt", "cadence"], to: current) == "Edited: prompt, cadence")
var withAgent = current
withAgent.agent = "slot-check-reviewer"
let agentCleared = edited(["agent": ""], withAgent)
expect("an empty agent clears it", agentCleared?.automation.agent == nil && agentCleared?.changed == ["agent"])
let movedFolder = problems(["folder": otherFolder], creating: false, AutomationTools.Context(sessionFolder: toolsFolder, homeFolder: otherFolder, current: withAgent))
expect("a new folder without the automation's agent is refused", movedFolder.count == 1 && movedFolder[0].contains("slot-check-reviewer"), "\(movedFolder)")
expect("a new folder with the agent given as none is fine", edited(["folder": otherFolder, "agent": ""], withAgent)?.automation.folder == otherFolder)

// Skip: not editable, switchable.
var skipping = current
skipping.permissions = .skip
expect("a Skip automation may not be edited by a session", AutomationTools.editRefusal(for: skipping) != nil && AutomationTools.editRefusal(for: current) == nil)
expect("but it may be switched", AutomationTools.switching(skipping, on: false, now: now)?.enabled == false)

// Switch.
expect("switching to the state it has changes nothing", AutomationTools.switching(current, on: true, now: now) == nil && AutomationTools.switching(off, on: false, now: now) == nil)
let switchedOn = AutomationTools.switching(off, on: true, now: now)
expect("turning it on starts the slots from now", switchedOn?.enabled == true && switchedOn?.lastSlot == now)
let switchedOff = AutomationTools.switching(current, on: false, now: now)
expect("turning it off keeps the slot", switchedOff?.enabled == false && switchedOff?.lastSlot == current.lastSlot)

// The mark rides on the automation, and the file is at version 2 and reads without it.
let markedFile = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-mark-\(getpid()).json")
var marked = current
marked.mark = AutomationMark(what: "Edited: prompt", by: "Planning", at: at("2026-10-15 09:07"))
try? AutomationFile.write([marked, current], to: markedFile)
let readBack = AutomationFile.read(at: markedFile)
expect("a mark survives the file and an automation without one stays without", readBack == .loaded([marked, current]), "\(readBack)")
let markedVersion = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: markedFile))) as? [String: Any])?["version"] as? Int
expect("the file is at version 2", markedVersion == 2)
try? FileManager.default.removeItem(at: markedFile)
try? FileManager.default.removeItem(at: toolsRoot)

// MARK: Marking Home trusted in Claude Code's config (`ClaudeTrust`)

let trustHome = "/Users/x/Library/Application Support/Varnick/Home"
func marking(_ text: String) -> ClaudeTrust.TrustEdit { ClaudeTrust.trustEdit(for: trustHome, in: Data(text.utf8)) }
func changedText(_ text: String) -> String? {
    if case .changed(let data) = marking(text) { return String(decoding: data, as: UTF8.self) }
    return nil
}
/// Every byte of the original is still there, in order, with only the inserted text added: removing it gives the original back.
func isUntouched(_ original: String, _ result: String?, inserted: String) -> Bool {
    guard let result, let range = result.range(of: inserted) else { return false }
    var copy = result
    copy.removeSubrange(range)
    return copy == original
}
let trustQuirks = """
{
  "numStartups": 1.50e2,
  "tip": "a } and \\" quote",
  "projects": {
    "/a": {"hasTrustDialogAccepted": true},
    "/b": {"allowedTools": [], "hasTrustDialogAccepted": false}
  },
  "after": [1, {"projects": 2}]
}

"""
let newEntry = "\"\(trustHome)\":{\"hasTrustDialogAccepted\":true},"
expect("a folder with no entry gets one just inside projects, nothing else changed", isUntouched(trustQuirks, changedText(trustQuirks), inserted: newEntry), changedText(trustQuirks) ?? "nil")
expect("and it reads back as trusted", ClaudeTrust.isTrusted(trustHome, in: Data((changedText(trustQuirks) ?? "").utf8)) == true)
expect("another folder is not made trusted by it", ClaudeTrust.isTrusted("/elsewhere", in: Data((changedText(trustQuirks) ?? "").utf8)) == false)
let falseEntry = "{\"projects\": {\"\(trustHome)\": {\"hasTrustDialogAccepted\": false, \"x\": 1}}}"
expect("a false becomes true in place", changedText(falseEntry) == falseEntry.replacingOccurrences(of: "false", with: "true"))
let bareEntry = "{\"projects\": {\"\(trustHome)\": {\"x\": 1}, \"/b\": {}}}"
expect("an entry without the key gets it first", isUntouched(bareEntry, changedText(bareEntry), inserted: "\"hasTrustDialogAccepted\":true,"))
let emptyEntry = "{\"projects\": {\"\(trustHome)\": {}}}"
expect("an empty entry gets it without a comma", changedText(emptyEntry) == "{\"projects\": {\"\(trustHome)\": {\"hasTrustDialogAccepted\":true}}}", changedText(emptyEntry) ?? "nil")
expect("an empty projects gets the entry without a comma", changedText("{\"projects\":{}}") == "{\"projects\":{\"\(trustHome)\":{\"hasTrustDialogAccepted\":true}}}")
expect("a trusted folder needs no change", marking("{\"projects\": {\"\(trustHome)\": {\"hasTrustDialogAccepted\": true}}}") == .already)
expect("a trusted parent is not the folder's own entry, so Home still gets its own", changedText("{\"projects\": {\"/Users/x/Library\": {\"hasTrustDialogAccepted\": true}}}") != nil)
let repeatedKeys: [(String, String)] = [("projects", "{\"projects\":{},\"projects\":{}}"), ("the folder", "{\"projects\":{\"\(trustHome)\":{},\"\(trustHome)\":{}}}"),
    ("the trust key", "{\"projects\":{\"\(trustHome)\":{\"hasTrustDialogAccepted\":false,\"hasTrustDialogAccepted\":false}}}")]
for (why, text) in repeatedKeys {
    var repeated = false
    if case .unexpected("a key is repeated") = marking(text) { repeated = true }
    expect("a repeated key for \(why) is left alone", repeated)
}
let unexpectedShapes: [(String, String)] = [
    ("no projects", "{\"a\": 1}"), ("projects that isn't an object", "{\"projects\": []}"), ("text that isn't json", "oops"), ("an empty file", ""),
    ("a cut-off file", "{\"projects\": {\"/a\": {"), ("a trust value that isn't a boolean", "{\"projects\": {\"\(trustHome)\": {\"hasTrustDialogAccepted\": \"yes\"}}}"),
    ("a root that isn't an object", "[1]"),
]
for (why, text) in unexpectedShapes {
    var unexpected = false
    if case .unexpected = marking(text) { unexpected = true }
    expect("\(why) is left alone", unexpected)
}
let quoted = "/Users/x/it's \"odd\"\\dir"
var quotedWorks = false
if case .changed(let data) = ClaudeTrust.trustEdit(for: quoted, in: Data("{\"projects\":{}}".utf8)) { quotedWorks = ClaudeTrust.isTrusted(quoted, in: data) == true }
expect("a path with quotes and backslashes is escaped", quotedWorks)

let trustRoot = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-trust-\(getpid())")
try? FileManager.default.createDirectory(at: trustRoot, withIntermediateDirectories: true)
let trustFile = trustRoot.appendingPathComponent("claude.json")
func attributes(_ url: URL) -> [FileAttributeKey: Any]? { try? FileManager.default.attributesOfItem(atPath: url.path) }
try? Data(trustQuirks.utf8).write(to: trustFile)
try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trustFile.path)
expect("a file is marked", ClaudeTrust.writeTrust(for: trustHome, file: trustFile) == .trusted)
expect("the file on disk is the original with the one entry added", isUntouched(trustQuirks, try? String(contentsOf: trustFile, encoding: .utf8), inserted: newEntry))
expect("it keeps the file's permissions", (attributes(trustFile)?[.posixPermissions] as? NSNumber)?.intValue == 0o600)
expect("no temporary file or lock is left beside it", ((try? FileManager.default.contentsOfDirectory(atPath: trustRoot.path)) ?? []) == ["claude.json"])
expect("a second mark finds it trusted and writes nothing", ClaudeTrust.writeTrust(for: trustHome, file: trustFile) == .alreadyTrusted)
expect("a missing file is skipped", ClaudeTrust.writeTrust(for: trustHome, file: trustRoot.appendingPathComponent("none.json")) == .skipped("the file can't be read"))
expect("and not created", attributes(trustRoot.appendingPathComponent("none.json")) == nil)
let linked = trustRoot.appendingPathComponent("link.json")
try? FileManager.default.createSymbolicLink(at: linked, withDestinationURL: trustFile)
try? Data(trustQuirks.utf8).write(to: trustFile)
expect("a linked file is marked through the link", ClaudeTrust.writeTrust(for: trustHome, file: linked) == .trusted)
expect("and the link is still a link", (try? FileManager.default.destinationOfSymbolicLink(atPath: linked.path)) == trustFile.path)
// Claude Code takes a lock directory beside the file while it saves; a held one is waited for, then the write is skipped.
try? Data(trustQuirks.utf8).write(to: trustFile)
try? FileManager.default.createDirectory(at: URL(fileURLWithPath: trustFile.path + ".lock"), withIntermediateDirectories: false)
expect("a held lock stops the write", ClaudeTrust.writeTrust(for: trustHome, file: trustFile) == .skipped("Claude Code holds the file's lock"))
expect("and leaves the file as it was", (try? String(contentsOf: trustFile, encoding: .utf8)) == trustQuirks)
expect("and the other's lock stays", attributes(URL(fileURLWithPath: trustFile.path + ".lock")) != nil)
try? FileManager.default.removeItem(atPath: trustFile.path + ".lock")

// A folder in a git repo needs that repo's own entry; a trusted parent doesn't cover a nested repo, and a folder in no repo takes its ancestors'.
let outer = trustRoot.appendingPathComponent("outer").path
try? FileManager.default.createDirectory(atPath: outer + "/repo/.git", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: outer + "/repo/sub", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: outer + "/plain/deeper", withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: outer + "/tree", withIntermediateDirectories: true)
try? Data("gitdir: elsewhere\n".utf8).write(to: URL(fileURLWithPath: outer + "/tree/.git"))
func trustConfig(_ keys: [String]) -> Data {
    Data(("{\"projects\":{" + keys.map { "\"\($0)\":{\"hasTrustDialogAccepted\":true}" }.joined(separator: ",") + "}}").utf8)
}
expect("a trusted parent does not cover a nested repo", ClaudeTrust.isTrusted(outer + "/repo", in: trustConfig([outer])) == false)
expect("nor a folder inside it", ClaudeTrust.isTrusted(outer + "/repo/sub", in: trustConfig([outer])) == false)
expect("the repo's own entry covers it and its folders", ClaudeTrust.isTrusted(outer + "/repo/sub", in: trustConfig([outer + "/repo"])) == true)
expect("a worktree's .git file marks a repo too", ClaudeTrust.isTrusted(outer + "/tree", in: trustConfig([outer])) == false)
expect("a folder in no repo takes a trusted ancestor", ClaudeTrust.isTrusted(outer + "/plain/deeper", in: trustConfig([outer + "/plain"])) == true)
expect("and is untrusted when none is", ClaudeTrust.isTrusted(outer + "/plain/deeper", in: trustConfig(["/elsewhere"])) == false)
let plainLink = trustRoot.appendingPathComponent("link-to-plain").path
try? FileManager.default.createSymbolicLink(atPath: plainLink, withDestinationPath: outer + "/plain")
expect("a symlink to a trusted folder is looked through", ClaudeTrust.isTrusted(plainLink, in: trustConfig([outer + "/plain"])) == true)

try? FileManager.default.removeItem(at: trustRoot)

// MARK: The old Default folder, given to the automations that had none

let moveFile = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-move-\(getpid()).json")
var folderAutomation = current
folderAutomation.folder = toolsFolder
var noFolderAutomation = current
noFolderAutomation.id = UUID()
noFolderAutomation.folder = nil
try? AutomationFile.write([folderAutomation, noFolderAutomation], to: moveFile)
expect("an automation with no folder is given the old Default folder", AutomationFile.giveFolder("/old/default", toThoseWithout: moveFile) == .moved(1))
let moveRead = AutomationFile.read(at: moveFile).automations
expect("the others keep theirs", moveRead.first { $0.id == folderAutomation.id }?.folder == toolsFolder && moveRead.first { $0.id == noFolderAutomation.id }?.folder == "/old/default")
expect("and a second move finds nothing to do", AutomationFile.giveFolder("/old/default", toThoseWithout: moveFile) == .nothingToMove)
expect("no file is nothing to do", AutomationFile.giveFolder("/old/default", toThoseWithout: moveFile.appendingPathExtension("none")) == .nothingToMove)
try? Data("not json".utf8).write(to: moveFile)
expect("a file this build can't read is kept as it is", AutomationFile.giveFolder("/old/default", toThoseWithout: moveFile) == .kept("the automations file isn't one this build writes"))
try? FileManager.default.removeItem(at: moveFile)

if failures > 0 {
    FileHandle.standardError.write(Data("error: check-slots: \(failures) of \(cases) checks failed\n".utf8))
    exit(1)
}
print("check-slots: \(cases) checks passed")
