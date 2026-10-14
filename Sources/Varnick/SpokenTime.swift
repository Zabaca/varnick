import Foundation

/// Time in a spoken request (listening-never-answers, option 07): the words that name a window on the Mac's calendar, and how a
/// row's time is said to the judge and the writer. Foundation only, with the clock and the calendar passed in, so each is a seam for
/// a first test once there is a test target. Nothing here is sent anywhere: a window is worked out on this Mac.
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

    /// The words that name a weekday, lowercased: they leave the search words (`SpokenText.queryWords`).
    static let weekdayWords = Set(weekdays)

    /// A stretch of the Mac's calendar a request names.
    struct Window: Equatable {
        var interval: DateInterval
        /// How the row's "when" names it: "this morning", "Monday evening", "last week".
        var label: String
        /// How "I found no sessions …" names it: the label, with "on" before a weekday.
        var spoken: String
        /// A part of a day, a day or a week: all the log says of it.
        var kind: String
    }

    /// The window the request's time words name at `now`, or nil. The first time word decides. Vague words ("recently", "earlier",
    /// "lately") name none, and nor does a part of a day with no day ("in the morning").
    ///
    /// - "today", "this morning", "this afternoon", "this evening", "tonight"
    /// - "yesterday", with a part of a day after it
    /// - "last night": 5 PM yesterday to 5 AM today
    /// - "this week", "last week": a week starts on the calendar's first weekday, and this week runs to the end of today
    /// - a weekday, meaning the latest one before today, with a part of a day after it
    static func window(in request: String, now: Date = Date(), calendar: Calendar = .current) -> Window? {
        let words = request.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        func hour(_ day: Date, _ hours: Int) -> Date { calendar.date(byAdding: .hour, value: hours, to: day) ?? day }
        func make(_ from: Date, _ to: Date, _ label: String, spoken: String? = nil, kind: String) -> Window {
            Window(interval: DateInterval(start: from, end: max(from, to)), label: label, spoken: spoken ?? label, kind: kind)
        }
        func part(of day: Date, _ name: String, label: String, spoken: String? = nil) -> Window? {
            guard let hours = parts.first(where: { $0.name == name })?.hours else { return nil }
            return make(hour(day, hours.lowerBound), hour(day, hours.upperBound), label, spoken: spoken, kind: "part of a day")
        }

        for (i, word) in words.enumerated() {
            let next = i + 1 < words.count ? words[i + 1] : nil
            let named = next.flatMap { name in parts.contains { $0.name == name } ? name : nil }
            switch word {
            case "this" where named != nil:
                return part(of: today, named!, label: "this \(named!)")
            case "tonight":
                return part(of: today, "evening", label: "tonight")
            case "today":
                return make(today, day(1), "today", kind: "a day")
            case "yesterday":
                if let named { return part(of: day(-1), named, label: "yesterday \(named)") }
                return make(day(-1), today, "yesterday", kind: "a day")
            case "last" where next == "night":
                return make(hour(day(-1), lastNightFrom), hour(today, lastNightTo), "last night", kind: "part of a day")
            case "this" where next == "week", "last" where next == "week":
                guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
                if word == "this" { return make(week.start, day(1), "this week", kind: "a week") }
                let before = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start) ?? week.start
                return make(before, week.start, "last week", kind: "a week")
            default:
                guard let index = weekdays.firstIndex(of: word) else { continue }
                // The latest one before today: today's own name means a week ago.
                let current = calendar.component(.weekday, from: now) - 1
                let back = (current - index + 7) % 7 == 0 ? 7 : (current - index + 7) % 7
                let name = word.capitalized
                if let named { return part(of: day(-back), named, label: "\(name) \(named)", spoken: "on \(name) \(named)") }
                return make(day(-back), day(-back + 1), name, spoken: "on \(name)", kind: "a day")
            }
        }
        return nil
    }

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
    static func today(now: Date = Date(), calendar: Calendar = .current) -> String {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return "\(dateName(now, calendar: calendar)); this week started \(dateName(start, calendar: calendar))"
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
