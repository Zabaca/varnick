import Foundation

/// How often an automation runs (option 01 of `prompts-cant-run-on-a-schedule`): presets only, kept as data and not as a cron string. Fifteen
/// minutes is the shortest, since each run is a whole Claude session. A slot is one time the cadence names, such as 9:00 on a Wednesday, in the
/// zone the automation keeps (the zone of the Mac that saved it).
public enum AutomationCadence: Equatable, Hashable {
    /// Every `n` minutes of the hour from :00, `n` one of `minuteSteps`.
    case minutes(Int)
    /// Every `n` hours of the day from 0:00, `n` one of `hourSteps`.
    case hours(Int)
    case daily(hour: Int, minute: Int)
    case weekdays(hour: Int, minute: Int)
    /// `weekday` counts as `Calendar` does: 1 is Sunday.
    case weekly(weekday: Int, hour: Int, minute: Int)

    public static let minuteSteps = [15, 30]
    public static let hourSteps = [1, 2, 3, 4, 6, 12]
    /// The shortest gap between slots: the floor of the presets.
    public static let shortest: TimeInterval = 15 * 60

    /// Whether the values are ones a preset has. A cadence read from a file that fails this is never fired.
    public var isValid: Bool {
        switch self {
        case .minutes(let n): Self.minuteSteps.contains(n)
        case .hours(let n): Self.hourSteps.contains(n)
        case .daily(let h, let m), .weekdays(let h, let m): Self.valid(h, m)
        case .weekly(let d, let h, let m): (1...7).contains(d) && Self.valid(h, m)
        }
    }

    private static func valid(_ hour: Int, _ minute: Int) -> Bool { (0..<24).contains(hour) && (0..<60).contains(minute) }

    /// "Every 15 minutes", "Daily at 9:00", "Weekdays at 9:00", "Wednesdays at 9:00".
    public var label: String {
        func time(_ h: Int, _ m: Int) -> String { String(format: "%d:%02d", h, m) }
        switch self {
        case .minutes(let n): return "Every \(n) minutes"
        case .hours(let n): return n == 1 ? "Every hour" : "Every \(n) hours"
        case .daily(let h, let m): return "Daily at \(time(h, m))"
        case .weekdays(let h, let m): return "Weekdays at \(time(h, m))"
        case .weekly(let d, let h, let m):
            let names = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
            return "\(names[(d - 1 + 7) % 7]) at \(time(h, m))"
        }
    }

    /// Whether a slot at the same wall-clock time on a day with no such time (the hour a clock skips) moves to the next valid time, as a fixed
    /// time of day does, or is skipped, as a step through the day is: "every 2 hours" has nothing to run at 2:00 on that day.
    var shiftsOverGaps: Bool {
        switch self {
        case .minutes, .hours: false
        case .daily, .weekdays, .weekly: true
        }
    }
}

extension AutomationCadence: Codable {
    private enum Kind: String, Codable { case minutes, hours, daily, weekdays, weekly }

    private enum Keys: String, CodingKey { case kind, every, weekday, hour, minute }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .minutes: self = .minutes(try c.decode(Int.self, forKey: .every))
        case .hours: self = .hours(try c.decode(Int.self, forKey: .every))
        case .daily: self = .daily(hour: try c.decode(Int.self, forKey: .hour), minute: try c.decode(Int.self, forKey: .minute))
        case .weekdays: self = .weekdays(hour: try c.decode(Int.self, forKey: .hour), minute: try c.decode(Int.self, forKey: .minute))
        case .weekly:
            self = .weekly(weekday: try c.decode(Int.self, forKey: .weekday), hour: try c.decode(Int.self, forKey: .hour),
                           minute: try c.decode(Int.self, forKey: .minute))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .minutes(let n):
            try c.encode(Kind.minutes, forKey: .kind)
            try c.encode(n, forKey: .every)
        case .hours(let n):
            try c.encode(Kind.hours, forKey: .kind)
            try c.encode(n, forKey: .every)
        case .daily(let h, let m):
            try c.encode(Kind.daily, forKey: .kind)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        case .weekdays(let h, let m):
            try c.encode(Kind.weekdays, forKey: .kind)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        case .weekly(let d, let h, let m):
            try c.encode(Kind.weekly, forKey: .kind)
            try c.encode(d, forKey: .weekday)
            try c.encode(h, forKey: .hour)
            try c.encode(m, forKey: .minute)
        }
    }
}

