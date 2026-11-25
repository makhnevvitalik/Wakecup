import Foundation

// Calendar choices share one strict composition policy. Impossible local clock
// times (for example during a daylight-saving jump) never roll to another time.
enum EndTimeSelection {
    static let daysAhead = 30
    static let minimumDurationSeconds = 10

    enum Issue: Equatable, LocalizedError {
        case incomplete, nonexistentTime, past, tooSoon, tooFar

        var errorDescription: String? { messageKey }
        var messageKey: String {
            switch self {
            case .incomplete: "Enter a time such as 18:30."
            case .nonexistentTime: "This time does not exist on the selected day."
            case .past: "This time has already passed."
            case .tooSoon: "Choose a duration of at least 10 seconds."
            case .tooFar: "Choose an end date within the next 30 days."
            }
        }
    }

    static func issue(for date: Date, from now: Date) -> Issue? {
        let duration = date.timeIntervalSince(now)
        if duration <= 0 { return .past }
        if duration < Double(minimumDurationSeconds) { return .tooSoon }
        return date < endOfWindow(from: now) ? nil : .tooFar
    }

    static func validateDuration(_ seconds: Int) throws {
        guard seconds >= minimumDurationSeconds else { throw Issue.tooSoon }
    }

    struct ClockTime: Equatable {
        let hour: Int
        let minute: Int

        init?(hour: Int, minute: Int) {
            guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
            self.hour = hour
            self.minute = minute
        }

        init(_ date: Date, calendar: Calendar) {
            hour = calendar.component(.hour, from: date)
            minute = calendar.component(.minute, from: date)
        }

        func date(on day: Date, calendar: Calendar, from now: Date? = nil, preserving existing: Date? = nil) -> Date? {
            guard let first = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                            of: day, matchingPolicy: .strict, repeatedTimePolicy: .first),
                  calendar.isDate(first, inSameDayAs: day),
                  Self(first, calendar: calendar) == self else { return nil }

            let earliest = now?.addingTimeInterval(Double(EndTimeSelection.minimumDurationSeconds))
            if let existing, calendar.isDate(existing, inSameDayAs: day), Self(existing, calendar: calendar) == self,
               let existingMinute = calendar.dateInterval(of: .minute, for: existing)?.start,
               earliest.map({ existing >= $0 }) ?? true {
                return existingMinute
            }
            guard let earliest, first < earliest else { return first }
            return laterOccurrence(after: first, on: day, noEarlierThan: earliest, calendar: calendar) ?? first
        }

        private func laterOccurrence(after first: Date, on day: Date, noEarlierThan earliest: Date,
                                     calendar: Calendar) -> Date? {
            guard let dayEnd = calendar.dateInterval(of: .day, for: day)?.end else { return nil }
            let zone = calendar.timeZone
            let firstOffset = zone.secondsFromGMT(for: first)
            var cursor = first
            // Foundation can return the same instant for both repeated-time policies
            // during a partial-hour rollback. The zone offset gives the real separation.
            while let transition = zone.nextDaylightSavingTimeTransition(after: cursor),
                  transition > cursor, transition < dayEnd {
                let offsetChange = firstOffset - zone.secondsFromGMT(for: transition)
                let candidate = first.addingTimeInterval(Double(offsetChange))
                if candidate >= transition, candidate >= earliest, candidate < dayEnd,
                   Self(candidate, calendar: calendar) == self, calendar.component(.second, from: candidate) == 0 {
                    return candidate
                }
                cursor = transition
            }
            return nil
        }
    }

    enum ClockEdit {
        case resolved(Date)
        case nonexistent(ClockTime, on: Date)
        case incomplete
        case empty
    }

    static func firstSelectableMinute(from now: Date, calendar: Calendar) -> Date? {
        let earliest = now.addingTimeInterval(Double(minimumDurationSeconds))
        guard let minute = calendar.dateInterval(of: .minute, for: earliest) else { return nil }
        return minute.start == earliest ? earliest : minute.end
    }

    enum Preset: Int, Codable {
        case indefinitely = 0
        case oneHour = 60
        case threeHours = 180
        case fiveHours = 300

        var duration: TimeInterval? {
            self == .indefinitely ? nil : Double(rawValue) * 60
        }
    }

    enum Choice: Codable {
        case preset(Preset, date: Date?)
        case date(Date)
        case duration(seconds: Int)

        static let oneHour = Choice.preset(.oneHour, date: nil)

        func date(from now: Date) -> Date? {
            switch self {
            case .preset(let preset, let date):
                return date ?? preset.duration.map { now.addingTimeInterval($0) }
            case .date(let date):
                return date
            case .duration(let seconds):
                return now.addingTimeInterval(Double(seconds))
            }
        }

        func validatedDuration(from now: Date) throws -> TimeInterval? {
            guard let date = date(from: now) else { return nil }
            if let issue = EndTimeSelection.issue(for: date, from: now) { throw issue }
            return date.timeIntervalSince(now)
        }

        var hasFixedDate: Bool {
            switch self {
            case .preset(_, let date): date != nil
            case .date: true
            case .duration: false
            }
        }

        var forStorage: Self {
            if case .preset(let preset, _) = self { return .preset(preset, date: nil) }
            return self
        }
    }

    // The first instant after the last selectable local day.
    static func endOfWindow(from now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let nextDay = calendar.date(byAdding: .day, value: daysAhead + 1, to: today) ?? today
        return calendar.startOfDay(for: nextDay)
    }
}
