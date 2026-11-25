import Foundation

@main struct StopTimeTests {
    static func main() throws {
        if CommandLine.arguments.contains("--system-formats") {
            try testSystemFormats()
            return
        }
        if CommandLine.arguments.contains("--system-quoted-hour") {
            try testSystemEditorFormat(preview: "kl. 6:30 PM", editor: "6:30", usesAfternoon: true)
            return
        }
        if CommandLine.arguments.contains("--system-quoted-separator") {
            try testSystemEditorFormat(preview: "18 m'in 30", editor: "18 m'in 30", usesAfternoon: false)
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
        let day = Date(timeIntervalSince1970: 1_794_309_600) // 2026-11-10 16:20 +05
        let expected = Date(timeIntervalSince1970: 1_794_317_400) // same date, 18:30 +05
        for value in ["18:30", "1830"] {
            try expect(parsedDate(from: value, on: day, calendar: calendar, final: false) == expected,
                       "Both supported time entry forms must choose the exact local time")
        }
        try expect(parsedDate(from: "18", on: day, calendar: calendar, final: false) == nil,
                   "A partial hour must remain a draft while typing")
        try expect(parsedDate(from: "18", on: day, calendar: calendar, final: true)
                   == Date(timeIntervalSince1970: 1_794_315_600), "Committing an hour must supply zero minutes")
        for invalid in ["", "24:00", "23:60", "-1:00", "abc", "99999"] {
            try expect(parsedDate(from: invalid, on: day, calendar: calendar, final: true) == nil,
                       "Invalid clock values must not become another time")
        }
        let twelveHour = StopTimeInput.Clock(locale: Locale(identifier: "en-US-u-hc-h12"), calendar: calendar)
        let twentyFourHour = StopTimeInput.Clock(locale: Locale(identifier: "en-GB-u-hc-h23"), calendar: calendar)
        let midnight = calendar.startOfDay(for: day)
        let noon = midnight.addingTimeInterval(12 * 3600)
        try expect(twelveHour.time(expected).contains("6:30") && twelveHour.time(expected).contains("PM"),
                   "A system 12-hour clock must include the evening marker")
        let example = twelveHour.example(on: day)
        try expect(twelveHour.parsedDate(from: example, afternoon: true, on: day, final: true) == expected,
                   "The numeric input must accept the exact sample suggested by the editor")
        try expect(twelveHour.parsedDate(from: "12:00", afternoon: false, on: day, final: true) == midnight,
                   "12 AM must be midnight on the selected day")
        try expect(twelveHour.parsedDate(from: "12:00", afternoon: true, on: day, final: true) == noon,
                   "12 PM must be noon on the selected day")
        try expect(twelveHour.parsedDate(from: "06:30", afternoon: true, on: day, final: false) == expected,
                   "The period control must distinguish morning and evening")
        try expect(twentyFourHour.time(expected) == "18:30", "A system 24-hour clock must omit the period")
        let usOverride = StopTimeInput.Clock(locale: Locale(identifier: "en-US-u-hc-h23"), calendar: calendar)
        try expect(usOverride.time(expected) == "18:30", "A 24-hour override must beat the region's usual 12-hour clock")
        let finnish = StopTimeInput.Clock(locale: Locale(identifier: "fi_FI"), calendar: calendar)
        try expect(finnish.editorText(expected) == "18.30" &&
                   finnish.parsedDate(from: "18.30", afternoon: false, on: day, final: true) == expected,
                   "The editor must use and parse the regional time separator")
        let nextYear = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 18, minute: 30))!
        let usDate = twelveHour.time(nextYear, dateDetail: .full)
        let ukDate = twentyFourHour.time(nextYear, dateDetail: .full)
        try expect(usDate.hasPrefix("Jan") && ukDate.hasPrefix("3") && usDate.contains("2027") && ukDate.contains("2027"),
                   "Use the regional date order and keep the year when requested")
        try expect(!twentyFourHour.dateLabel(nextYear, detail: .dayAndMonth).contains("2027"),
                   "A compact date may omit the year")
        let compactDate = twelveHour.time(nextYear, dateDetail: .dayAndMonth)
        try expect(compactDate.hasPrefix("Jan 3") && compactDate.contains("6:30") &&
                   compactDate.hasSuffix("PM") && !compactDate.contains("2027"),
                   "A compact deadline must use the region's date-time format and 12-hour preference")
        try expect(twentyFourHour.dateLabel(nextYear, detail: .full).contains("2027"),
                   "The date picker must be able to show the year for an absolute date in another year")

