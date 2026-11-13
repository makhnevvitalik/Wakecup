import Foundation

@main struct StopTimeTests {
    static func main() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
        let day = Date(timeIntervalSince1970: 1_794_309_600) // 2026-11-10 16:20 +05
        let expected = Date(timeIntervalSince1970: 1_794_317_400) // same date, 18:30 +05
        for value in ["18:30", "1830"] {
            try expect(StopTimeInput.date(from: value, on: day, calendar: calendar, final: false) == expected,
                       "Both supported time entry forms must choose the exact local time")
        }
        try expect(StopTimeInput.date(from: "18", on: day, calendar: calendar, final: false) == nil,
                   "A partial hour must remain a draft while typing")
        try expect(StopTimeInput.date(from: "18", on: day, calendar: calendar, final: true)
                   == Date(timeIntervalSince1970: 1_794_315_600), "Committing an hour must supply zero minutes")
        for invalid in ["", "24:00", "23:60", "-1:00", "abc", "99999"] {
            try expect(StopTimeInput.date(from: invalid, on: day, calendar: calendar, final: true) == nil,
                       "Invalid clock values must not become another time")
        }
        try expect(StopTimeInput.text(for: expected, calendar: calendar) == "18:30", "Time text must retain the chosen hour and minutes")
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = Date(timeIntervalSince1970: 1_772_985_600) // 2026-03-08 noon EDT
        try expect(StopTimeInput.date(from: "02:30", on: springDay, calendar: calendar, final: true) == nil,
                   "A nonexistent DST time must not silently shift the requested endpoint")
        let beforeClockChange = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23))!
        let expectedEnd = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        try expect(EndTimeSelection.endOfWindow(from: beforeClockChange, calendar: calendar) == expectedEnd,
                   "March 31 must remain the final selectable day across the DST change and month boundary")
        print("PASS: stop-time parsing, exact local endpoints and the calendar window across DST")
    }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "StopTimeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
