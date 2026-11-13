import Foundation

// Calendar choices share one strict composition policy. Impossible local clock
// times (for example during a daylight-saving jump) never roll to another time.
enum EndTimeSelection {
    static let daysAhead = 30
    static let minimumDurationSeconds = 10

    enum Issue: Equatable, LocalizedError {
        case incomplete, past, tooSoon, tooFar

        var errorDescription: String? { messageKey }
        var messageKey: String {
            switch self {
            case .incomplete: "Enter a time such as 18:30."
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
    static func date(hour: Int, minute: Int, on day: Date, calendar: Calendar) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0
        guard let date = calendar.date(from: components),
              calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute,
              calendar.isDate(date, inSameDayAs: day) else { return nil }
        return date
    }

    static func replacingDay(of date: Date, with day: Date, calendar: Calendar) -> Date? {
        self.date(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date),
                  on: day, calendar: calendar)
    }
}
