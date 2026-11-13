import Foundation

// Calendar choices share one strict composition policy. Impossible local clock
// times (for example during a daylight-saving jump) never roll to another time.
enum EndTimeSelection {
    static let daysAhead = 30

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

        static let oneHour = Choice.preset(.oneHour, date: nil)

        func date(from now: Date) -> Date? {
            switch self {
            case .preset(let preset, let date):
                return date ?? preset.duration.map { now.addingTimeInterval($0) }
            case .date(let date):
                return date
            }
        }

        var hasFixedDate: Bool {
            switch self {
            case .preset(_, let date): date != nil
            case .date: true
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
