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
var sample = Automation(name: "Morning summary", prompt: "Say hello", cadence: .weekdays(hour: 9, minute: 0), timeZone: "America/Los_Angeles",
                        permissions: .allowedOnly, allowedTools: ["Bash(git status)", "Edit"], createdAt: at("2026-10-15 09:00"))
sample.lastSlot = at("2026-10-15 16:00")
for index in 0..<(Automation.runLimit + 5) {
    let slot = at("2026-10-15 16:00").addingTimeInterval(Double(index) * 60)
    sample.record(AutomationRun(slot: slot, endedAt: slot, state: .done))
}
expect("a run list keeps twenty, newest first", sample.runs.count == 20 && sample.runs.first!.slot > sample.runs.last!.slot)
// A run that may still have a pane is never the one dropped, and slots that did not run fold.
var going = Automation(name: "Going", prompt: "x", cadence: .minutes(15), createdAt: at("2026-10-15 09:00"))
let oldest = AutomationRun(slot: at("2026-10-15 09:00"), startedAt: at("2026-10-15 09:00"), state: .running)
going.record(oldest)
for index in 1...30 {
    let slot = at("2026-10-15 09:00").addingTimeInterval(Double(index) * 900)
    going.record(AutomationRun(slot: slot, startedAt: slot, endedAt: slot, state: .done))
}
expect("a run still going outlives twenty newer ones", going.runs.count == 20 && going.runs.contains { $0.id == oldest.id }, "\(going.runs.count) runs")
var flood = Automation(name: "Flood", prompt: "x", cadence: .minutes(15), createdAt: at("2026-10-15 09:00"))
for index in 0..<40 {
    flood.record(AutomationRun(slot: at("2026-10-15 09:00").addingTimeInterval(Double(index) * 900), state: .skipped, detail: "The last run was still going"))
}
expect("40 skipped slots are one record that counts them", flood.runs.count == 1 && flood.runs[0].count == 40
       && flood.runs[0].slot == at("2026-10-15 09:00").addingTimeInterval(39 * 900), "\(flood.runs.count) records")
flood.record(AutomationRun(slot: at("2026-10-16 09:00"), state: .missed, detail: "Over 12 hours old at the next check"))
flood.record(AutomationRun(slot: at("2026-10-16 09:15"), state: .skipped, detail: "The last run was still going"))
expect("a different state or reason is another record", flood.runs.count == 3, "\(flood.runs.count) records")
flood.record(AutomationRun(slot: at("2026-10-16 09:30"), startedAt: at("2026-10-16 09:30"), state: .running))
flood.record(AutomationRun(slot: at("2026-10-16 09:45"), state: .skipped, detail: "The last run was still going"))
expect("a run between two skipped slots splits them", flood.runs.count == 5, "\(flood.runs.count) records")
sample.runs[0].state = .message
sample.runs[0].detail = "Found 3"
do {
    try AutomationFile.write([sample], to: file)
    let back = AutomationFile.read(at: file)
    expect("an automation survives its file", back == .loaded([sample]), "\(back)")
    let mode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) ?? 0
    expect("the file is owner-only", mode == 0o600, String(mode, radix: 8))
} catch {
    expect("the file can be written", false, "\(error)")
}
try? Data("{\"version\": 99, \"automations\": []}".utf8).write(to: file)
expect("a newer version is never written over", AutomationFile.read(at: file) == .newer(99) && AutomationFile.read(at: file).problem != nil)
try? Data("not json".utf8).write(to: file)
if case .unreadable = AutomationFile.read(at: file) {} else { expect("garbage is unreadable", false) }
try? Data("{\"version\": 1, \"automations\": [{\"name\": 3}]}".utf8).write(to: file)
if case .unreadable = AutomationFile.read(at: file) {} else { expect("a record that doesn't decode is unreadable", false) }
expect("an unreadable file fires nothing", AutomationFile.read(at: file).automations.isEmpty)
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

let toolsContext = AutomationTools.Context(sessionFolder: toolsFolder, defaultFolder: otherFolder)
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
let goneContext = AutomationTools.Context(sessionFolder: toolsRoot.path + "/gone", defaultFolder: otherFolder)
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
current.runs = [AutomationRun(slot: at("2026-10-14 09:00"), state: .done)]
current.lastSlot = at("2026-10-14 09:00")
let editContext = AutomationTools.Context(sessionFolder: toolsFolder, defaultFolder: otherFolder, current: current)
func edited(_ arguments: [String: String], _ automation: Automation, zone: TimeZone = utc) -> (automation: Automation, changed: [String])? {
    guard let given = fields(arguments, creating: false, AutomationTools.Context(sessionFolder: toolsFolder, defaultFolder: otherFolder, current: automation)) else { return nil }
    return AutomationTools.edit(automation, with: given, now: now, zone: zone)
}
let promptOnly = edited(["prompt": "Say goodbye"], current)
var promptReverted = promptOnly?.automation
promptReverted?.prompt = current.prompt
expect("a prompt edit changes the prompt alone", promptOnly?.automation.prompt == "Say goodbye" && promptOnly?.changed == ["prompt"] && promptReverted == current)
expect("it keeps the runs and the last slot", promptOnly?.automation.runs == current.runs && promptOnly?.automation.lastSlot == current.lastSlot)
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
let movedFolder = problems(["folder": otherFolder], creating: false, AutomationTools.Context(sessionFolder: toolsFolder, defaultFolder: otherFolder, current: withAgent))
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
expect("turning it off keeps the slot and the runs", switchedOff?.enabled == false && switchedOff?.lastSlot == current.lastSlot && switchedOff?.runs == current.runs)

// The mark rides on the automation, and the file stays at version 1 and reads without it.
let markedFile = FileManager.default.temporaryDirectory.appendingPathComponent("slot-check-mark-\(getpid()).json")
var marked = current
marked.mark = AutomationMark(what: "Edited: prompt", by: "Planning", at: at("2026-10-15 09:07"))
try? AutomationFile.write([marked, current], to: markedFile)
let readBack = AutomationFile.read(at: markedFile)
expect("a mark survives the file and an automation without one stays without", readBack == .loaded([marked, current]), "\(readBack)")
let markedVersion = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: markedFile))) as? [String: Any])?["version"] as? Int
expect("the file is still version 1", markedVersion == 1)
try? FileManager.default.removeItem(at: markedFile)
try? FileManager.default.removeItem(at: toolsRoot)

if failures > 0 {
    FileHandle.standardError.write(Data("error: check-slots: \(failures) of \(cases) checks failed\n".utf8))
    exit(1)
}
print("check-slots: \(cases) checks passed")
