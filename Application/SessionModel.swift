import Foundation
import ServiceManagement
import Combine

final class SessionModel: ObservableObject {
    @Published var phase: AppSessionPhase = .idle
    @Published var message: SessionMessage?
    @Published var now: TimeInterval
    @Published var power: PowerState?
    @Published private(set) var closedLid = true { didSet { saveOptions() } }
    let display: DisplayModeController
    var displayMode: DisplayMode { display.mode }
    @Published private(set) var displayModeDraft: DisplayMode?
    var displayShortcut: DisplayShortcut? { display.shortcut }
    var isBacklightOff: Bool { display.isBacklightOff }
    var keepDisplayOn: Bool { display.mode.keepsDisplayOn }
    var displayControlError: SessionMessage? { display.error }
    var backlightCountdown: Int? {
        guard phase == .active, !isRestarting, !settingsApplying, settingsMessage == nil else { return nil }
        return display.countdownSeconds(at: operations.now())
    }
    private var editingDisplayShortcut = false
    var canChangeDisplayMode: Bool { canEditSessionSettings && !settingsApplying && !display.transitioning }
    var canChangeDisplayShortcut: Bool { canChangeDisplayMode && !isBacklightOff }

    @Published private var endTimeChoice: EndTimeSelection.Choice = .oneHour
    @Published private(set) var endTimeInputInvalid = false
    @Published private(set) var durationEditDirty = false
    @Published private(set) var settingsApplying = false
    @Published private var powerDraft: PowerDraft?
    @Published private var closedLidDraft: Bool?
    var selectedClosedLid: Bool { closedLidDraft ?? closedLid }
    var selectedAllowBattery: Bool { powerDraft?.allowBattery ?? allowBattery }
    var selectedThreshold: Double { powerDraft?.threshold ?? threshold }
    var hasSettingsDraft: Bool {
        durationEditDirty || displayModeDraft != nil || powerDraft != nil || closedLidDraft != nil
    }
    var showsSettingsActions: Bool { hasSettingsDraft && (phase == .active || isRestarting) }
    var canApplySettingsDraft: Bool {
        phase == .active && hasSettingsDraft && canEditSettingsDraft && durationInputIsValid && !display.transitioning
    }
    var canEditSettingsDraft: Bool { canEditSessionSettings && !settingsApplying }
    @Published private(set) var settingsMessage: SessionMessage?
    @Published private(set) var isRestarting = false
    @Published private(set) var allowBattery = true { didSet { saveOptions() } }
    @Published private(set) var threshold = 20.0 { didSet { saveOptions() } }
    @Published var showRemaining = true { didSet { saveOptions() } }
    @Published var showInMenuBar = true { didSet { saveOptions() } }
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var deadline: TimeInterval?

    let helper: PrivilegedHelperController
    private var helperObservation: AnyCancellable?
    private var displayObservation: AnyCancellable?
    private var usingInstalledHelper = false
    var waitingForPassword: Bool { phase == .authorizing && !usingInstalledHelper }
    var canSelectHelperMode: Bool { !phase.showsProgress && !isRestarting && !helper.working }
    var canEditSessionSettings: Bool { !phase.showsProgress && !isRestarting && !needsRecovery && !helper.working }
    var canChangeClosedLid: Bool { canEditSessionSettings && !settingsApplying && !display.transitioning }
    var canChangeHelper: Bool { !busy && canSelectHelperMode && !needsRecovery }

    private let defaults: UserDefaults
    private let operations: SessionOperations
    private var cancelTicks: (() -> Void)?
    private var files: SessionFiles?
    private var configuration: SessionConfiguration?
    private var monitor: SessionMonitor?
    private var control = SessionControl()
    private var authorization: SessionAuthorization?
    private var helperRequestID: UUID?
    private var recoveryStartedAt = 0.0
    private var statusReadFailedAt: TimeInterval?
    private var authorizationFinishedAt: TimeInterval?
    private var pendingError: SessionMessage?
    private static let displayChangeInterrupted: SessionMessage = "Wakecup stopped before the display setting could change."
    private static let restartExpired: SessionMessage = "The Wakecup timer ended. “Keep awake with lid closed” was not changed."
    private var recovering = false
    private var canPersist = false
    private var lastStatus: SessionStatus?
    private struct PowerDraft: Equatable {
        var allowBattery: Bool
        var threshold: Double
        var mode: PowerMode { allowBattery ? .battery : .ac }
    }
    private struct PendingSettings {
        let update: SessionLiveUpdate
        let sentAt: TimeInterval
        let duration: EndTimeSelection.Choice?
        let display: DisplayMode?
        let appliesPanelDraft: Bool
    }
    private struct RestartRequest {
        let previousClosedLid: Bool
        let deadline: TimeInterval?
        var power: PowerDraft? = nil
        var duration: EndTimeSelection.Choice? = nil
        var display: DisplayMode? = nil
        var appliesPanelDraft = false
    }
    private struct StartSettings {
        let closedLid: Bool
        let power: PowerDraft
        let endTime: EndTimeSelection.Choice?
        let display: DisplayMode
    }
    private var pendingStart: StartSettings?
    private var settingsResult: SessionOperationResult?
    var partialSettingsIssue: SessionMessage? {
        guard case .partiallyApplied(let issue) = settingsResult else { return nil }
        return issue
    }
    private var pendingSettings: PendingSettings?
    private var nextSettingsRevision: UInt64 = 0
    private var restartRequest: RestartRequest?
    private var guardianExitWaitSince: TimeInterval?
    var statusDidChange: (() -> Void)?
    var showRequested: (() -> Void)?
    var quitRequested: (() -> Void)?

    var busy: Bool { phase.isBusy || isRestarting }
    var startPowerRestriction: PowerRestriction? {
        guard !busy, !needsRecovery else { return nil }
        return powerRestriction(power, mode: allowBattery ? .battery : .ac, threshold: Int(threshold))
    }
    var remaining: Int? { deadline.map { max(0, Int(ceil($0 - now))) } }
    var endDate: Date? {
        deadline.map { operations.wallNow().addingTimeInterval($0 - operations.now()) }
    }