        func localDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let april29 = localDate(2026, 4, 29)
        let april30 = localDate(2026, 4, 30)
        let may1 = localDate(2026, 5, 1)
        let dec30 = localDate(2026, 12, 30)
        let dec31 = localDate(2026, 12, 31, hour: 23)
        let jan1 = localDate(2027, 1, 1, hour: 0)
        let cases: [(Date, Date, StopTimeInput.Clock.DayPresentation)] = [
            (day, expected, .today),
            (april30, may1, .tomorrow),
            (dec31, jan1, .tomorrow),
            (april29, may1, .date(.dayAndMonth)),
            (localDate(2026, 4, 27), april29, .date(.dayAndMonth)),
            (dec30, jan1, .date(.full))
        ]
        for (start, end, presentation) in cases {
            try expect(twentyFourHour.dayPresentation(for: end, relativeTo: start) == presentation,
                       "Classify the deadline by system calendar days, with tomorrow before month and year boundaries")
        }
        calendar.timeZone = TimeZone(identifier: "America/Nuuk")!
        let nuuk = StopTimeInput.Clock(locale: Locale(identifier: "kl_GL"), calendar: calendar)
        let beforeNuukJump = localDate(2027, 3, 26, hour: 23)
        try expect(nuuk.dayPresentation(for: localDate(2027, 3, 27), relativeTo: beforeNuukJump) == .tomorrow,
                   "Tomorrow must still be March 27 when tomorrow's 23:00 is skipped")
        try expect(nuuk.dayPresentation(for: localDate(2027, 3, 28), relativeTo: beforeNuukJump) == .date(.dayAndMonth),
                   "A DST jump must not label the day after tomorrow as tomorrow")

