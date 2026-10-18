import Foundation

/// The structured result of parsing a quick-add line.
public struct QuickAddResult: Equatable, Sendable {
    public var title: String
    public var when: When?
    public var isEvening: Bool = false
    public var reminder: TimeOfDay?
    public var deadline: LocalDay?
    public var tags: [String] = []
    public var project: String?

    public init(title: String, when: When? = nil, isEvening: Bool = false, reminder: TimeOfDay? = nil,
                deadline: LocalDay? = nil, tags: [String] = [], project: String? = nil) {
        self.title = title
        self.when = when
        self.isEvening = isEvening
        self.reminder = reminder
        self.deadline = deadline
        self.tags = tags
        self.project = project
    }
}

/// Parses lines like `Call Sarah tomorrow at 10am #phone /Work !friday`.
///
/// - `#tag`, `#"multi word"` — tags
/// - `/Project`, `/"Home Reno"` — project or area
/// - `!<date>`, `by <date>`, `due <date>` — deadline
/// - a date phrase (`today`, `tonight`, `fri`, `next week`, `in 3 days`, `oct 20`, `someday`) — start
/// - `at 10am`, `9:30pm`, `noon` — reminder (implies today when no date is given)
public struct QuickAddParser: Sendable {
    public var today: LocalDay

    public init(today: LocalDay) {
        self.today = today
    }