    var currentDate: Date { operations.wallNow() }
    var selectedEndDate: Date? {
        if phase == .active && !durationEditDirty { return endDate }
        return endTimeChoice.date(from: currentDate)
    }

    // Starting to type from infinity chooses today, even near midnight.
    var selectedEndDay: Date { selectedEndDate ?? currentDate }

    func selectEndDay(_ day: Date, calendar: Calendar) {
        guard canEditSettingsDraft else { return }
        let selectedDate = selectedEndDate
        if let selectedDate, calendar.isDate(selectedDate, inSameDayAs: day) { return }
        let now = currentDate
        var clock = selectedDate ?? now.addingTimeInterval(3600)
        if selectedDate == nil, calendar.isDate(day, inSameDayAs: now),
           let today = calendar.dateInterval(of: .day, for: now), clock >= today.end {
            clock = today.end.addingTimeInterval(-60)
        }
        if let date = EndTimeSelection.replacingDay(of: clock, with: day, calendar: calendar) { selectEndDate(date) }
        else { setEndTimeInputInvalid(true) }
    }

    func selectEndTimePreset(_ minutes: Int) {
        guard let preset = EndTimeSelection.Preset(rawValue: minutes) else { return }
        let date = preset.duration.map { currentDate.addingTimeInterval($0) }
        selectEndTime(.preset(preset, date: date))
    }

