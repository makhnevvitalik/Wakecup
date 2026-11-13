import Foundation

@main struct EndTimeModelTests {
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() throws {
        let suite = "WakecupEndTime-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "closedLid")
        defaults.set(0, forKey: "preset")
        defaults.set(45, forKey: "customMinutes")
        defaults.set(true, forKey: "keepDisplayOn")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        var time = 1_000.0
        let base = Date(timeIntervalSince1970: 1_794_309_600)
        var sessions: [SessionConfiguration] = []
        var operations = SessionOperations(now: { time }, readPower: { .init(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { config in
                sessions.append(config)
                return try SessionFiles.create(at: directory.appendingPathComponent(config.id), configuration: config)
            }, guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
            usesInstalledHelper: { false }, startHelper: { _, _, _ in },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        var wallAdvance = 0.0
        var wallStep = 0.0
        operations.wallNow = {
            let value = base.addingTimeInterval(time - 1_000 + wallAdvance)
            wallAdvance += wallStep
            return value
        }
        operations.readLidClosed = { false }
        let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) },
            requestInformation: { _ in }, interaction: .inert)
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        try expect(try model.selectedDuration() == 3_600 && model.displayMode == .mayTurnOff,
                   "Obsolete duration and display preferences must not influence the current defaults")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
        let morning = Calendar.current.startOfDay(for: base).addingTimeInterval(60)
        let dayAfterLimit = EndTimeSelection.endOfWindow(from: morning)
        let lastMinuteOfLimit = dayAfterLimit.addingTimeInterval(-60)
        wallAdvance = morning.timeIntervalSince(base)
        model.selectEndDate(lastMinuteOfLimit)
        model.selectEndDate(dayAfterLimit)
        try expect(model.endTimeIssue == .tooFar, "An invalid draft must remain visible for correction")
        wallAdvance += 12 * 3_600
        let reopenedDate = SessionModel(defaults: defaults, operations: operations, helper: helper)
        try expect(reopenedDate.selectedEndDate == lastMinuteOfLimit && reopenedDate.durationInputIsValid,
                   "Reopening later must keep the last valid exact date, despite a newer invalid draft")
        wallAdvance = dayAfterLimit.timeIntervalSince(base)
        let expiredDate = SessionModel(defaults: defaults, operations: operations, helper: helper)
        try expect(try expiredDate.selectedDuration() == 3_600 && expiredDate.durationInputIsValid,
                   "An expired saved date must restore a usable one-hour default")
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
        wallAdvance = evening.timeIntervalSince(base)
        model.selectEndTimePreset(0)
        try expect(calendar.isDate(model.selectedEndDay, inSameDayAs: evening), "Infinity must provide today as the day for new clock input")
        model.selectEndDay(evening, calendar: calendar)
        try expect(model.selectedEndDate.map { calendar.isDate($0, inSameDayAs: evening) && $0 > evening } == true
            && model.durationInputIsValid, "Choosing Today from infinity before midnight must offer a future time today")
        model.selectEndTimePreset(0)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: evening)!
        model.selectEndDay(tomorrow, calendar: calendar)
        try expect(calendar.isDate(model.selectedEndDate!, inSameDayAs: tomorrow), "The model must preserve an explicitly selected day")
        wallAdvance = 0
        let presetDefaults = SessionModel(defaults: defaults, operations: operations, helper: helper)
        presetDefaults.selectEndTimePreset(60)
        let restoredPreset = SessionModel(defaults: defaults, operations: operations, helper: helper)
        let initialDefault = restoredPreset.selectedEndDate!
        time = 1_060; model.tick()
        try expect(restoredPreset.selectedEndDate == initialDefault.addingTimeInterval(60), "An untouched saved duration must remain usable while the app waits in the menu bar")
        time = 1_000
        model.selectEndTimePreset(180)
        try expect(model.selectedEndDate == base.addingTimeInterval(10_800), "A quick choice must fill a concrete end time")
        time = 1_015; model.tick()
        try expect(model.selectedEndDate == base.addingTimeInterval(10_800), "Waiting before Start must not move the selected endpoint")
        model.start()
        try expect(model.phase == .active && model.deadline == 11_800 && sessions.isEmpty,
                   "The start request must pin the end time, including authorization waits")
        let exactEnd = base.addingTimeInterval(1_823.5)
        model.selectEndDate(exactEnd)
        model.applySettingsDraft()
        let exactDeadline = model.deadline
        let selectedDay = calendar.startOfDay(for: exactEnd)
        model.selectEndDay(selectedDay, calendar: calendar)
        try expect(!model.showsSettingsActions && model.selectedEndDate == exactEnd && model.deadline == exactDeadline,
                   "Reselecting the current day must preserve seconds and leave no draft")
        let nextDay = calendar.date(byAdding: .day, value: 1, to: selectedDay)!
        model.selectEndDay(nextDay, calendar: calendar)
        try expect(model.showsSettingsActions && calendar.isDate(model.selectedEndDate!, inSameDayAs: nextDay),
                   "Selecting another day must still create a draft")
        model.editThreshold(35)
        let displayedEnd = calendar.dateInterval(of: .minute, for: exactEnd)!.start
        model.selectEndDate(displayedEnd)
        try expect(!model.durationEditDirty && model.selectedEndDate == exactEnd && model.deadline == exactDeadline
            && model.showsSettingsActions && model.selectedThreshold == 35,
            "Returning to the displayed time must preserve exact seconds and keep other edits")
        model.discardSettingsDraft()
        model.selectEndDate(displayedEnd.addingTimeInterval(60))
        model.selectEndDate(displayedEnd)
        try expect(!model.showsSettingsActions, "Reverting the only time edit must hide Apply and Cancel")
        model.selectEndDate(base.addingTimeInterval(10_800))
        model.applySettingsDraft()
        model.selectEndDate(base.addingTimeInterval(1_800))
        time = 1_030; model.tick()
        try expect(model.deadline == 11_800 && model.durationEditDirty && model.selectedEndDate == base.addingTimeInterval(1_800),
                   "Editing must retain the old running timer and the exact draft across ticks")
        model.discardSettingsDraft()
        try expect(model.deadline == 11_800 && !model.durationEditDirty && model.selectedEndDate == base.addingTimeInterval(10_800) && sessions.isEmpty,
                   "Cancel must restore the live end time without changing the deadline or restarting")
        model.selectEndDate(base.addingTimeInterval(1_800))
        model.applySettingsDraft()
        try expect(model.deadline == 2_800 && !model.durationEditDirty && sessions.isEmpty,
                   "Apply must use the absolute selected time without restarting the session")
        model.selectEndTimePreset(0); model.applySettingsDraft()
        try expect(model.deadline == nil && model.selectedEndDate == nil, "Infinity must clear the endpoint")
        model.selectEndDate(base.addingTimeInterval(1_900))
        model.setEndTimeInputInvalid(true)
        model.discardSettingsDraft()
        try expect(model.deadline == nil && model.selectedEndDate == nil && !model.durationEditDirty && !model.endTimeInputInvalid && model.durationInputIsValid,
                   "Cancel from an invalid finite draft must restore the active unlimited mode")
        model.selectEndDate(base.addingTimeInterval(1_900)); model.applySettingsDraft()
        try expect(model.deadline == 2_900 && sessions.isEmpty, "Typing a time must leave infinity in the same session")
        model.selectEndDate(model.currentDate.addingTimeInterval(2))
        wallStep = 1.25
        let snapshotDuration = try model.selectedDuration()
        try expect(snapshotDuration == 2, "Validation and conversion must use one clock snapshot near the end-time boundary")
        wallStep = 0; wallAdvance = 0
        model.selectEndDate(base.addingTimeInterval(-60))
        try expect(!model.durationInputIsValid && model.endTimeIssue == .past, "A past end time must report a passed clock time rather than the duration limit")
        model.applySettingsDraft()
        try expect(model.deadline == 2_900, "An invalid draft must retain the active deadline")
        let outsideWindow = EndTimeSelection.endOfWindow(from: model.currentDate)
        let lastMinute = outsideWindow.addingTimeInterval(-60)
        model.selectEndDate(lastMinute)
        try expect(model.durationInputIsValid, "23:59 on the thirtieth future day must be selectable")
        model.applySettingsDraft()
        let lastMinuteDeadline = model.deadline!
        model.selectEndDate(outsideWindow)
        model.applySettingsDraft()
        try expect(model.deadline == lastMinuteDeadline && !model.canApplySettingsDraft,
                   "An extension into the thirty-first day must retain the running timer")
        try expect(!model.durationInputIsValid && model.endTimeIssue == .tooFar,
                   "Manual input must reject midnight on the thirty-first day")
        model.setEndTimeInputInvalid(true)
        try expect(model.endTimeIssue == .incomplete, "An incomplete clock entry needs its own format feedback")
        model.selectEndTimePreset(0)
        try expect(model.durationInputIsValid && model.endTimeIssue == nil && model.selectedEndDate == nil, "Infinity must clear validation errors")
        model.applySettingsDraft()
        model.selectEndDate(base.addingTimeInterval(1_900))
        model.editClosedLid(true)
        model.applySettingsDraft()
        try expect(model.isRestarting && sessions.count == 1 && sessions.last!.absoluteDeadline == 2_900,
                   "One Apply must carry the finite deadline into the closed-lid restart")
        model.stop()
        print("PASS: fixed endpoint presets/start, live drafts/Apply, infinity, past and excessive dates, no session restarts")
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw NSError(domain: "EndTimeModelTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
