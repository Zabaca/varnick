import Foundation

/// Time in a spoken request (option 07, ADR 0037): the labels of the times a request may ask about, built from the Mac's clock and
/// calendar for the route to choose among, the hours a chosen label means, and how a row's time is said. Foundation only.
enum SpokenTime {
    /// Parts of a day, in hours. A named part of the day is one of these; "last night" runs from `lastNightFrom` to `lastNightTo`.
    static let morning = 5..<12
    static let afternoon = 12..<17
    static let evening = 17..<24
    static let lastNightFrom = 17
    static let lastNightTo = 5

    private static let parts: [(name: String, hours: Range<Int>)] = [("morning", morning), ("afternoon", afternoon), ("evening", evening)]
    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                                 "November", "December"]

    /// How many days before yesterday, and after tomorrow's start, are named by weekday and date.
    static let namedDaysBack = 5
    static let namedDaysAhead = 6

    /// A stretch of the Mac's calendar a request asks about.
    struct Window: Equatable {
        var interval: DateInterval
        /// How the row's "when" names it: "this morning", "Monday evening", "last week".
        var label: String
        /// How "I found no sessions …" names it: the label, with "on" before a weekday.
        var spoken: String
        /// A part of a day, a day or a week: all the log says of it.
        var kind: String
        /// Still to come: no session was used then, so it never filters or boosts a session search.
        var future = false
    }

    /// One answer to the window question: an id Jev answers with, its description (the criterion Jev reads), and the window it means.
    struct Label: Equatable {
        var id: String
        var description: String
        var window: Window
    }

    /// The labels at `now`, past and present first, then the future, each described by its dates and hours so the model only has to
    /// match a request to one. A part of today that hasn't begun is a future label; one under way, like today and this week, runs to now.
    static func labels(now: Date = Date(), calendar: Calendar = .current) -> [Label] {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        // The hour on that day's own clock, so a day the clocks change in still starts its parts at 5, noon and 5; 24 is the next midnight.
        func hour(_ day: Date, _ hours: Int) -> Date {
            if hours >= 24 { return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) ?? day }
            return calendar.date(bySettingHour: hours, minute: 0, second: 0, of: day) ?? day
        }
        func clock(_ hours: Int) -> String { hours == 12 ? "noon" : hours >= 24 ? "midnight" : "\(hours % 12) \(hours < 12 ? "AM" : "PM")" }
        func slug(_ date: Date) -> String {
            let parts = calendar.dateComponents([.month, .day], from: date)
            return "\(weekdayName(date, calendar: calendar).lowercased())_\(months[(parts.month ?? 1) - 1].prefix(3).lowercased())\(parts.day ?? 1)"
        }
        func window(_ from: Date, _ to: Date, _ label: String, spoken: String? = nil, kind: String, future: Bool = false) -> Window {
            Window(interval: DateInterval(start: from, end: max(from, to)), label: label, spoken: spoken ?? label, kind: kind, future: future)
        }
        var labels: [Label] = []
        func add(_ id: String, _ description: String, _ window: Window) { labels.append(Label(id: id, description: description, window: window)) }

        // Past and present.
        let todayName = dateName(today, calendar: calendar)
        add("today", "Today, \(todayName), up to now", window(today, now, "today", kind: "a day"))
        var comingToday: [(name: String, hours: Range<Int>)] = []
        for part in parts {
            let (start, end) = (hour(today, part.hours.lowerBound), hour(today, part.hours.upperBound))
            if now >= start {
                let to = now < end ? "now" : clock(part.hours.upperBound)
                add("this_\(part.name)", "This \(part.name): \(todayName), \(clock(part.hours.lowerBound)) to \(to)",
                    window(start, min(end, now), "this \(part.name)", kind: "part of a day"))
            } else {
                comingToday.append(part)
            }
        }
        let yesterday = day(-1)
        let yesterdayName = dateName(yesterday, calendar: calendar)
        add("last_night", "Last night: \(yesterdayName), \(clock(lastNightFrom)) to \(clock(lastNightTo)) today",
            window(hour(yesterday, lastNightFrom), min(hour(today, lastNightTo), now), "last night", kind: "part of a day"))
        add("yesterday", "Yesterday: \(yesterdayName), the whole day", window(yesterday, today, "yesterday", kind: "a day"))
        for part in parts {
            add("yesterday_\(part.name)", "Yesterday \(part.name): \(yesterdayName), \(clock(part.hours.lowerBound)) to \(clock(part.hours.upperBound))",
                window(hour(yesterday, part.hours.lowerBound), hour(yesterday, part.hours.upperBound), "yesterday \(part.name)", kind: "part of a day"))
        }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        add("this_week", "This week: since \(dateName(week, calendar: calendar)), up to now", window(week, now, "this week", kind: "a week"))
        let before = calendar.date(byAdding: .weekOfYear, value: -1, to: week) ?? week
        add("last_week", "Last week: \(dateName(before, calendar: calendar)) to \(dateName(calendar.date(byAdding: .day, value: -1, to: week) ?? week, calendar: calendar))",
            window(before, week, "last week", kind: "a week"))
        for back in 2...(namedDaysBack + 1) {
            let date = day(-back)
            let name = weekdayName(date, calendar: calendar)
            let dated = dateName(date, calendar: calendar)
            let datePart = String(dated.drop { $0 != "," }.dropFirst(2))
            add(slug(date), "\(dated), the whole day", window(date, day(-back + 1), name, spoken: "on \(name)", kind: "a day"))
            for part in parts {
                add("\(slug(date))_\(part.name)", "\(name) \(part.name), \(datePart), \(clock(part.hours.lowerBound)) to \(clock(part.hours.upperBound))",
                    window(hour(date, part.hours.lowerBound), hour(date, part.hours.upperBound), "\(name) \(part.name)",
                           spoken: "on \(name) \(part.name)", kind: "part of a day"))
            }
        }

        // The future: no session was used then.
        add("later_today", "Later today: \(todayName), from now to midnight, still to come",
            window(now, hour(today, 24), "later today", kind: "part of a day", future: true))
        for part in comingToday {
            add("this_\(part.name)", "This \(part.name): \(todayName), \(clock(part.hours.lowerBound)) to \(clock(part.hours.upperBound)), still to come",
                window(hour(today, part.hours.lowerBound), hour(today, part.hours.upperBound), "this \(part.name)", kind: "part of a day", future: true))
        }
        let tomorrow = day(1)
        add("tomorrow", "Tomorrow: \(dateName(tomorrow, calendar: calendar))", window(tomorrow, day(2), "tomorrow", kind: "a day", future: true))
        for ahead in 1...namedDaysAhead {
            let date = day(ahead)
            let name = weekdayName(date, calendar: calendar)
            add(slug(date), "\(dateName(date, calendar: calendar)), still to come", window(date, day(ahead + 1), name, spoken: "on \(name)", kind: "a day", future: true))
        }
        return labels
    }

    /// What the window question's "none" says: no time, this very moment, a time somewhere else, or a vague one.
    static let noneDescription = "No time, this very moment (\"right now\"), a time somewhere else, or a vague one such as recently."

    // MARK: How a row's time is said

    /// "morning", "afternoon", "evening", or "night" between midnight and the morning.
    static func partOfDay(_ date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        return parts.first { $0.hours.contains(hour) }?.name ?? "night"
    }

    /// The weekday's name, in English like the rest of what Varnick says.
    static func weekdayName(_ date: Date, calendar: Calendar = .current) -> String {
        weekdays[calendar.component(.weekday, from: date) - 1].capitalized
    }

    /// "Wednesday, October 14".
    static func dateName(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return "\(weekdayName(date, calendar: calendar)), \(months[(parts.month ?? 1) - 1]) \(parts.day ?? 1)"
    }

    /// Today's date and where this week started, which the judge and the writer need for "this week": "Wednesday, October 14; this
    /// week started Sunday, October 11".
    /// The Mac's time in its own short format ("3:00 PM"); the narrow no-break space before AM and PM is not a pause worth keeping.
    static func shortTime(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        return formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// With `withTime`, the Mac's time follows the date ("Wednesday, October 14, 3:00 PM; …"), as the route call's state has it.
    static func today(now: Date = Date(), calendar: Calendar = .current, withTime: Bool = false, locale: Locale = .current) -> String {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        var date = dateName(now, calendar: calendar)
        if withTime { date += ", " + shortTime(now, locale: locale) }
        return "\(date); this week started \(dateName(start, calendar: calendar))"
    }

    /// How a row's time reads to the judge and the writer.
    /// - A session in the request's window: the window, then the day: "Monday evening, 2 days ago".
    /// - Anything else last used or visited in the past week: its weekday and part of the day, then the day: "Thursday evening, 5 days ago".
    /// - Older: "3 weeks ago", as before.
    /// A session first seen in the second eval had only "2 days ago" and was scored 0.33 for a request about Monday evening.
    static func when(_ date: Date, in window: Window? = nil, now: Date = Date(), calendar: Calendar = .current) -> String {
        let relative = SpokenText.words(for: date, now: now, calendar: calendar)
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        let named: String
        if let window {
            named = window.label
        } else if (0..<7).contains(days) {
            named = "\(weekdayName(date, calendar: calendar)) \(partOfDay(date, calendar: calendar))"
        } else {
            return relative
        }
        // "yesterday afternoon, yesterday" says it twice.
        return named.hasPrefix(relative) ? named : "\(named), \(relative)"
    }
}
