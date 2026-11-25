import Foundation

// A time is interpreted on the explicitly selected calendar day. It never
// silently rolls into tomorrow or normalizes an impossible local clock time.
enum StopTimeInput {
    static func clockTime(from text: String, final: Bool, hourCycle: Locale.HourCycle = .zeroToTwentyThree,
                          afternoon: Bool = false) -> EndTimeSelection.ClockTime? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 }) else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        let hours: Int?
        let minutes: Int?
        if parts.count == 2 {
            guard (1...2).contains(parts[0].count), parts[1].count == 2 else { return nil }
            hours = Int(parts[0]); minutes = Int(parts[1])
        } else if parts.count == 1, text.count == 4 {
            hours = Int(text.prefix(2)); minutes = Int(text.suffix(2))
        } else if final, parts.count == 1, (1...2).contains(text.count) {
            hours = Int(text); minutes = 0
        } else { return nil }
        guard let hours, let minutes else { return nil }
        let hour: Int
        switch hourCycle {
        case .oneToTwelve:
            guard (1...12).contains(hours) else { return nil }
            hour = hours % 12 + (afternoon ? 12 : 0)
        case .zeroToEleven:
            guard (0...11).contains(hours) else { return nil }
            hour = hours + (afternoon ? 12 : 0)
        case .oneToTwentyFour:
            guard (1...24).contains(hours) else { return nil }
            hour = hours % 24
        case .zeroToTwentyThree:
            hour = hours
        @unknown default:
            return nil
        }
        return EndTimeSelection.ClockTime(hour: hour, minute: minutes)
    }

    struct Clock {
        enum DateDetail: Equatable {
            case dayAndMonth
            case full
        }

        enum DayPresentation: Equatable {
            case today
            case tomorrow
            case date(DateDetail)
        }

        private static let dayAndMonthTemplate = "MMMd"

        let locale: Locale
        let calendar: Calendar
        let hourCycle: Locale.HourCycle
        let separator: String
        let periods: [String]
        let periodFirst: Bool
        private let paddedHour: Bool

        init(locale: Locale = .autoupdatingCurrent, calendar: Calendar = .autoupdatingCurrent) {
            var calendar = calendar
            calendar.locale = locale
            self.locale = locale
            self.calendar = calendar
            let formatter = Self.makeFormatter(locale: locale, calendar: calendar)
            formatter.timeStyle = .short
            let pattern = Self.patternParts(formatter.dateFormat ?? "")
            let hour = pattern.firstIndex { $0.symbol.map { "hHkK".contains($0) } ?? false }
            hourCycle = switch hour.flatMap({ pattern[$0].symbol }) {
            case "h": .oneToTwelve
            case "H": .zeroToTwentyThree
            case "k": .oneToTwentyFour
            case "K": .zeroToEleven
            default: locale.hourCycle
            }
            let dayPeriod = pattern.firstIndex { $0.symbol.map { "abB".contains($0) } ?? false }
            periodFirst = hour.map { hourIndex in dayPeriod.map { $0 < hourIndex } ?? false } ?? false
            paddedHour = if let hour, case .field(_, let count) = pattern[hour] { count > 1 } else { true }
            if let hour, let minute = pattern.firstIndex(where: { $0.symbol == "m" }),
               hour + 2 == minute, case .literal(let delimiter) = pattern[hour + 1],
               delimiter.contains(where: { $0.wholeNumberValue == nil }) {
                separator = delimiter
            } else {
                // The compact numeric editor needs an unambiguous delimiter.
                separator = ":"
            }
            periods = hourCycle == .oneToTwelve || hourCycle == .zeroToEleven
                ? [formatter.amSymbol, formatter.pmSymbol] : []
        }

        func tomorrow(from now: Date) -> Date? {
            calendar.dateInterval(of: .day, for: now)?.end
        }

        func dayPresentation(for date: Date, relativeTo now: Date) -> DayPresentation {
            if calendar.isDate(date, inSameDayAs: now) { return .today }
            if let tomorrow = tomorrow(from: now),
               calendar.isDate(date, inSameDayAs: tomorrow) { return .tomorrow }
            return .date(calendar.isDate(date, equalTo: now, toGranularity: .year) ? .dayAndMonth : .full)
        }

        func time(_ date: Date, dateDetail: DateDetail? = nil) -> String {
            let formatter = Self.makeFormatter(locale: locale, calendar: calendar)
            if dateDetail != nil { formatter.dateStyle = .medium }
            let fullDatePattern = dateDetail == .dayAndMonth ? formatter.dateFormat : nil
            formatter.timeStyle = .short

            if dateDetail == .dayAndMonth {
                // Shorten just the date and preserve the system's time style and date-time separator.
                guard let fullDatePattern, !fullDatePattern.isEmpty, let pattern = formatter.dateFormat,
                      let dateRange = pattern.range(of: fullDatePattern),
                      let compactDatePattern = DateFormatter.dateFormat(fromTemplate: Self.dayAndMonthTemplate,
                                                                        options: 0, locale: locale) else {
                    return "\(dateLabel(date, detail: .dayAndMonth)) \(time(date))"
                }
                formatter.dateFormat = pattern.replacingCharacters(in: dateRange, with: compactDatePattern)
            }
            return formatter.string(from: date)
        }

        func dateLabel(_ date: Date, detail: DateDetail) -> String {
            let formatter = Self.makeFormatter(locale: locale, calendar: calendar)
            switch detail {
            case .full: formatter.dateStyle = .medium
            case .dayAndMonth: formatter.setLocalizedDateFormatFromTemplate(Self.dayAndMonthTemplate)
            }
            return formatter.string(from: date)
        }

        func example(on day: Date) -> String {
            editorText(calendar.date(bySettingHour: 18, minute: 30, second: 0, of: day) ?? day)
        }

        func editorText(_ date: Date) -> String {
            editorText(EndTimeSelection.ClockTime(date, calendar: calendar))
        }

        func editorText(_ time: EndTimeSelection.ClockTime) -> String {
            let hour = time.hour
            let clockHour: Int
            switch hourCycle {
            case .oneToTwelve: clockHour = (hour + 11) % 12 + 1
            case .zeroToEleven: clockHour = hour % 12
            case .oneToTwentyFour: clockHour = (hour + 23) % 24 + 1
            default: clockHour = hour
            }
            return number(clockHour, padded: paddedHour) + separator + number(time.minute, padded: true)
        }

        func number(_ value: Int, padded: Bool) -> String {
            let formatter = NumberFormatter()
            formatter.locale = locale
            formatter.minimumIntegerDigits = padded ? 2 : 1
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        struct EditorInput {
            let digitsAndColon: String
            let separatorRange: Range<String.Index>?
        }

        // Parse the complete localized delimiter first. A bare colon is an
        // alternate input, even when the localized delimiter contains a colon.
        func input(_ text: String) -> EditorInput? {
            let delimiter = text.range(of: separator, options: .literal) ?? text.range(of: ":")
            var normalized = ""
            var index = text.startIndex
            while index < text.endIndex {
                if let delimiter, index == delimiter.lowerBound {
                    normalized.append(":")
                    index = delimiter.upperBound
                } else {
                    guard let digit = text[index].wholeNumberValue, (0...9).contains(digit) else { return nil }
                    normalized.append(String(digit))
                    text.formIndex(after: &index)
                }
            }
            return EditorInput(digitsAndColon: normalized, separatorRange: delimiter)
        }

        func steppedDate(from date: Date, on day: Date, increasing: Bool) -> Date? {
            if calendar.isDate(date, inSameDayAs: day) {
                return date.addingTimeInterval(increasing ? 60 : -60)
            }

            return steppedDate(from: EndTimeSelection.ClockTime(date, calendar: calendar), on: day, increasing: increasing)
        }

        func steppedDate(from time: EndTimeSelection.ClockTime, on day: Date, increasing: Bool) -> Date? {
            // Search wall-clock minutes on the selected day, including when a clock change skips midnight.
            let minute = time.hour * 60 + time.minute
            let boundary = increasing ? 24 * 60 : -1
            for candidate in stride(from: minute, to: boundary, by: increasing ? 1 : -1) {
                if let time = EndTimeSelection.ClockTime(hour: candidate / 60, minute: candidate % 60),
                   let date = time.date(on: day, calendar: calendar) {
                    return date
                }
            }
            return nil
        }

        func clockTime(from text: String, afternoon: Bool, final: Bool) -> EndTimeSelection.ClockTime? {
            guard let input = input(text) else { return nil }
            return StopTimeInput.clockTime(from: input.digitsAndColon, final: final, hourCycle: hourCycle, afternoon: afternoon)
        }

        private enum PatternPart {
            case field(Character, count: Int)
            case literal(String)

            var symbol: Character? {
                if case .field(let symbol, _) = self { return symbol }
                return nil
            }
        }

        // Unicode date patterns reserve unquoted ASCII letters for fields;
        // two successive apostrophes represent a single literal apostrophe.
        private static func patternParts(_ pattern: String) -> [PatternPart] {
            var parts: [PatternPart] = []
            var literal = ""
            var quoted = false
            var index = pattern.startIndex
            while index < pattern.endIndex {
                let character = pattern[index]
                pattern.formIndex(after: &index)
                if character == "'" {
                    if index < pattern.endIndex, pattern[index] == "'" {
                        literal.append("'")
                        pattern.formIndex(after: &index)
                    } else {
                        quoted.toggle()
                    }
                } else if !quoted && character.isASCII && character.isLetter {
                    if !literal.isEmpty {
                        parts.append(.literal(literal))
                        literal = ""
                    }
                    var count = 1
                    while index < pattern.endIndex, pattern[index] == character {
                        count += 1
                        pattern.formIndex(after: &index)
                    }
                    parts.append(.field(character, count: count))
                } else {
                    literal.append(character)
                }
            }
            if !literal.isEmpty { parts.append(.literal(literal)) }
            return parts
        }

        private static func makeFormatter(locale: Locale, calendar: Calendar) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            return formatter
        }
    }
}