    func selectEndDate(_ date: Date) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        if date == selectedEndDate && !endTimeInputInvalid && !durationEditDirty { return }
        selectEndTime(.date(date))
    }

    private func selectEndTime(_ choice: EndTimeSelection.Choice) {
        guard canEditSettingsDraft else { return }
        settingsMessage = nil
        endTimeInputInvalid = false
        if phase == .active && matchesAppliedEndTime(choice) {
            durationEditDirty = false
            return
        }
        endTimeChoice = choice
        if phase == .active { durationEditDirty = true }
        else { saveEndTimeChoice(choice) }
    }

    private func matchesAppliedEndTime(_ choice: EndTimeSelection.Choice) -> Bool {
        switch choice {
        case .date(let date):
            guard let appliedDate = endDate else { return false }
            // The editor submits a minute boundary. Keep the exact running deadline
            // when the user restores the time shown in the field.
            return date == appliedDate || date == Calendar.current.dateInterval(of: .minute, for: appliedDate)?.start
        case .preset(.indefinitely, _):
            return deadline == nil
        case .preset, .duration:
            return false
        }
    }

    func setEndTimeInputInvalid(_ invalid: Bool) {
        guard canEditSettingsDraft else { return }
        if invalid != endTimeInputInvalid { settingsMessage = nil }
        if invalid && phase == .active {
            if !durationEditDirty {
                endTimeChoice = selectedEndDate.map(EndTimeSelection.Choice.date) ?? .preset(.indefinitely, date: nil)
            }
            durationEditDirty = true
        }
        endTimeInputInvalid = invalid
    }

    init(defaults: UserDefaults = .standard, operations: SessionOperations? = nil,
         helper: PrivilegedHelperController? = nil) {
        self.defaults = defaults
        let helper = helper ?? PrivilegedHelperController(defaults: defaults)
        self.helper = helper
        let operations = operations ?? .system(helper: helper)
        self.operations = operations
        display = DisplayModeController(defaults: defaults, operations: .init(
            assertions: operations.startAssertions, enter: operations.enterBacklight,
            restore: operations.restoreBacklight, validate: operations.validateDisplayShortcut,
            checkHealth: operations.checkBacklightHealth))
        now = operations.now()
        power = operations.readPower()
        restoreSavedEndTime()
        closedLid = defaults.object(forKey: "closedLid") as? Bool ?? true

        allowBattery = defaults.object(forKey: "allowBattery") as? Bool ?? true
        threshold = min(Double(BatteryThreshold.range.upperBound),
            max(Double(BatteryThreshold.range.lowerBound), defaults.object(forKey: "threshold") as? Double ?? 20))
        showRemaining = defaults.object(forKey: "showRemaining") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        helperObservation = helper.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        displayObservation = display.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshLoginState()
        canPersist = true
        inspectPreviousSession()
        cancelTicks = operations.scheduleTicks { [weak self] in self?.tick() }
    }

    deinit { cancelTicks?() }

    var endTimeIssue: EndTimeSelection.Issue? {
        if endTimeInputInvalid { return .incomplete }
        if phase == .active && !durationEditDirty { return nil }
        let now = currentDate
        return endTimeChoice.date(from: now).flatMap { EndTimeSelection.issue(for: $0, from: now) }
    }

    var durationInputIsValid: Bool { endTimeIssue == nil }

    func selectedDuration() throws -> TimeInterval? {
        guard !endTimeInputInvalid else { throw EndTimeSelection.Issue.incomplete }
        return try endTimeChoice.validatedDuration(from: currentDate)
    }

    private static let endTimeChoiceKey = "endTimeChoice"

    private func saveEndTimeChoice(_ choice: EndTimeSelection.Choice) {
        let now = currentDate
        if let date = choice.date(from: now), EndTimeSelection.issue(for: date, from: now) != nil { return }
        if let data = try? JSONEncoder().encode(choice.forStorage) {
            defaults.set(data, forKey: Self.endTimeChoiceKey)
        }
    }

    private func restoreSavedEndTime() {
        let choice = defaults.data(forKey: Self.endTimeChoiceKey)
            .flatMap { try? JSONDecoder().decode(EndTimeSelection.Choice.self, from: $0) } ?? .oneHour
        let now = currentDate
        if let date = choice.date(from: now), EndTimeSelection.issue(for: date, from: now) != nil {
            endTimeChoice = .oneHour
        } else {
            endTimeChoice = choice
        }
        endTimeInputInvalid = false
        durationEditDirty = false
    }

    private func saveOptions() {
        guard canPersist else { return }
        if !isRestarting { defaults.set(closedLid, forKey: "closedLid") }
        defaults.set(allowBattery, forKey: "allowBattery")
        defaults.set(threshold, forKey: "threshold")
        defaults.set(showRemaining, forKey: "showRemaining")
        defaults.set(showInMenuBar, forKey: "showInMenuBar")
        statusDidChange?()
    }

    func editClosedLid(_ enabled: Bool) {
        guard canChangeClosedLid, enabled != selectedClosedLid else { return }
        settingsMessage = nil
        if phase == .active { closedLidDraft = enabled == closedLid ? nil : enabled }
        else { closedLid = enabled }
    }

    private var currentPowerSettings: PowerDraft {
        PowerDraft(allowBattery: allowBattery, threshold: threshold)
    }

    func editAllowBattery(_ enabled: Bool) {
        guard canEditSettingsDraft, enabled != selectedAllowBattery else { return }
        settingsMessage = nil
        guard phase == .active else { allowBattery = enabled; return }
        var value = powerDraft ?? currentPowerSettings
        value.allowBattery = enabled
        powerDraft = value == currentPowerSettings ? nil : value
    }

    func editThreshold(_ threshold: Double) {
        guard canEditSettingsDraft else { return }
        guard Self.validThreshold(threshold) else {
            settingsMessage = "Choose a battery stop threshold between 10% and 90%."
            return
        }
        settingsMessage = nil
        guard threshold != selectedThreshold else { return }
        guard phase == .active else { self.threshold = threshold; return }
        var value = powerDraft ?? currentPowerSettings
        value.threshold = threshold
        powerDraft = value == currentPowerSettings ? nil : value
    }

    private static func validThreshold(_ value: Double) -> Bool {
        value.isFinite && value.rounded() == value
            && (Double(BatteryThreshold.range.lowerBound)...Double(BatteryThreshold.range.upperBound)).contains(value)
    }

    func discardSettingsDraft() {
        guard !settingsApplying, !isRestarting else { return }
        endTimeInputInvalid = false
        durationEditDirty = false
        discardDisplayModeDraft()
        powerDraft = nil
        closedLidDraft = nil
        settingsMessage = nil
        syncBacklightCountdown()
    }

    func applySettingsDraft() {
        guard canApplySettingsDraft else { return }
        defer { syncBacklightCountdown() }
        settingsResult = nil
        settingsMessage = nil
        let proposedDisplay = displayModeDraft
        let duration = durationEditDirty ? endTimeChoice : nil
        let targetDeadline: TimeInterval?
        if duration != nil {
            do { targetDeadline = try selectedDuration().map { operations.now() + $0 } }
            catch { settingsMessage = SessionMessage(reason: error.localizedDescription); return }
        } else {
            targetDeadline = deadline
        }
        _ = applySessionChanges(closedLid: closedLidDraft, power: powerDraft, deadline: targetDeadline,
                            duration: duration, display: proposedDisplay, appliesPanelDraft: true)
    }

    private func applySessionChanges(closedLid: Bool?, power: PowerDraft?, deadline targetDeadline: TimeInterval?,
                                     duration: EndTimeSelection.Choice?, display: DisplayMode?,
                                     appliesPanelDraft: Bool = false) -> SessionOperationResult {
        if let closedLid {
            let targetPower = power ?? currentPowerSettings
            // A restart must be able to start under the proposed power policy.
            let latestPower = operations.readPower()
            if let restriction = powerRestriction(latestPower, mode: targetPower.mode, threshold: Int(targetPower.threshold)) {
                return rejectSettings(SessionMessage(reason: restriction.reason))
            }
            return restartClosedLid(closedLid, request: RestartRequest(previousClosedLid: self.closedLid,
                deadline: targetDeadline, power: power, duration: duration, display: display, appliesPanelDraft: appliesPanelDraft))
        } else if power != nil || duration != nil {
            return submitSettings(power: power ?? currentPowerSettings, deadline: targetDeadline, duration: duration,
                                  display: display, appliesPanelDraft: appliesPanelDraft)
        } else if let display {
            return applySettingsDisplay(display, appliesPanelDraft: appliesPanelDraft)
        }
        return .completed
    }

    @discardableResult
    func applySettings(endTime: EndTimeSelection.Choice?, closedLid: Bool?, allowBattery: Bool?,
                                 threshold: Int?, displayMode: DisplayMode?, starting: Bool) throws -> SessionOperationResult {
        guard canEditSessionSettings, !settingsApplying, !display.transitioning, !starting || !busy else {
            throw WakecupError(message: "Wakecup is busy. Check its status and try again.")
        }
        let power = PowerDraft(allowBattery: allowBattery ?? self.allowBattery,
                              threshold: threshold.map(Double.init) ?? self.threshold)
        guard Self.validThreshold(power.threshold) else { throw WakecupError(message: "Battery threshold must be 10–90%.") }
        let targetMode = displayMode ?? self.displayMode
        if targetMode == .backlightOff && displayShortcut == nil {
            throw WakecupError(message: "Configure a restore brightness shortcut first.")
        }
        let nextLid = closedLid ?? self.closedLid
        if starting {
            return try start(with: StartSettings(closedLid: nextLid, power: power, endTime: endTime, display: targetMode))
        }
        let duration = try endTime?.validatedDuration(from: currentDate)
        settingsResult = nil
        settingsMessage = nil
        display.clearError()
        if phase == .active {
            let targetDeadline = endTime == nil ? deadline : duration.map { operations.now() + $0 }
            return applySessionChanges(closedLid: nextLid == self.closedLid ? nil : nextLid,
                power: power == currentPowerSettings ? nil : power,
                deadline: targetDeadline, duration: endTime,
                display: targetMode == self.displayMode ? nil : targetMode)
        } else {
            if let endTime {
                endTimeChoice = endTime
                saveEndTimeChoice(endTime)
            }
            if nextLid != self.closedLid { self.closedLid = nextLid }
            if power.allowBattery != self.allowBattery { self.allowBattery = power.allowBattery }
            if power.threshold != self.threshold { self.threshold = power.threshold }
            if targetMode != self.displayMode { return setDisplayMode(targetMode) }
            return .completed
        }
    }

    private static let settingsFailure: SessionMessage = "Could not apply settings. The current settings remain active."

    @discardableResult
    private func rejectSettings(_ issue: SessionMessage) -> SessionOperationResult {
        settingsMessage = issue
        let result = SessionOperationResult.rejected(issue)
        settingsResult = result
        return result
    }

    private func submitSettings(power: PowerDraft, deadline targetDeadline: TimeInterval?,
                                duration: EndTimeSelection.Choice?, display: DisplayMode?,
                                appliesPanelDraft: Bool) -> SessionOperationResult {
        guard phase == .active, pendingSettings == nil, let config = configuration,
              nextSettingsRevision < UInt64.max else { return rejectSettings(Self.settingsFailure) }
        let time = operations.now()
        guard deadline.map({ time < $0 }) ?? true else {
            tick()
            return rejectSettings(Self.settingsFailure)
        }
        let revision = nextSettingsRevision + 1
        let update = SessionLiveUpdate(revision: revision, powerMode: power.mode, threshold: Int(power.threshold), deadline: targetDeadline)
        var candidate = control
        candidate.update = update
        do {
            if config.closedLid {
                guard let files else { return rejectSettings(Self.settingsFailure) }
                try files.write(candidate, to: "control.json")
            }
            control = candidate
            nextSettingsRevision = revision
            pendingSettings = PendingSettings(update: update, sentAt: time, duration: duration,
                                              display: display, appliesPanelDraft: appliesPanelDraft)
            settingsApplying = true
            settingsResult = .pending()
            if !config.closedLid { tick() }
            return settingsResult ?? rejectSettings(Self.settingsFailure)
        } catch {
            return rejectSettings(Self.settingsFailure)
        }
    }

    private func reconcileSettings(_ status: SessionStatus) {
        guard let revision = status.settingsRevision, let mode = status.powerMode, let threshold = status.threshold,
              let pending = pendingSettings, revision >= pending.update.revision else { return }
        pendingSettings = nil
        settingsApplying = false
        let previousPower = currentPowerSettings
        allowBattery = mode == .battery
        self.threshold = Double(threshold)
        if let error = status.settingsError {
            rejectSettings(SessionMessage(reason: error))
        } else {
            settingsResult = .completed
            settingsMessage = nil
            reconcilePowerDraft(previous: previousPower, appliesPanelDraft: pending.appliesPanelDraft)
            if let choice = pending.duration {
                saveEndTimeChoice(choice)
                if pending.appliesPanelDraft { durationEditDirty = false }
            }
            saveOptions()
            if let mode = pending.display {
                if phase == .active, status.phase == "active" {
                    _ = applySettingsDisplay(mode, afterOtherChanges: true, appliesPanelDraft: pending.appliesPanelDraft)
                } else {
                    settingsResult = .partiallyApplied(Self.displayChangeInterrupted)
                }
            }
        }
    }

    private func reconcilePowerDraft(previous: PowerDraft, appliesPanelDraft: Bool) {
        guard let draft = powerDraft else { return }
        let rebased = PowerDraft(allowBattery: draft.allowBattery == previous.allowBattery ? allowBattery : draft.allowBattery,
                                 threshold: draft.threshold == previous.threshold ? threshold : draft.threshold)
        powerDraft = appliesPanelDraft || rebased == currentPowerSettings ? nil : rebased
    }

    private func restartClosedLid(_ enabled: Bool, request: RestartRequest) -> SessionOperationResult {
        guard canChangeClosedLid else { return rejectSettings(Self.settingsFailure) }
        guard operations.readLidClosed() == false else {
            return rejectSettings("Open the lid before changing closed-lid mode.")
        }
        if enabled {
            guard !(helper.selected && helper.checking) else {
                return rejectSettings("Wait for the check to finish.")
            }
            do {
                guard try !operations.readSleepDisabled() else {
                    return rejectSettings("Sleep is already disabled by a system setting. Wakecup will not change an existing setting.")
                }
            } catch { return rejectSettings(SessionMessage(reason: error.localizedDescription)) }
        }
        guard deadline.map({ operations.now() < $0 }) ?? true else {
            tick()
            return rejectSettings(Self.restartExpired)
        }
        settingsResult = .pending()
        restartRequest = request
        isRestarting = true
        guardianExitWaitSince = nil
        closedLid = enabled
        requestStop()
        let result = settingsResult ?? rejectSettings(Self.settingsFailure)
        if case .pending = result, waitingForPassword {
            return .pending("Confirm the macOS authorization prompt if it appears.")
        }
        return result
    }

    private func becameActive() {
        let start = pendingStart
        pendingStart = nil
        let restart = restartRequest
        let wasRestarting = isRestarting
        isRestarting = false
        restartRequest = nil
        guardianExitWaitSince = nil
        settingsMessage = nil
        if let start { closedLid = start.closedLid }
        let previousPower = currentPowerSettings
        if let power = start?.power ?? restart?.power {
            allowBattery = power.allowBattery
            threshold = power.threshold
        }
        if let choice = start?.endTime ?? restart?.duration {
            saveEndTimeChoice(choice)
            if start != nil || restart?.appliesPanelDraft == true || !durationEditDirty {
                endTimeChoice = choice
                durationEditDirty = false
            }
        }
        if closedLidDraft == closedLid || restart?.appliesPanelDraft == true { closedLidDraft = nil }
        reconcilePowerDraft(previous: previousPower, appliesPanelDraft: restart?.appliesPanelDraft == true)
        if let start, start.display != displayMode {
            display.setMode(start.display, running: true, now: operations.now(), assertionsAlreadyApplied: true)
        } else if let mode = restart?.display {
            _ = applySettingsDisplay(mode, afterOtherChanges: true, appliesPanelDraft: restart?.appliesPanelDraft == true)
        } else {
            if wasRestarting { settingsResult = .completed }
            display.activateIfConfigured(at: operations.now())
        }
        saveOptions()
        if !wasRestarting {
            endTimeInputInvalid = false
            durationEditDirty = false
        }
    }

    private func applySettingsDisplay(_ mode: DisplayMode, afterOtherChanges: Bool = false,
                                      appliesPanelDraft: Bool) -> SessionOperationResult {
        if appliesPanelDraft { discardDisplayModeDraft() }
        func outcome(_ result: SessionOperationResult) -> SessionOperationResult {
            if case .rejected(let issue) = result, afterOtherChanges { return .partiallyApplied(issue) }
            return result
        }
        let result = setDisplayMode(mode) { [weak self] result in
            guard let self, case .pending = self.settingsResult else { return }
            if case .completed = result, self.displayMode != mode {
                self.settingsResult = outcome(.rejected(Self.displayChangeInterrupted))
            } else {
                self.settingsResult = outcome(result)
            }
            if case .completed = result, self.displayModeDraft == self.displayMode { self.discardDisplayModeDraft() }
        }
        let recorded = outcome(result)
        settingsResult = recorded
        if case .completed = result, displayModeDraft == displayMode { discardDisplayModeDraft() }
        return recorded
    }

    @discardableResult
    private func setDisplayMode(_ mode: DisplayMode, completion: ((SessionOperationResult) -> Void)? = nil) -> SessionOperationResult {
        guard canChangeDisplayMode else { return .rejected(Self.settingsFailure) }
        let result = display.setMode(mode, running: phase == .active, now: operations.now(), completion: completion)
        statusDidChange?()
        return result
    }

    func selectDisplayMode(_ mode: DisplayMode) {
        guard canChangeDisplayMode, mode != (displayModeDraft ?? displayMode) else { return }
        settingsMessage = nil
        guard phase == .active else { setDisplayMode(mode); return }
        if mode == displayMode { discardDisplayModeDraft(); return }
        displayModeDraft = mode
        display.pauseCountdown()
    }

    private func discardDisplayModeDraft() {
        guard displayModeDraft != nil else { return }
        displayModeDraft = nil
        syncBacklightCountdown()
    }

    func cancelBacklightCountdown() {
        guard backlightCountdown != nil else { return }
        display.cancelBlackout()
    }

    func beginDisplayShortcutEditing() {
        editingDisplayShortcut = true
        syncBacklightCountdown()
    }

    func endDisplayShortcutEditing() {
        editingDisplayShortcut = false
        syncBacklightCountdown()
    }

    private func syncBacklightCountdown() {
        guard phase == .active, !isRestarting, display.hasCountdown else { return }
        if settingsMessage != nil {
            // A failed Apply must not leave an already armed blackout behind.
            display.cancelBlackout()
            if displayModeDraft == displayMode { displayModeDraft = nil }
        } else if editingDisplayShortcut || displayModeDraft != nil || settingsApplying {
            display.pauseCountdown()
        } else {
            display.resumeCountdown(at: operations.now())
        }
    }

    func validateDisplayShortcut(_ shortcut: DisplayShortcut) throws {
        try display.validateShortcut(shortcut)
    }

    @discardableResult
    func setDisplayShortcut(_ shortcut: DisplayShortcut?) throws -> SessionOperationResult {
        guard canChangeDisplayShortcut else { throw WakecupError(message: "display.shortcut.locked") }
        let result = try display.setShortcut(shortcut, running: phase == .active)
        if shortcut == nil, displayModeDraft == .backlightOff { discardDisplayModeDraft() }
        return result
    }

    func start() { _ = try? start(with: nil) }

    private func start(with candidate: StartSettings?) throws -> SessionOperationResult {
        guard !busy, !needsRecovery, !helper.working, !display.transitioning else {
            throw WakecupError(message: "Wakecup is busy. Check its status and try again.")
        }
        if (candidate?.closedLid ?? closedLid) && helper.selected && helper.checking {
            throw WakecupError(message: "Wait for the helper check to finish.")
        }
        // A previous failed brightness recovery keeps its escape action armed.
        // Resolve it before starting another timer or restoration child.
        if isBacklightOff {
            display.finish()
            guard !isBacklightOff else { throw WakecupError(message: "Restore brightness before starting Wakecup.") }
        }
        // Refresh here as well as on ticks: power can change just before a click.
        power = operations.readPower()
        let targetPower = candidate?.power ?? currentPowerSettings
        if let restriction = powerRestriction(power, mode: targetPower.mode, threshold: Int(targetPower.threshold)) {
            throw WakecupError(message: SessionMessage(reason: restriction.reason).text(using: { $0 }))
        }
        settingsResult = nil
        beginStart(restart: nil, candidate: candidate)
        switch phase {
        case .active: return .completed
        case .authorizing, .stopping:
            return .pending(waitingForPassword ? "Confirm the macOS authorization prompt if it appears." : nil)
        default: return .rejected(message ?? "Wakecup could not start. Check the current status.")
        }
    }

    private func beginStart(restart: RestartRequest?, candidate: StartSettings? = nil) {
        settingsMessage = nil
        do {
            let duration: TimeInterval?
            if let restart { duration = restart.deadline.map { max(1, $0 - operations.now()) } }
            else if let choice = candidate?.endTime {
                duration = try choice.validatedDuration(from: currentDate)
            } else { duration = try selectedDuration() }
            let choice = candidate?.endTime ?? endTimeChoice
            let absoluteDeadline: TimeInterval?
            if let restart { absoluteDeadline = restart.deadline }
            else { absoluteDeadline = choice.hasFixedDate ? duration.map { operations.now() + $0 } : nil }
            let targetPower = candidate?.power ?? restart?.power ?? currentPowerSettings
            let config = SessionConfiguration(id: UUID().uuidString, parentPID: getpid(), duration: duration,
                powerMode: targetPower.mode, threshold: Int(targetPower.threshold),
                closedLid: candidate?.closedLid ?? closedLid, keepDisplayOn: candidate?.display.keepsDisplayOn ?? keepDisplayOn,
                parentIdentity: processIdentity(getpid()), absoluteDeadline: absoluteDeadline)
            _ = try SessionMonitor(configuration: config, now: operations.now())
            if config.closedLid, try operations.readSleepDisabled() {
                throw WakecupError(message: "Sleep is already disabled by a system setting. Wakecup will not change an existing setting.")
            }
            let newFiles = try config.closedLid ? operations.createFiles(config) : nil
            pendingStart = candidate
            configuration = config
            files = newFiles
            monitor = nil
            control = SessionControl()
            lastStatus = nil
            statusReadFailedAt = nil
            pendingError = nil
            pendingSettings = nil
            settingsApplying = false
            nextSettingsRevision = 0
            display.clearError()
            message = nil
            if restart == nil { deadline = nil }
            if let newFiles {
                defaults.set(newFiles.url.path, forKey: "lastSession")
                phase = .authorizing
                authorizationFinishedAt = nil
                usingInstalledHelper = operations.usesInstalledHelper()
                if usingInstalledHelper { runInstalledHelper(files: newFiles, restoreOnly: false) }
                else {
                    let task = operations.authorization(newFiles, false)
                    authorization = task
                    runAuthorization(task)
                }
            } else {
                try operations.startAssertions(config.keepDisplayOn)
                let start = operations.now()
                monitor = try SessionMonitor(configuration: config, now: start)
                deadline = monitor?.deadline
                phase = .active
                becameActive()
            }
            tick()
        } catch let issue as EndTimeSelection.Issue {
            fail(SessionMessage(issue.messageKey))
        } catch { fail(SessionMessage(reason: error.localizedDescription)) }
    }

    private func runInstalledHelper(files: SessionFiles, restoreOnly: Bool) {
        let requestID = UUID()
        helperRequestID = requestID
        let sessionID = configuration?.id
        operations.startHelper(files, restoreOnly) { [weak self] result in
            guard let self, self.configuration?.id == sessionID, self.helperRequestID == requestID, self.busy else { return }
            self.helperRequestID = nil
            self.authorizationFinishedAt = operations.now()
            if case .failure(let error) = result {
                // The reply can be lost after the guard has started. Always send
                // stop through the session files; never replay the root request.
                let helperError = SessionMessage("Helper request failed: %@", arguments: [error.localizedDescription])
                if restoreOnly {
                    self.pendingError = helperError
                    self.recovering = false
                    self.fail(helperError)
                } else {
                    if self.pendingError == nil { self.pendingError = helperError }
                    self.requestStop()
                }
                self.showRequested?()
            }
            self.tick()
        }
    }

    private func runAuthorization(_ task: SessionAuthorization) {
        helperRequestID = nil
        let sessionID = configuration?.id
        do {
            try task.run { [weak self] result in
                guard let self else { return }
                guard self.configuration?.id == sessionID, self.authorization === task else { return }
                self.authorization = nil
                self.authorizationFinishedAt = self.operations.now()
                if self.recovering {
                    self.recovering = false
                    if result.status == 0, let files = self.files,
                       let status = try? files.read("status.json", as: SessionStatus.self), status.sleepRestored {
                        self.finish(status)
                    } else { self.fail("Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide.") }
                } else if result.status != 0 {
                    // AppleScript appends its error number to the final line.
                    let cancelled = result.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
                    if self.pendingError == nil {
                        self.pendingError = cancelled ? "Request cancelled. The session was not started." : "Could not authorize closed-lid mode."
                    }
                    if cancelled, self.discardUnstartedFiles() {
                        self.finishCancelledStartup()
                    } else {
                        self.requestStop()
                    }
                    self.showRequested?()
                }
                self.tick()
            }
        } catch {
            authorization = nil
            // A thrown launch error occurs before the authorization process runs.
            if !recovering { _ = discardUnstartedFiles() }
            recovering = false
            fail(SessionMessage(reason: error.localizedDescription))
        }
    }

    func tick() {
        now = operations.now()
        power = operations.readPower()
        display.checkHealth()
        defer {
            syncBacklightCountdown()
            if phase == .active, !isRestarting, statusReadFailedAt == nil, deadline.map({ now < $0 }) ?? true {
                display.advanceCountdown(at: now)
            }
            statusDidChange?()
        }
        if isRestarting, let restart = restartRequest, let limit = restart.deadline, now >= limit {
            closedLid = restart.previousClosedLid
            restartRequest = nil
            isRestarting = false
            pendingError = Self.restartExpired
            requestStop()
        }
        if needsRecovery, !busy { _ = refreshRecoveryStatus() }
        if busy, recovering, usingInstalledHelper, let files {
            if let status = try? files.read("status.json", as: SessionStatus.self),
               ["stopped", "failed"].contains(status.phase), status.sleepRestored {
                recovering = false; finish(status)
            } else if now - recoveryStartedAt > 30 {
                recovering = false
                fail("Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide.")
            }
            return
        }
        guard busy, !recovering, let config = configuration else { return }
        if config.closedLid {
            guard let files else { return }
            guard let status = try? files.read("status.json", as: SessionStatus.self) else {
                let failedAt = statusReadFailedAt ?? now
                statusReadFailedAt = failedAt
                if now - failedAt >= 10 {
                    fail("Could not read guardian state.", requiresSleepConfirmation: true)
                }
                return
            }
            statusReadFailedAt = nil
            lastStatus = status
            if ["arming", "active", "restoring"].contains(status.phase),
               !operations.guardianResponding(status, operations.now()) {
                fail("The guardian is not responding. Restore normal sleep to continue.")
                return
            }
            if let pending = pendingSettings, now - pending.sentAt > 8 {
                // Check the deadline before an acknowledgement can clear the pending request.
                pendingSettings = nil
                settingsMessage = "Could not confirm the new settings."
                if status.phase == "active" {
                    stop()
                    return
                }
            } else {
                reconcileSettings(status)
            }
            switch status.phase {
            case "active":
                if phase == .authorizing {
                    do {
                        try operations.startAssertions(config.keepDisplayOn)
                        deadline = status.deadline
                        phase = .active
                        becameActive()
                    }
                    catch { pendingError = SessionMessage(reason: error.localizedDescription); requestStop(); return }
                }
                deadline = status.deadline
            case "stopped", "failed": finish(status)
            case "restoring": phase = .stopping
            case "arming": break
            case "preparing":
                if authorization == nil, let finished = authorizationFinishedAt, now - finished > 5 {
                    resolveGuardianStartupTimeout(files)
                }
            default: break
            }
        } else if phase == .active, var monitor {
            let reason = monitor.step(now: now, control: control, power: power, ownerAlive: true)
            self.monitor = monitor
            deadline = monitor.deadline
            var status = SessionStatus(phase: reason == nil ? "active" : "stopped", reason: reason ?? "")
            _ = status.update(from: monitor)
            reconcileSettings(status)
            if reason != nil { finish(status) }
        }
    }

    private func resolveGuardianStartupTimeout(_ files: SessionFiles) {
        let startupError: SessionMessage = "The guardian did not start. Sleep settings were not confirmed."
        do {
            if try confirmGuardianDidNotStart(files) {
                if phase == .stopping { finishCancelledStartup() }
                else { fail(startupError) }
            } else if let finished = authorizationFinishedAt, now - finished >= SessionStatus.responseTimeout {
                fail("Could not confirm that the guardian stopped.", requiresSleepConfirmation: true)
            } else if phase == .authorizing {
                pendingError = startupError
                phase = .stopping
            }
        } catch {
            fail("Could not send the stop request to the guardian.", requiresSleepConfirmation: true)
        }
    }

    private func sendGuardianStop(_ files: SessionFiles) throws {
        guard !control.stop else { return }
        var stop = control
        stop.stop = true
        try files.write(stop, to: "control.json")
        control = stop
    }

    private func confirmGuardianDidNotStart(_ files: SessionFiles, checkSystemSleep: Bool = false) throws -> Bool {
        try sendGuardianStop(files)
        guard try files.tryLockGuardianAccess() else { return false }
        defer { files.unlockGuardianAccess() }
        // The guardian must read Stop under this same lock before changing sleep.
        if let status = try? files.read("status.json", as: SessionStatus.self) {
            guard status.phase == "preparing" else { return false }
            _ = discardUnstartedFiles()
        } else {
            // On explicit retry, a missing status can be resolved by checking macOS.
            guard checkSystemSleep, (try? operations.readSleepDisabled()) == false else { return false }
            forgetSessionFiles(files)
        }
        return true
    }

    private func finishCancelledStartup() {
        finish(SessionStatus(phase: "stopped", reason: "запуск отменён"))
    }

    @discardableResult
    func stop() -> SessionOperationResult {
        if partialSettingsIssue == nil && !display.transitioning { settingsResult = nil }
        pendingStart = nil
        if let restart = restartRequest { closedLid = restart.previousClosedLid }
        restartRequest = nil
        isRestarting = false
        let displayResult = display.finish()
        let stopResult = requestStop()
        switch stopResult {
        case .completed: return displayResult
        default: return stopResult
        }
    }

    @discardableResult
    private func requestStop() -> SessionOperationResult {
        if !isRestarting { displayModeDraft = nil }
        display.cancelCountdown()
        guard busy else { return .completed }
        defer { statusDidChange?() }
        if let files, configuration?.closedLid == true {
            defer { authorization?.cancel() }
            do {
                try sendGuardianStop(files)
                phase = .stopping
                return .pending()
            } catch {
                let issue: SessionMessage = "Could not send the stop request to the guardian."
                fail(issue, requiresSleepConfirmation: true)
                return .rejected(issue)
            }
        }
        finish(SessionStatus(phase: "stopped", reason: "остановлено"))
        return .completed
    }

    private func finish(_ status: SessionStatus) {
        pendingStart = nil
        let wasRestarting = isRestarting
        let wasApplying = settingsApplying || wasRestarting
        if !wasApplying && pendingError == nil && hasSettingsDraft { settingsMessage = nil }
        if let restart = restartRequest {
            if pendingError == nil, status.phase == "stopped", status.sleepRestored, status.reason == "остановлено" {
                lastStatus = status
                if configuration?.closedLid == true, operations.guardianIsRunning(status) {
                    if guardianExitWaitSince == nil { guardianExitWaitSince = operations.now() }
                    if operations.now() - (guardianExitWaitSince ?? operations.now()) > 5 {
                        fail("The previous guardian has not exited. Wakecup could not apply the change.")
                    }
                    return
                }
                if let files { discardFinishedFiles(files) }
                if let limit = restart.deadline, operations.now() >= limit {
                    pendingError = Self.restartExpired
                } else {
                    phase = .idle
                    beginStart(restart: restart)
                    return
                }
            }
            closedLid = restart.previousClosedLid
            restartRequest = nil
            isRestarting = false
        }
        displayModeDraft = nil
        powerDraft = nil
        closedLidDraft = nil
        pendingSettings = nil
        settingsApplying = false
        display.clearError()
        display.finish(completion: operations.stopAssertions)
        helperRequestID = nil
        lastStatus = status
        deadline = nil
        monitor = nil
        needsRecovery = status.ownsSleepChange && !status.sleepRestored
        phase = status.phase == "failed" || needsRecovery ? .failed : .idle
        let notice: SessionMessage?
        if needsRecovery {
            notice = SessionMessage("%@ Restore normal sleep to continue.", arguments: [status.reason])
        } else if let pendingError {
            notice = pendingError
        } else if wasRestarting && status.reason == "время истекло" {
            notice = Self.restartExpired
        } else if phase == .idle && ["", "остановлено", "запуск отменён", "время истекло"].contains(status.reason) {
            notice = wasRestarting ? "The mode could not restart. Wakecup has stopped." : nil
        } else {
            notice = status.reason.isEmpty ? "Session ended." : SessionMessage("Session ended: %@.", arguments: [status.reason])
        }
        if wasApplying {
            rejectSettings(notice ?? settingsMessage ?? Self.settingsFailure)
            message = nil
        } else {
            // A pending display change reports its outcome when brightness restoration finishes.
            if case .pending = settingsResult, !display.transitioning { settingsResult = nil }
            message = notice
        }
        if status.sleepRestored, let files { discardFinishedFiles(files) }
        restoreSavedEndTime()
        statusDidChange?()
    }

    private func fail(_ text: SessionMessage, requiresSleepConfirmation: Bool = false) {
        settingsResult = nil
        pendingStart = nil
        let wasApplying = settingsApplying || isRestarting
        powerDraft = nil
        closedLidDraft = nil
        if isRestarting { restoreSavedEndTime() }
        displayModeDraft = nil
        if let restart = restartRequest { closedLid = restart.previousClosedLid }
        restartRequest = nil
        isRestarting = false
        pendingSettings = nil
        settingsApplying = false
        display.clearError()
        display.finish(completion: operations.stopAssertions)
        helperRequestID = nil
        if busy, let files { try? sendGuardianStop(files) }
        needsRecovery = requiresSleepConfirmation || (lastStatus?.ownsSleepChange == true && lastStatus?.sleepRestored != true)
        phase = .failed
        if wasApplying { rejectSettings(text) }
        message = wasApplying ? nil : text
        statusDidChange?()
    }

    private func inspectPreviousSession() {
        guard let path = defaults.string(forKey: "lastSession"),
              let previous = try? SessionFiles(url: URL(fileURLWithPath: path)),
              let config = try? previous.read("configuration.json", as: SessionConfiguration.self), config.closedLid else { return }
        guard let status = try? previous.read("status.json", as: SessionStatus.self) else {
            files = previous
            configuration = config
            fail("Could not read guardian state.", requiresSleepConfirmation: true)
            return
        }
        if status.phase == "preparing" {
            files = previous
            configuration = config
            lastStatus = status
            phase = .stopping
            authorizationFinishedAt = operations.now()
            resolveGuardianStartupTimeout(previous)
            return
        }
        if status.sleepRestored {
            discardFinishedFiles(previous)
            return
        }
        guard status.ownsSleepChange else { return }
        files = previous
        configuration = config
        lastStatus = status
        if operations.guardianResponding(status, operations.now()) {
            phase = .stopping
            do { try sendGuardianStop(previous) }
            catch { fail("Could not send the stop request to the guardian.", requiresSleepConfirmation: true) }
        } else {
            needsRecovery = true
            phase = .failed
            message = "The previous session was interrupted. Restore normal sleep before starting again."
        }
    }

    private func discardUnstartedFiles() -> Bool {
        guard let files, files.removeIfUnstarted() else { return false }
        forgetSessionFiles(files)
        return true
    }

    private func discardFinishedFiles(_ finished: SessionFiles) {
        if finished.removeIfFinished() { forgetSessionFiles(finished) }
    }

    private func forgetSessionFiles(_ removed: SessionFiles) {
        if defaults.string(forKey: "lastSession") == removed.url.path {
            defaults.removeObject(forKey: "lastSession")
        }
        if files === removed { files = nil }
    }

    private func refreshRecoveryStatus() -> Bool {
        guard let files, let status = try? files.read("status.json", as: SessionStatus.self),
              ["stopped", "failed"].contains(status.phase) else { return false }
        if status.sleepRestored {
            finish(status)
            return true
        }
        if status.ownsSleepChange, lastStatus?.phase != status.phase || lastStatus?.reason != status.reason {
            finish(status)
        }
        return false
    }

    @discardableResult
    func recover() -> SessionOperationResult {
        guard !busy, !helper.working else { return .rejected("Wait until Wakecup has stopped.") }
        guard needsRecovery else { return .completed }
        let recoveryFailure: SessionMessage = "Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide."
        guard let files else { return .rejected(recoveryFailure) }
        settingsMessage = nil
        if refreshRecoveryStatus() { return .completed }
        let status = try? files.read("status.json", as: SessionStatus.self)
        let stopFailure: SessionMessage = "Could not send the stop request to the guardian."
        if status == nil || status?.phase == "preparing" {
            do {
                if try confirmGuardianDidNotStart(files, checkSystemSleep: true) {
                    finishCancelledStartup()
                    return .completed
                }
                message = recoveryFailure
                return .rejected(recoveryFailure)
            } catch {
                message = stopFailure
                return .rejected(stopFailure)
            }
        }
        if let status, ["arming", "active", "restoring"].contains(status.phase),
           operations.guardianResponding(status, operations.now()) {
            do {
                try sendGuardianStop(files)
                message = "Stopping…"
                return .pending()
            } catch {
                message = stopFailure
                return .rejected(stopFailure)
            }
        }
        phase = .authorizing
        recovering = true
        recoveryStartedAt = operations.now()
        authorizationFinishedAt = nil
        usingInstalledHelper = operations.usesInstalledHelper()
        if usingInstalledHelper { runInstalledHelper(files: files, restoreOnly: true) }
        else {
            let task = operations.authorization(files, true)
            authorization = task
            runAuthorization(task)
        }
        if phase == .failed { return .rejected(message ?? recoveryFailure) }
        return needsRecovery ? .pending(waitingForPassword ? "Confirm the macOS authorization prompt." : nil) : .completed
    }

    func refreshLoginState() {
        let previouslyNeededApproval = loginNeedsApproval
        let status = operations.loginItem.readStatus()
        loginEnabled = status == .enabled
        loginNeedsApproval = status == .requiresApproval
        if previouslyNeededApproval && loginEnabled { message = "Login at startup is enabled." }
    }

    func toggleLogin() {
        refreshLoginState()
        setLoginEnabled(!loginEnabled)
    }

    func setLoginEnabled(_ enabled: Bool) {
        defer { refreshLoginState() }
        do {
            try operations.loginItem.setEnabled(enabled)
            refreshLoginState()
            if loginNeedsApproval {
                message = "Allow Wakecup in System Settings → General → Login Items."
            } else { message = loginEnabled ? "Login at startup is enabled." : "Login at startup is disabled." }
        } catch { message = SessionMessage("Could not change login at startup: %@", arguments: [error.localizedDescription]) }
    }

    func prepareToQuit(completion: @escaping () -> Void) -> Bool {
        guard display.transitioning || isBacklightOff else { return false }
        stop()
        display.finish(completion: completion)
        return true
    }

    func quit() { stop(); quitRequested?() }
}
