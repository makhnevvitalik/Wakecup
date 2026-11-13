import Foundation

// A time is interpreted on the explicitly selected calendar day. It never
// silently rolls into tomorrow or normalizes an impossible local clock time.
enum StopTimeInput {
    static func date(from text: String, on day: Date, calendar: Calendar, final: Bool) -> Date? {
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
        return EndTimeSelection.date(hour: hours, minute: minutes, on: day, calendar: calendar)
    }

    static func text(for date: Date, calendar: Calendar) -> String {
        String(format: "%02d:%02d", calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}