/// When an automation is due: one pure function of the cadence, the zone, the last slot fired for and the time now, which a Mac's check and (from
/// slice 2) the headless host's relay both call. `make check-slots` runs it over a table of cases.
public enum AutomationSlot {
    /// A due slot older than this is not run: a Mac shut for a weekend doesn't start Friday's runs on Monday.
    public static let catchUpWindow: TimeInterval = 12 * 3600
    /// A run started this long after its slot is marked late. The check runs once a minute, so a normal run is up to a minute behind.
    public static let lateAfter: TimeInterval = 120
    /// How many missed slots a check names: a run list keeps twenty runs, so more would only push them out.
    public static let missedLimit = 20

    public struct Check: Equatable {
        /// The slot to run now, if there is one under the catch-up window.
        public var due: Date?
        /// Slots that passed since the last and are not run, newest first, at most `missedLimit`.
        public var missed: [Date]
        /// The due slot is not the one that just passed: the Mac slept or Varnick was quit through it.
        public var late: Bool
    }

    /// What a check at `now` does for an automation whose last slot is `last`. The newest slot in (`last`, `now`] is due, if under the catch-up
    /// window; every other slot there is missed. A slot at exactly `now` is due.
    public static func check(_ cadence: AutomationCadence, zone: TimeZone, after last: Date, now: Date) -> Check {
        guard cadence.isValid else { return Check(due: nil, missed: [], late: false) }
        let found = slots(cadence, zone: zone, after: last, through: now, limit: missedLimit + 1)
        guard let newest = found.first else { return Check(due: nil, missed: [], late: false) }
        if now.timeIntervalSince(newest) < catchUpWindow {
            return Check(due: newest, missed: Array(found.dropFirst().prefix(missedLimit)),
                         late: now.timeIntervalSince(newest) >= lateAfter)
        }
        return Check(due: nil, missed: Array(found.prefix(missedLimit)), late: false)
    }

    /// The first slot after `date`, for "next run". Nil for a cadence that isn't valid.
    public static func next(_ cadence: AutomationCadence, zone: TimeZone, after date: Date) -> Date? {
        guard cadence.isValid else { return nil }
        let calendar = Self.calendar(zone)
        var day = calendar.startOfDay(for: date)
        // A weekly slot is at most a week away, and a daylight-saving change moves a day's start by an hour at most.
        for _ in 0..<9 {
            if let slot = daySlots(cadence, on: day, calendar: calendar).first(where: { $0 > date }) { return slot }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: following)
        }
        return nil
    }

    /// The slots in (`after`, `through`], newest first, at most `limit`.
    public static func slots(_ cadence: AutomationCadence, zone: TimeZone, after: Date, through: Date, limit: Int) -> [Date] {
        guard through > after else { return [] }
        let calendar = Self.calendar(zone)
        var found: [Date] = []
        var day = calendar.startOfDay(for: through)
        let floor = calendar.startOfDay(for: after)
        // Walking back a day at a time stops at the day of the last slot, or when enough are found. A weekly cadence with a year of silence
        // is a few hundred steps, and the bound keeps a corrupt date from walking for ever.
        var steps = 0
        while day >= floor, found.count < limit, steps < 800 {
            for slot in daySlots(cadence, on: day, calendar: calendar).reversed() where slot <= through && slot > after {
                found.append(slot)
                if found.count == limit { break }
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = calendar.startOfDay(for: previous)
            steps += 1
        }
        return found
    }

    private static func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The slots on the local day that starts at `day`, oldest first. A wall-clock time that day lacks (the hour a clock skips) moves to the next
    /// valid time for a fixed time of day and is left out for a step; a time it has twice (the hour a clock repeats) is the first one.
    static func daySlots(_ cadence: AutomationCadence, on day: Date, calendar: Calendar) -> [Date] {
        let weekday = calendar.component(.weekday, from: day)
        let times: [(hour: Int, minute: Int)]
        switch cadence {
        case .minutes(let n): times = (0..<24).flatMap { h in stride(from: 0, to: 60, by: n).map { (h, $0) } }
        case .hours(let n): times = stride(from: 0, to: 24, by: n).map { ($0, 0) }
        case .daily(let h, let m): times = [(h, m)]
        case .weekdays(let h, let m): times = (2...6).contains(weekday) ? [(h, m)] : []
        case .weekly(let d, let h, let m): times = weekday == d ? [(h, m)] : []
        }
        var slots: [Date] = []
        for time in times {
            guard let slot = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day,
                                           matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
            let parts = calendar.dateComponents([.hour, .minute], from: slot)
            if !cadence.shiftsOverGaps, parts.hour != time.hour || parts.minute != time.minute { continue }
            // Still the same local day: a shift never crosses midnight in practice, but a slot on the next day would be found twice.
            guard calendar.startOfDay(for: slot) == day else { continue }
            slots.append(slot)
        }
        return Array(Set(slots)).sorted()
    }
}
