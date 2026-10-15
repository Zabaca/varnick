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
    sample.record(AutomationRun(slot: at("2026-10-15 16:00").addingTimeInterval(Double(index) * 60), state: .done))
}
expect("a run list keeps twenty, newest first", sample.runs.count == 20 && sample.runs.first!.slot > sample.runs.last!.slot)
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

if failures > 0 {
    FileHandle.standardError.write(Data("error: check-slots: \(failures) of \(cases) checks failed\n".utf8))
    exit(1)
}
print("check-slots: \(cases) checks passed")