        let nuukJumpDay = localDate(2027, 3, 27)
        let missingFinalMinute = EndTimeSelection.ClockTime(hour: 23, minute: 30)!
        let lastNuukMinute = calendar.date(from: DateComponents(year: 2027, month: 3, day: 27, hour: 22, minute: 59))!
        try expect(nuuk.steppedDate(from: missingFinalMinute, on: nuukJumpDay, increasing: false) == lastNuukMinute,
                   "Down from a skipped final hour must find the last real minute on the selected day")
        try expect(nuuk.steppedDate(from: missingFinalMinute, on: nuukJumpDay, increasing: true) == nil,
                   "Up from a skipped final hour must not leave the selected day")

        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = Date(timeIntervalSince1970: 1_772_985_600) // 2026-03-08 noon EDT
        try expect(parsedDate(from: "02:30", on: springDay, calendar: calendar, final: true) == nil,
                   "A nonexistent DST time must not silently shift the requested endpoint")
        let previousDayClock = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30))!
        let gapClock = StopTimeInput.Clock(locale: Locale(identifier: "en-US"), calendar: calendar)
        let nextTime = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 3))!
        let previousTime = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 1, minute: 59))!
        try expect(gapClock.steppedDate(from: previousDayClock, on: springDay, increasing: true) == nextTime
            && gapClock.steppedDate(from: previousDayClock, on: springDay, increasing: false) == previousTime,
            "Stepping out of a DST gap must find a real minute on the selected day")
        var halfHourCalendar = Calendar(identifier: .gregorian)
        halfHourCalendar.timeZone = TimeZone(identifier: "Australia/Lord_Howe")!
        let lordHowe = StopTimeInput.Clock(locale: Locale(identifier: "en-AU"), calendar: halfHourCalendar)
        let halfHourGap = halfHourCalendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        let missingQuarter = EndTimeSelection.ClockTime(hour: 2, minute: 15)!
        let beforeHalfHourGap = halfHourCalendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 1, minute: 59))!
        let afterHalfHourGap = halfHourCalendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 2, minute: 30))!
        try expect(lordHowe.steppedDate(from: missingQuarter, on: halfHourGap, increasing: false) == beforeHalfHourGap
            && lordHowe.steppedDate(from: missingQuarter, on: halfHourGap, increasing: true) == afterHalfHourGap,
            "A non-hour clock change must find the neighboring real minutes on the selected day")

        let halfHourFold = halfHourCalendar.date(from: DateComponents(year: 2026, month: 4, day: 5))!
        let repeated = EndTimeSelection.ClockTime(hour: 1, minute: 45)!
        let firstOccurrence = halfHourFold.addingTimeInterval(105 * 60)
        try expect(repeated.date(on: halfHourFold, calendar: halfHourCalendar, from: halfHourFold) == firstOccurrence,
                   "Use the first occurrence when both are valid")
        try expect(repeated.date(on: halfHourFold, calendar: halfHourCalendar, from: firstOccurrence.addingTimeInterval(600))
                   == firstOccurrence.addingTimeInterval(30 * 60),
                   "Find the second occurrence even if the rollback is only thirty minutes")
        let beforeClockChange = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 23))!
        let expectedEnd = calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!
        try expect(EndTimeSelection.endOfWindow(from: beforeClockChange, calendar: calendar) == expectedEnd,
                   "March 31 must remain the final selectable day across the DST change and month boundary")
        print("PASS: stop-time parsing, exact local endpoints and the calendar window across DST")
    }
    private static func testSystemFormats() throws {
        // test.sh supplies these date and time styles only to this process.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 18, minute: 30))!
        let clock = StopTimeInput.Clock(calendar: calendar)

        try expect(clock.time(date) == "18-30", "The fixture must apply the system's custom short time style")
        try expect(clock.editorText(date) == "18-30" && clock.periods.isEmpty &&
                   clock.parsedDate(from: "18-30", afternoon: false, on: date, final: true) == date,
                   "The editor must display and accept the same system clock and separator")
        try expect(clock.time(date, dateDetail: .full) == "2027/01/03 at 18-30",
                   "A complete deadline must use the system's custom date and time styles")
        try expect(clock.dateLabel(date, detail: .full) == "2027/01/03",
                   "The complete picker date must use the system's custom date style")
        try expect(clock.time(date, dateDetail: .dayAndMonth) == "Jan 3 at 18-30",
                   "A compact deadline must show the month without the year and keep the system time style")
        print("PASS: complete and compact deadlines respect system date and time styles")
    }

    private static func testSystemEditorFormat(preview: String, editor: String, usesAfternoon: Bool) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 18, minute: 30))!
        let clock = StopTimeInput.Clock(calendar: calendar)
        try expect(clock.time(date) == preview, "The fixture must apply the process's custom macOS time style")
        try expect(clock.editorText(date) == editor && clock.periods.count == (usesAfternoon ? 2 : 0),
                   "Quoted text must not change the hour cycle, separate period control or editor delimiter")
        try expect(clock.parsedDate(from: editor, afternoon: usesAfternoon, on: date, final: true) == date,
                   "The value shown by the editor must round-trip to the same minute")
        if usesAfternoon {
            try expect(clock.parsedDate(from: editor, afternoon: false, on: date, final: true) == date.addingTimeInterval(-12 * 3600)
                       && !clock.periodFirst, "The editor must distinguish 6:30 AM from 6:30 PM")
        }
        print("PASS: system time format with quoted text and exact editor round-trip")
    }

    private static func parsedDate(from text: String, on day: Date, calendar: Calendar, final: Bool) -> Date? {
        StopTimeInput.clockTime(from: text, final: final)?.date(on: day, calendar: calendar)
    }

    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "StopTimeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}


private extension StopTimeInput.Clock {
    func parsedDate(from text: String, afternoon: Bool, on day: Date, final: Bool) -> Date? {
        clockTime(from: text, afternoon: afternoon, final: final)?.date(on: day, calendar: calendar)
    }
}