    public func parse(_ text: String) -> QuickAddResult {
        let tokens = Self.tokenize(text)
        var result = QuickAddResult(title: "")
        var titleWords: [String] = []
        var i = 0

        while i < tokens.count {
            let token = tokens[i]
            let word = Self.normalize(token)

            if token.count > 1, token.hasPrefix("#") {
                let (name, used) = Self.quotedName(tokens, from: i)
                result.tags.append(name)
                i += used
                continue
            }
            if token.count > 1, token.hasPrefix("/"), result.project == nil {
                let (name, used) = Self.quotedName(tokens, from: i)
                result.project = name
                i += used
                continue
            }
            if token.count > 1, token.hasPrefix("!"), result.deadline == nil {
                var words = tokens.map(Self.normalize)
                words[i] = String(words[i].dropFirst())
                if let (match, used) = matchDate(words, at: i), case .day(let day, _) = match {
                    result.deadline = day
                    i += used
                    continue
                }
            }
            if (word == "by" || word == "due"), result.deadline == nil,
               let (match, used) = matchDate(tokens.map(Self.normalize), at: i + 1), case .day(let day, _) = match {
                result.deadline = day
                i += 1 + used
                continue
            }
            if result.reminder == nil, let (time, used) = matchTime(tokens.map(Self.normalize), at: i) {
                result.reminder = time
                i += used
                continue
            }
            if result.when == nil {
                let words = tokens.map(Self.normalize)
                let start = (word == "on" && i + 1 < tokens.count) ? i + 1 : i
                if let (match, used) = matchDate(words, at: start) {
                    switch match {
                    case .day(let day, let evening):
                        result.when = .on(day)
                        result.isEvening = evening
                    case .bucket(let bucket):
                        result.when = bucket
                    }
                    i = start + used
                    continue
                }
            }
            titleWords.append(token)
            i += 1
        }

        result.title = titleWords.joined(separator: " ")
        if result.title.isEmpty {
            // Nothing left to call it; keep the user's words rather than an empty to-do.
            return QuickAddResult(title: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.reminder != nil && result.when == nil {
            result.when = .on(today)
        }
        if let reminder = result.reminder, reminder.hour >= 18, result.when == .on(today) {
            result.isEvening = true
        }
        return result
    }

    // MARK: - Dates

    enum DateMatch: Equatable {
        case day(LocalDay, evening: Bool)
        case bucket(When)
    }

    /// Matches the longest date phrase starting at `i`; returns it and the number of words used.
    func matchDate(_ w: [String], at i: Int) -> (DateMatch, Int)? {
        guard i < w.count else { return nil }
        let word = w[i]
        let nextWord = i + 1 < w.count ? w[i + 1] : nil

        switch word {
        case "today", "tod": return (.day(today, evening: false), 1)
        case "tonight": return (.day(today, evening: true), 1)
        case "tomorrow", "tmr", "tmrw": return (.day(today.adding(days: 1), evening: false), 1)
        case "someday": return (.bucket(.someday), 1)
        case "anytime": return (.bucket(.anytime), 1)
        case "weekend": return (.day(weekend(), evening: false), 1)
        default: break
        }

        if let weekday = Self.weekday(word) {
            return (.day(today.next(weekday), evening: false), 1)
        }

        if word == "this", let nextWord {
            if nextWord == "evening" { return (.day(today, evening: true), 2) }
            if nextWord == "weekend" { return (.day(weekend(), evening: false), 2) }
            if let weekday = Self.weekday(nextWord) { return (.day(today.next(weekday), evening: false), 2) }
        }

        if word == "next", let nextWord {
            let nextMonday = today.startOfWeek.adding(days: 7)
            if let weekday = Self.weekday(nextWord) {
                return (.day(nextMonday.adding(days: weekday.rawValue - 1), evening: false), 2)
            }
            switch nextWord {
            case "week": return (.day(nextMonday, evening: false), 2)
            case "weekend": return (.day(nextMonday.adding(days: 5), evening: false), 2)
            case "month":
                let first = LocalDay(year: today.year, month: today.month, day: 1).adding(months: 1)
                return (.day(first, evening: false), 2)
            default: break
            }
        }

        if word == "in", let nextWord, i + 2 < w.count {
            let amount = nextWord == "a" || nextWord == "an" ? 1 : Int(nextWord)
            if let amount, amount >= 0 {
                let unit = w[i + 2]
                if let day = offset(by: amount, unit: unit) { return (.day(day, evening: false), 3) }
            }
        }

        if let day = LocalDay(iso: word) {
            return (.day(day, evening: false), 1)
        }

        // "oct 20", "october 20th 2027"
        if let month = Self.month(word), let nextWord, let dayNumber = Self.dayOfMonth(nextWord) {
            let yearWord = i + 2 < w.count ? w[i + 2] : nil
            return monthDay(month: month, day: dayNumber, yearWord: yearWord, used: 2)
        }
        // "20 oct", "20th october 2027"
        if let dayNumber = Self.dayOfMonth(word), let nextWord, let month = Self.month(nextWord) {
            let yearWord = i + 2 < w.count ? w[i + 2] : nil
            return monthDay(month: month, day: dayNumber, yearWord: yearWord, used: 2)
        }
        return nil
    }

    private func weekend() -> LocalDay {
        today.weekday == .sunday ? today : today.next(.saturday)
    }

    private func offset(by amount: Int, unit: String) -> LocalDay? {
        switch unit {
        case "day", "days": return today.adding(days: amount)
        case "week", "weeks", "wk", "wks": return today.adding(days: 7 * amount)
        case "month", "months": return today.adding(months: amount)
        case "year", "years": return today.adding(years: amount)
        default: return nil
        }
    }

    private func monthDay(month: Int, day: Int, yearWord: String?, used: Int) -> (DateMatch, Int)? {
        if let yearWord, yearWord.count == 4, let year = Int(yearWord) {
            guard day <= LocalDay.daysIn(month: month, year: year) else { return nil }
            return (.day(LocalDay(year: year, month: month, day: day), evening: false), used + 1)
        }
        var year = today.year
        guard day <= LocalDay.daysIn(month: month, year: 2000) else { return nil }  // 2000 is a leap year
        if LocalDay(year: year, month: month, day: day) < today { year += 1 }
        return (.day(LocalDay(year: year, month: month, day: day), evening: false), used)
    }

    // MARK: - Times

    /// `at 10`, `at 10:30 pm`, `10am`, `9:30pm`, `21:00`, `noon`, `midnight`.
    func matchTime(_ w: [String], at i: Int) -> (TimeOfDay, Int)? {
        guard i < w.count else { return nil }
        if w[i] == "at", i + 1 < w.count {
            if let (time, used) = Self.time(w, at: i + 1, requireMarker: false) { return (time, used + 1) }
            return nil
        }
        return Self.time(w, at: i, requireMarker: true)
    }

    /// Parses a time expression. With `requireMarker`, a bare number like `10` is not a
    /// time (it needs am/pm or a colon), so titles like "Buy 10 eggs" stay intact.
    static func time(_ w: [String], at i: Int, requireMarker: Bool) -> (TimeOfDay, Int)? {
        let word = w[i]
        if word == "noon" { return (.noon, 1) }
        if word == "midnight" { return (.midnight, 1) }

        var body = word
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) && body.count > suffix.count {
            let stem = String(body.dropLast(suffix.count))
            if stem.last?.isNumber == true {
                body = stem
                meridiem = suffix.hasPrefix("a") ? "am" : "pm"
                break
            }
        }
        var used = 1
        if meridiem == nil, i + 1 < w.count, ["am", "pm"].contains(w[i + 1]) {
            meridiem = w[i + 1]
            used = 2
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              var hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1])! : 0
        if parts.count == 2 && parts[1].count != 2 { return nil }
        if requireMarker && meridiem == nil && parts.count == 1 { return nil }
        guard (0...59).contains(minute) else { return nil }

        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "pm" && hour != 12 { hour += 12 }
            if meridiem == "am" && hour == 12 { hour = 0 }
        } else {
            guard (0...23).contains(hour) else { return nil }
            // "at 3" almost always means the afternoon.
            if parts.count == 1 && (1...7).contains(hour) { hour += 12 }
        }
        return (TimeOfDay(hour: hour, minute: minute), used)
    }

    // MARK: - Tokens

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Lowercased, with trailing punctuation removed, for matching.
    static func normalize(_ token: String) -> String {
        var t = token.lowercased()
        while let last = t.last, ",.;".contains(last) { t.removeLast() }
        return t
    }

    /// Reads `#name`, `/name`, or a quoted `#"multi word"` starting at `i`.
    static func quotedName(_ tokens: [String], from i: Int) -> (String, Int) {
        let first = String(tokens[i].dropFirst())
        guard first.hasPrefix("\"") else { return (first, 1) }
        var words = [String(first.dropFirst())]
        var j = i
        while !(words.last ?? "").hasSuffix("\"") && j + 1 < tokens.count {
            j += 1
            words.append(tokens[j])
        }
        var name = words.joined(separator: " ")
        if name.hasSuffix("\"") { name.removeLast() }
        return (name, j - i + 1)
    }

    static func weekday(_ word: String) -> Weekday? {
        switch word {
        case "mon", "monday": return .monday
        case "tue", "tues", "tuesday": return .tuesday
        case "wed", "weds", "wednesday": return .wednesday
        case "thu", "thur", "thurs", "thursday": return .thursday
        case "fri", "friday": return .friday
        case "sat", "saturday": return .saturday
        case "sun", "sunday": return .sunday
        default: return nil
        }
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    static func month(_ word: String) -> Int? {
        guard word.count >= 3 else { return nil }
        let full = ["january", "february", "march", "april", "may", "june", "july",
                    "august", "september", "october", "november", "december"]
        if let index = full.firstIndex(of: word) { return index + 1 }
        if word == "sept" { return 9 }
        return months.firstIndex(of: word).map { $0 + 1 }
    }

    static func dayOfMonth(_ word: String) -> Int? {
        var digits = word
        for suffix in ["st", "nd", "rd", "th"] where digits.hasSuffix(suffix) {
            digits.removeLast(2)
            break
        }
        guard digits.count <= 2, let n = Int(digits), (1...31).contains(n) else { return nil }
        return n
    }
}
