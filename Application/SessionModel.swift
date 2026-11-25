import Foundation
import ServiceManagement
import Combine

final class SessionModel: ObservableObject {
    @Published var phase: AppSessionPhase = .idle {
        didSet {
            if phase != oldValue { pendingDisplayModeSelection = nil }
            display.setShortcutSessionActive(phase == .active)
        }
    }
    @Published var message: SessionMessage?
    @Published var now: TimeInterval
    @Published var power: PowerState?
    @Published private(set) var closedLid = true { didSet { saveOptions() } }
    private let display: DisplayModeController
    var displayMode: DisplayMode { display.mode }
    var isDisplayTransitioning: Bool { display.transitioning }
    @Published private(set) var displayModeDraft: DisplayMode?
    var displayShortcut: DisplayShortcut? { display.shortcut }
    var isBacklightOff: Bool { display.isBacklightOff }
    var keepDisplayOn: Bool { display.mode.keepsDisplayOn }
    var displayControlError: SessionMessage? { display.error ?? display.shortcutRegistrationError }
    var priorityStopMessage: SessionMessage? {
        if needsRecovery && !busy { return message }
        guard let message, message.key == Self.thermalStopNotice.key else { return nil }
        return isBacklightOff ? display.error ?? message : message
    }
    var backlightCountdown: Int? {
        guard phase == .active, !isRestarting, !settingsApplying, settingsMessage == nil else { return nil }
        return display.countdownSeconds(at: operations.now())
    }
    private var editingDisplayShortcut = false
    private var pendingDisplayModeSelection: UUID?
    var canChangeDisplayMode: Bool { canEditSessionSettings && !settingsApplying && !display.transitioning }
    var canChangeDisplayShortcut: Bool { canChangeDisplayMode && !isBacklightOff }

    @Published private var endTimeChoice: EndTimeSelection.Choice = .oneHour
    @Published private(set) var endTimeInputInvalid = false
    @Published private(set) var endTimeReplacementID: UUID?
    private var unresolvedEndDay: (day: Date, clockTime: EndTimeSelection.ClockTime)?
    @Published private(set) var durationEditDirty = false
    @Published private var liveSettingsApplying = false
    @Published private var displaySettingsApplying = false
    var settingsApplying: Bool { liveSettingsApplying || displaySettingsApplying }
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
    @Published private(set) var thermalStopLevel: ThermalStopLevel = .critical
    @Published var showRemaining = true { didSet { saveOptions() } }
    @Published var showInMenuBar = true { didSet { saveOptions() } }
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var needsRecovery = false
    @Published private(set) var deadline: TimeInterval?

    private let helper: PrivilegedHelperController
    private var helperObservation: AnyCancellable?
    private var displayObservation: AnyCancellable?
    private var usingInstalledHelper = false
    var waitingForPassword: Bool { phase == .authorizing && !usingInstalledHelper }
    var canSelectHelperMode: Bool { !statusPhase.showsProgress && !isRestarting && !helper.working }
    var canEditSessionSettings: Bool { !statusPhase.showsProgress && !isRestarting && !needsRecovery && !helper.working }
    var canChangeClosedLid: Bool { canEditSessionSettings && !settingsApplying && !display.transitioning }
    var canChangeHelper: Bool { !busy && canSelectHelperMode && !needsRecovery }

    enum HelperInstallationAction { case install, update, remove }

    var helperStatus: HelperStatus {
        HelperStatus(state: helper.state, selected: helper.selected, working: helper.working,
                     checking: helper.checking, detail: helper.detail, installationError: helper.installationError,
                     updateRequired: helper.selected && helper.updatePending)
    }

    var helperStatuses: AnyPublisher<HelperStatus, Never> {
        // The controller sends will-change notifications. Read the full status
        // after its synchronous transition has completed.
        helper.objectWillChange
            .receive(on: DispatchQueue.main)
            .compactMap { [weak self] in self?.helperStatus }
            .prepend(helperStatus)
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func refreshHelperStatus() { helper.refresh() }

    func prepareHelperSettings() -> HelperStatus? {
        guard canSelectHelperMode else { return nil }
        refreshHelperStatus()
        return helperStatus
    }

    func prepareHelperRemoval() -> Bool {
        guard canChangeHelper else { return false }
        refreshHelperStatus()
        return helper.installed
    }

    // An absent helper needs the setup dialog. An installed helper can update directly.
    func updateHelperOrPrepareSetup(beforeAuthorization: () -> Void,
                                    onFailure: @escaping (String) -> Void) -> HelperStatus? {
        guard canChangeHelper else { return nil }
        refreshHelperStatus()
        guard helper.installed else { return helperStatus }
        _ = beginHelperInstallation(.update, beforeAuthorization: beforeAuthorization, onFailure: onFailure)
        return nil
    }

    func canSetHelperMode(_ enabled: Bool) -> Bool { canSelectHelperMode && (!enabled || helper.state == .ready) }

    @discardableResult
    func setHelperMode(_ enabled: Bool) -> SessionOperationResult {
        guard canSetHelperMode(enabled) else { return .rejected("The requested helper mode is unavailable.") }
        helper.select(enabled)
        return .completed
    }

    func applyHelperSettings(expected: HelperStatus, allowInstallationChanges: Bool,
                             beforeAuthorization: () -> Void, onFailure: @escaping (String) -> Void) {
        guard canSelectHelperMode else { return }
        refreshHelperStatus()
        guard helper.state == expected.state else { return }
        if helper.state == .ready {
            guard helper.selected == expected.selected else { return }
            setHelperMode(!expected.selected)
        } else if allowInstallationChanges {
            let action: HelperInstallationAction = expected.installed ? .update : .install
            _ = beginHelperInstallation(action, beforeAuthorization: beforeAuthorization, onFailure: onFailure)
        }
    }

    @discardableResult
    func changeHelperInstallation(_ action: HelperInstallationAction,
                                  beforeAuthorization: () -> Void = {},
                                  onFailure: ((String) -> Void)? = nil) -> SessionOperationResult {
        guard canChangeHelper else { return .rejected("Stop Wakecup and restore sleep before changing the helper.") }
        refreshHelperStatus()
        return beginHelperInstallation(action, beforeAuthorization: beforeAuthorization, onFailure: onFailure)
    }

    private func beginHelperInstallation(_ action: HelperInstallationAction, beforeAuthorization: () -> Void,
                                         onFailure: ((String) -> Void)?) -> SessionOperationResult {
        guard canChangeHelper else { return .rejected("Stop Wakecup and restore sleep before changing the helper.") }
        guard helper.installed == (action != .install) else {
            return .rejected(helper.installed ? "The helper is already installed. Use update." : "The helper is not installed.")
        }
        beforeAuthorization()
        return helper.requestInstallation(remove: action == .remove, onFailure: onFailure)
    }

    private let defaults: UserDefaults
    private let operations: SessionOperations
    private let resources: SessionPowerResources
    private var cancelTicks: (() -> Void)?
    private var cancelThermalChecks: (() -> Void)?
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
    private static let thermalStopNotice = SessionMessage(SessionTermination.thermal.text)
    private static let restartExpired: SessionMessage = "The Wakecup timer ended. “Keep awake with lid closed” was not changed."
    private var recovering = false
    var recoveryInProgress: Bool { recovering && busy }
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

    static let returningControlMessage: SessionMessage = "Returning control to macOS…"

    private var hasRunningSession: Bool { phase.isBusy || isRestarting }
    var isReturningControl: Bool {
        !recovering && !isRestarting && (phase == .stopping || display.isReturningControl)
    }
    var needsBrightnessRecovery: Bool { !hasRunningSession && isBacklightOff && !display.transitioning }
    // The guardian can finish before the display worker releases the last system resources.
    var statusPhase: AppSessionPhase {
        if isReturningControl { return .stopping }
        if needsBrightnessRecovery { return .failed }
        return phase
    }
    var busy: Bool { hasRunningSession || display.isReturningControl }
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

    var selectedEndTimePreset: EndTimeSelection.Preset? {
        guard !endTimeInputInvalid else { return nil }
        if phase == .active && !durationEditDirty {
            return deadline == nil ? .indefinitely : nil
        }
        guard case .preset(let preset, _) = endTimeChoice else { return nil }
        return preset
    }

    var selectedEndCalendarDate: Date? { unresolvedEndDay?.day ?? selectedEndDate }
    var unresolvedEndClockTime: EndTimeSelection.ClockTime? { unresolvedEndDay?.clockTime }

    // Starting to type from infinity chooses today, even near midnight.
    var selectedEndDay: Date { selectedEndCalendarDate ?? currentDate }

    func selectEndDay(_ day: Date, calendar: Calendar) {
        guard canEditSettingsDraft else { return }
        if let currentDay = selectedEndCalendarDate, calendar.isDate(currentDay, inSameDayAs: day) { return }
        let now = currentDate
        let clock: EndTimeSelection.ClockTime
        if let unresolvedEndClockTime {
            clock = unresolvedEndClockTime
        } else {
            let selected = selectedEndDate
            var seed = selected ?? now.addingTimeInterval(3600)
            if selected == nil, calendar.isDate(day, inSameDayAs: now),
               let today = calendar.dateInterval(of: .day, for: now), seed >= today.end {
                seed = today.end.addingTimeInterval(-60)
            }
            clock = EndTimeSelection.ClockTime(seed, calendar: calendar)
        }
        if let date = clock.date(on: day, calendar: calendar, from: now) {
            selectEndDate(date)
        } else {
            editEndClock(.nonexistent(clock, on: day))
        }
    }

    func editEndClock(_ edit: EndTimeSelection.ClockEdit) {
        guard canEditSettingsDraft else { return }
        switch edit {
        case .resolved(let date):
            selectEndDate(date)
        case .nonexistent(let clock, let day):
            unresolvedEndDay = (day, clock)
            setEndTimeInputInvalid(true)
        case .incomplete:
            setEndTimeInputInvalid(true)
        case .empty:
            if phase == .active && deadline == nil {
                selectEndTime(.preset(.indefinitely, date: nil))
            } else {
                setEndTimeInputInvalid(selectedEndDate != nil || unresolvedEndDay != nil)
            }
        }
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
        defer { syncBacklightCountdown() }
        settingsMessage = nil
        clearEndTimeInputError()
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
        defer { syncBacklightCountdown() }
        let invalid = invalid || unresolvedEndDay != nil
        if invalid != endTimeInputInvalid { settingsMessage = nil }
        if invalid && phase == .active {
            if !durationEditDirty {
                endTimeChoice = selectedEndDate.map(EndTimeSelection.Choice.date) ?? .preset(.indefinitely, date: nil)
            }
            durationEditDirty = true
        }
        endTimeInputInvalid = invalid
    }

    private func clearEndTimeInputError() {
        unresolvedEndDay = nil
        endTimeInputInvalid = false
    }

    init(defaults: UserDefaults = .standard, operations: SessionOperations? = nil,
         helper: PrivilegedHelperController? = nil) {
        self.defaults = defaults
        let helper = helper ?? PrivilegedHelperController(defaults: defaults)
        self.helper = helper
        let operations = operations ?? .system(helper: helper)
        self.operations = operations
        let resources = SessionPowerResources(startAssertions: operations.startAssertions, stopAssertions: operations.stopAssertions,
            readThermalState: operations.readThermalState, restoreAfterThermalStop: operations.restoreBacklightAfterThermalStop)
        self.resources = resources
        display = DisplayModeController(defaults: defaults, operations: .init(
            assertions: resources.holdAssertions,
            enter: { complete in operations.enterBacklight(resources.darkeningPermission(), complete) },
            restore: operations.restoreBacklight, validate: operations.validateDisplayShortcut,
            register: operations.registerDisplayShortcut, unregister: operations.unregisterDisplayShortcut,
            checkBacklight: operations.checkBacklight))
        now = operations.now()
        power = operations.readPower()
        restoreSavedEndTime()
        closedLid = defaults.object(forKey: "closedLid") as? Bool ?? true

        allowBattery = defaults.object(forKey: "allowBattery") as? Bool ?? true
        threshold = min(Double(BatteryThreshold.range.upperBound),
            max(Double(BatteryThreshold.range.lowerBound), defaults.object(forKey: "threshold") as? Double ?? 20))
        thermalStopLevel = defaults.string(forKey: "thermalStopLevel").flatMap(ThermalStopLevel.init(rawValue:)) ?? .critical
        showRemaining = defaults.object(forKey: "showRemaining") as? Bool ?? true
        showInMenuBar = defaults.object(forKey: "showInMenuBar") as? Bool ?? true
        helperObservation = helperStatuses.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        displayObservation = display.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        refreshLoginState()
        canPersist = true
        display.shortcutPressed = { [weak self] in self?.handleDisplayShortcut() }
        inspectPreviousSession()
        cancelTicks = operations.scheduleTicks { [weak self] in self?.tick() }
        cancelThermalChecks = operations.scheduleThermalChecks { [weak resources] in resources?.checkTemperature() }
    }

    deinit {
        cancelThermalChecks?()
        cancelTicks?()
    }

    func setThermalStopLevel(_ level: ThermalStopLevel) {
        guard level != thermalStopLevel else { return }
        do {
            if !recovering && (phase == .active || phase == .authorizing) {
                try resources.setThermalLevel(level)
            }
            thermalStopLevel = level
            defaults.set(level.rawValue, forKey: "thermalStopLevel")
        } catch {
            settingsMessage = Self.settingsFailure
        }
    }

    var endTimeIssue: EndTimeSelection.Issue? {
        if unresolvedEndDay != nil { return .nonexistentTime }
        if endTimeInputInvalid { return .incomplete }
        if phase == .active && !durationEditDirty { return nil }
        let now = currentDate
        return endTimeChoice.date(from: now).flatMap { EndTimeSelection.issue(for: $0, from: now) }
    }

    var durationInputIsValid: Bool { endTimeIssue == nil }

    func selectedDuration() throws -> TimeInterval? {
        if unresolvedEndDay != nil { throw EndTimeSelection.Issue.nonexistentTime }
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
        clearEndTimeInputError()
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
        defer { syncBacklightCountdown() }
        settingsMessage = nil
        if phase == .active { closedLidDraft = enabled == closedLid ? nil : enabled }
        else { closedLid = enabled }
    }

    private var currentPowerSettings: PowerDraft {
        PowerDraft(allowBattery: allowBattery, threshold: threshold)
    }

    func editAllowBattery(_ enabled: Bool) {
        guard canEditSettingsDraft, enabled != selectedAllowBattery else { return }
        defer { syncBacklightCountdown() }
        settingsMessage = nil
        guard phase == .active else { allowBattery = enabled; return }
        var value = powerDraft ?? currentPowerSettings
        value.allowBattery = enabled
        powerDraft = value == currentPowerSettings ? nil : value
    }

    func editThreshold(_ threshold: Double) {
        guard canEditSettingsDraft else { return }
        defer { syncBacklightCountdown() }
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
        clearEndTimeInputError()
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
        if needsRecovery { return .rejected(Self.recoveryRequired) }
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
                selectEndTime(endTime)
                endTimeReplacementID = UUID()
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
                try resources.updateGuardianSettings(update, files: files)
            }
            control = candidate
            nextSettingsRevision = revision
            pendingSettings = PendingSettings(update: update, sentAt: time, duration: duration,
                                              display: display, appliesPanelDraft: appliesPanelDraft)
            liveSettingsApplying = true
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
        liveSettingsApplying = false
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
                if phase == .active, status.phase == .active {
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
            clearEndTimeInputError()
            durationEditDirty = false
        }
    }

    private func applySettingsDisplay(_ mode: DisplayMode, afterOtherChanges: Bool = false,
                                      appliesPanelDraft: Bool) -> SessionOperationResult {
        let result = setDisplayMode(mode) { [weak self] result in
            // Synchronous completions are handled through the return value below.
            guard let self, self.displaySettingsApplying else { return }
            self.displaySettingsApplying = false
            self.finishDisplaySettings(result, mode: mode, afterOtherChanges: afterOtherChanges,
                                       appliesPanelDraft: appliesPanelDraft)
            self.statusDidChange?()
        }
        if case .pending = result {
            displaySettingsApplying = true
            settingsResult = result
            return result
        }
        return finishDisplaySettings(result, mode: mode, afterOtherChanges: afterOtherChanges,
                                     appliesPanelDraft: appliesPanelDraft)
    }

    @discardableResult
    private func finishDisplaySettings(_ result: SessionOperationResult, mode: DisplayMode, afterOtherChanges: Bool,
                                       appliesPanelDraft: Bool) -> SessionOperationResult {
        let outcome: SessionOperationResult
        if case .completed = result, displayMode != mode {
            outcome = .rejected(Self.displayChangeInterrupted)
        } else {
            outcome = result
        }

        let recorded: SessionOperationResult
        switch outcome {
        case .completed:
            if displayModeDraft == displayMode { discardDisplayModeDraft() }
            recorded = outcome
        case .rejected(let issue):
            if appliesPanelDraft {
                settingsMessage = issue
                syncBacklightCountdown()
            }
            recorded = afterOtherChanges ? .partiallyApplied(issue) : outcome
        default:
            recorded = outcome
        }
        settingsResult = recorded
        return recorded
    }

    @discardableResult
    private func setDisplayMode(_ mode: DisplayMode, completion: ((SessionOperationResult) -> Void)? = nil) -> SessionOperationResult {
        guard canChangeDisplayMode else { return .rejected(Self.settingsFailure) }
        let result = display.setMode(mode, running: phase == .active, now: operations.now(), completion: completion)
        statusDidChange?()
        return result
    }

    func selectDisplayMode(_ mode: DisplayMode, configureShortcut: ((@escaping (Bool) -> Void) -> Void)? = nil) {
        guard canChangeDisplayMode else { return }
        pendingDisplayModeSelection = nil
        guard mode != (displayModeDraft ?? displayMode) else { return }
        settingsMessage = nil
        if mode == .backlightOff && displayShortcut == nil {
            guard let configureShortcut else { setDisplayMode(mode); return }
            let request = UUID()
            pendingDisplayModeSelection = request
            configureShortcut { [weak self] saved in
                guard let self, self.pendingDisplayModeSelection == request else { return }
                self.pendingDisplayModeSelection = nil
                if saved, self.displayShortcut != nil { self.selectDisplayMode(mode) }
            }
            return
        }
        guard phase == .active else { setDisplayMode(mode); return }
        if mode == displayMode { discardDisplayModeDraft(); return }
        displayModeDraft = mode
        syncBacklightCountdown()
    }

    private func discardDisplayModeDraft() {
        guard displayModeDraft != nil else { return }
        displayModeDraft = nil
        syncBacklightCountdown()
    }

    @discardableResult
    func cancelBacklightCountdown() -> SessionOperationResult {
        guard display.hasCountdown else { return .completed }
        let result = display.cancelBlackout()
        if displayModeDraft == displayMode { discardDisplayModeDraft() }
        statusDidChange?()
        return result
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
        } else if editingDisplayShortcut || hasSettingsDraft || settingsApplying {
            display.pauseCountdown()
        } else {
            display.resumeCountdown(at: operations.now())
        }
    }

    func displayShortcutConflict(for shortcut: DisplayShortcut) -> DisplayShortcutConflict? {
        operations.checkDisplayShortcutConflict(shortcut)
    }

    @discardableResult
    func setDisplayShortcut(_ shortcut: DisplayShortcut?, reviewedConflict: DisplayShortcutConflict? = nil) throws -> SessionOperationResult {
        guard canChangeDisplayShortcut else { throw WakecupError(message: "display.shortcut.locked") }
        if let shortcut {
            guard shortcut.isValid else { throw DisplayHotKeyError.invalid }
            let conflict = displayShortcutConflict(for: shortcut)
            guard conflict != .system, conflict == reviewedConflict else { throw DisplayShortcutReviewRequired(conflict: conflict) }
        }
        let result = try display.setShortcut(shortcut, running: phase == .active)
        if shortcut == nil, displayModeDraft == .backlightOff { discardDisplayModeDraft() }
        return result
    }

    @discardableResult
    func restoreBrightness() -> SessionOperationResult {
        let result = display.restoreForUser(running: phase == .active && !isRestarting)
        statusDidChange?()
        return result
    }

    private func handleDisplayShortcut() {
        let running = phase == .active && !isRestarting
        if display.isBacklightOff || display.transitioning {
            // The same chord is still an escape if an earlier restoration failed.
            restoreBrightness()
            return
        } else if running, canChangeDisplayMode, !editingDisplayShortcut, statusReadFailedAt == nil,
                  deadline.map({ operations.now() < $0 }) ?? true {
            display.darkenImmediately()
            if displayModeDraft == displayMode { discardDisplayModeDraft() }
        } else { return }
        statusDidChange?()
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
        let continuing = restart != nil
        do {
            try resources.checkStart(level: thermalStopLevel, continuing: continuing)
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
                parentIdentity: processIdentity(getpid()), absoluteDeadline: absoluteDeadline,
                thermalStopLevel: thermalStopLevel)
            _ = try SessionMonitor(configuration: config, now: operations.now())
            if config.closedLid, try operations.readSleepDisabled() {
                throw WakecupError(message: "Sleep is already disabled by a system setting. Wakecup will not change an existing setting.")
            }
            let newFiles = try config.closedLid ? operations.createFiles(config) : nil
            do {
                try resources.begin(id: config.id, level: thermalStopLevel, files: newFiles, continuing: continuing) { [weak self] id in
                    self?.thermalStopDetected(in: id)
                }
            } catch {
                if let newFiles { _ = resources.discardUnstarted(newFiles) }
                throw error
            }
            pendingStart = candidate
            configuration = config
            files = newFiles
            monitor = nil
            control = SessionControl()
            lastStatus = nil
            statusReadFailedAt = nil
            pendingError = nil
            pendingSettings = nil
            liveSettingsApplying = false
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
                try resources.holdAssertions(display: config.keepDisplayOn)
                let start = operations.now()
                monitor = try SessionMonitor(configuration: config, now: start)
                deadline = monitor?.deadline
                phase = .active
                becameActive()
            }
            tick()
        } catch let termination as SessionTermination where termination.code == .thermal {
            if continuing {
                prepareForThermalStop()
                fail(Self.thermalStopNotice)
            } else {
                fail("Wakecup cannot start because the Mac is too hot.")
            }
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
                       let status = try? self.operations.readGuardianStatus(files), status.phase.isTerminal, status.sleepRestored {
                        self.finish(status)
                    } else { self.fail(Self.recoveryFailure) }
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
        display.checkBacklight()
        defer {
            syncBacklightCountdown()
            if phase == .active, !isRestarting, statusReadFailedAt == nil, deadline.map({ now < $0 }) ?? true {
                display.advanceCountdown(at: now)
            }
            statusDidChange?()
        }
        if let id = configuration?.id, resources.hasThermalStop(for: id) {
            thermalStopDetected(in: id)
        }
        if isRestarting, let restart = restartRequest, let limit = restart.deadline, now >= limit {
            closedLid = restart.previousClosedLid
            restartRequest = nil
            isRestarting = false
            pendingError = Self.restartExpired
            requestStop()
        }
        if needsRecovery, !busy { _ = refreshRecoveryStatus() }
        if recoveryInProgress, let files, usingInstalledHelper || phase == .stopping {
            if let status = try? operations.readGuardianStatus(files),
               status.phase.isTerminal, status.sleepRestored || phase == .stopping {
                recovering = false
                finish(status)
            } else if now - recoveryStartedAt >= 30 {
                recovering = false
                fail(Self.recoveryFailure)
            }
            return
        }
        guard hasRunningSession, !recovering, let config = configuration else { return }
        if config.closedLid {
            guard let files else { return }
            guard let status = try? operations.readGuardianStatus(files) else {
                let failedAt = statusReadFailedAt ?? now
                statusReadFailedAt = failedAt
                if now - failedAt >= 10 {
                    fail("Could not read guardian state.", requiresSleepConfirmation: true)
                }
                return
            }
            statusReadFailedAt = nil
            lastStatus = status
            if status.phase == .unknown {
                fail("Could not read guardian state.", requiresSleepConfirmation: true)
                return
            }
            if status.reasonCode == .thermal {
                resources.acceptThermalStop(for: config.id)
                thermalStopDetected(in: config.id)
            }
            if status.phase.expectsHeartbeat,
               !operations.guardianResponding(status, operations.now()) {
                fail("The guardian is not responding. Restore normal sleep to continue.")
                return
            }
            if let pending = pendingSettings, now - pending.sentAt > 8 {
                // Check the deadline before an acknowledgement can clear the pending request.
                pendingSettings = nil
                settingsMessage = "Could not confirm the new settings."
                if status.phase == .active {
                    stop()
                    return
                }
            } else {
                reconcileSettings(status)
            }
            switch status.phase {
            case .active:
                if phase == .authorizing {
                    do {
                        try resources.holdAssertions(display: config.keepDisplayOn)
                        deadline = status.deadline
                        phase = .active
                        becameActive()
                    }
                    catch {
                        if resources.hasThermalStop(for: config.id) { thermalStopDetected(in: config.id) }
                        else { pendingError = SessionMessage(reason: error.localizedDescription); requestStop() }
                        return
                    }
                }
                deadline = status.deadline
            case .stopped, .failed: finish(status)
            case .restoring: phase = .stopping
            case .arming: break
            case .preparing:
                if authorization == nil, let finished = authorizationFinishedAt, now - finished > 5 {
                    resolveGuardianStartupTimeout(files)
                }
            case .unknown: break // Handled before applying settings or checking liveness.
            }
        } else if phase == .active, var monitor {
            let reason = monitor.step(now: now, control: control, power: power, ownerAlive: true)
            self.monitor = monitor
            deadline = monitor.deadline
            var status = SessionStatus(phase: reason == nil ? .active : .stopped)
            if let reason { status.setTermination(reason) }
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
        try resources.sendGuardianStop(files)
        control.stop = true
    }

    private func confirmGuardianDidNotStart(_ files: SessionFiles, checkSystemSleep: Bool = false) throws -> Bool {
        try sendGuardianStop(files)
        guard try files.tryLockGuardianAccess() else { return false }
        defer { files.unlockGuardianAccess() }
        // The guardian must read Stop under this same lock before changing sleep.
        if let status = try? operations.readGuardianStatus(files) {
            if status.phase == .preparing {
                _ = discardUnstartedFiles()
            } else {
                guard status.phase == .unknown, status.sleepRestored, checkSystemSleep,
                      (try? operations.readSleepDisabled()) == false else { return false }
                // A future record format can be left intact once the system
                // confirms there is no sleep change and no guardian can start.
                forgetSessionFiles(files)
            }
        } else {
            // On explicit retry, a missing status can be resolved by checking macOS.
            guard checkSystemSleep, (try? operations.readSleepDisabled()) == false else { return false }
            forgetSessionFiles(files)
        }
        return true
    }

    private func finishCancelledStartup() {
        var status = SessionStatus(phase: .stopped)
        status.setTermination(.startupCancelled)
        finish(status)
    }

    @discardableResult
    func stop() -> SessionOperationResult {
        if recoveryInProgress { return .pending(Self.recoveryProgress) }
        if !hasRunningSession && display.isReturningControl { return .pending(Self.returningControlMessage) }
        if needsRecovery { return .rejected(Self.recoveryRequired) }
        if partialSettingsIssue == nil && !display.transitioning { settingsResult = nil }
        pendingStart = nil
        cancelRestart()
        let displayResult = display.finish()
        let stopResult = requestStop()
        switch stopResult {
        case .completed: return displayResult
        default: return stopResult
        }
    }

    private func thermalStopDetected(in id: String) {
        guard !recovering, hasRunningSession, configuration?.id == id,
              pendingError?.key != Self.thermalStopNotice.key else { return }
        prepareForThermalStop()
        if phase != .stopping { stop() }
    }

    private func prepareForThermalStop() {
        displaySettingsApplying = false
        pendingError = Self.thermalStopNotice
        pendingSettings = nil
        liveSettingsApplying = false
        settingsResult = nil
        settingsMessage = nil
        cancelRestart()
    }

    private func cancelRestart() {
        if let restart = restartRequest { closedLid = restart.previousClosedLid }
        restartRequest = nil
        isRestarting = false
    }

    @discardableResult
    private func requestStop() -> SessionOperationResult {
        if !isRestarting { displayModeDraft = nil }
        display.cancelCountdown()
        guard hasRunningSession else { return .completed }
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
        var status = SessionStatus(phase: .stopped)
        status.setTermination(.requested)
        finish(status)
        return .completed
    }

    private func finish(_ status: SessionStatus) {
        pendingStart = nil
        if let id = configuration?.id {
            if status.reasonCode == .thermal { resources.acceptThermalStop(for: id) }
            if status.reasonCode == .thermal || resources.hasThermalStop(for: id) {
                prepareForThermalStop()
            }
        }
        let wasRestarting = isRestarting
        let wasApplying = liveSettingsApplying || wasRestarting
        if !wasApplying && pendingError == nil && hasSettingsDraft { settingsMessage = nil }
        if let restart = restartRequest {
            if pendingError == nil, status.phase == .stopped, status.sleepRestored, status.reasonCode == .requested {
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
        liveSettingsApplying = false
        display.clearError()
        finishDisplayAndReleaseAssertions()
        helperRequestID = nil
        lastStatus = status
        deadline = nil
        monitor = nil
        let recovered = needsRecovery && status.sleepRestored && status.phase == .stopped
        needsRecovery = status.ownsSleepChange && !status.sleepRestored
        phase = status.phase == .failed || needsRecovery ? .failed : .idle
        let notice: SessionMessage?
        if needsRecovery {
            notice = SessionMessage("%@ Restore normal sleep to continue.", arguments: [status.reason])
        } else if recovered {
            pendingError = nil
            notice = nil
        } else if let pendingError {
            notice = pendingError
        } else if wasRestarting && status.reasonCode == .expired {
            notice = Self.restartExpired
        } else if phase == .idle && (status.reason.isEmpty || [.requested, .startupCancelled, .expired].contains(status.reasonCode)) {
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

    private func finishDisplayAndReleaseAssertions() {
        let id = configuration?.id
        display.finish { [resources] in resources.end(id: id) }
    }

    private func fail(_ text: SessionMessage, requiresSleepConfirmation: Bool = false) {
        displaySettingsApplying = false
        settingsResult = nil
        pendingStart = nil
        let wasApplying = liveSettingsApplying || isRestarting
        powerDraft = nil
        closedLidDraft = nil
        if isRestarting { restoreSavedEndTime() }
        displayModeDraft = nil
        if let restart = restartRequest { closedLid = restart.previousClosedLid }
        restartRequest = nil
        isRestarting = false
        pendingSettings = nil
        liveSettingsApplying = false
        display.clearError()
        if busy, let files { try? sendGuardianStop(files) }
        finishDisplayAndReleaseAssertions()
        helperRequestID = nil
        needsRecovery = needsRecovery || requiresSleepConfirmation || (lastStatus?.ownsSleepChange == true && lastStatus?.sleepRestored != true)
        phase = .failed
        if wasApplying { rejectSettings(text) }
        message = wasApplying ? nil : text
        statusDidChange?()
    }

    private func inspectPreviousSession() {
        guard let path = defaults.string(forKey: "lastSession"),
              let previous = try? SessionFiles(url: URL(fileURLWithPath: path)),
              let config = try? previous.read("configuration.json", as: SessionConfiguration.self), config.closedLid else { return }
        guard let status = try? operations.readGuardianStatus(previous) else {
            files = previous
            configuration = config
            fail("Could not read guardian state.", requiresSleepConfirmation: true)
            return
        }
        if status.phase == .unknown {
            files = previous
            configuration = config
            lastStatus = status
            try? sendGuardianStop(previous)
            fail("Could not read guardian state.", requiresSleepConfirmation: true)
            return
        }
        if status.phase == .preparing {
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
        guard let files, resources.discardUnstarted(files) else { return false }
        forgetSessionFiles(files)
        return true
    }

    private func discardFinishedFiles(_ finished: SessionFiles) {
        if resources.discardFinished(finished) { forgetSessionFiles(finished) }
    }

    private func forgetSessionFiles(_ removed: SessionFiles) {
        if defaults.string(forKey: "lastSession") == removed.url.path {
            defaults.removeObject(forKey: "lastSession")
        }
        if files === removed { files = nil }
    }

    private func refreshRecoveryStatus() -> Bool {
        guard let files, let status = try? operations.readGuardianStatus(files),
              status.phase.isTerminal else { return false }
        if status.sleepRestored {
            finish(status)
            return true
        }
        if status.ownsSleepChange, lastStatus?.phase != status.phase || lastStatus?.reason != status.reason {
            finish(status)
        }
        return false
    }

    private static let recoveryRequired: SessionMessage = "Restore normal sleep first. Use restore-sleep in the CLI or wakecup_restore_sleep in MCP."
    private static let recoveryFailure: SessionMessage = "Could not restore sleep. Try recovery again; if it still fails, use the manual recovery guide."
    private static let recoveryProgress: SessionMessage = "Restoring normal sleep…"

    @discardableResult
    func recover() -> SessionOperationResult {
        if recoveryInProgress { return .pending(Self.recoveryProgress) }
        guard !busy, !helper.working else { return .rejected("Wait until Wakecup has stopped.") }
        guard needsRecovery else { return .completed }
        guard let files else {
            message = Self.recoveryFailure
            return .rejected(Self.recoveryFailure)
        }
        settingsMessage = nil
        if refreshRecoveryStatus() { return .completed }
        let status = try? operations.readGuardianStatus(files)
        let stopFailure: SessionMessage = "Could not send the stop request to the guardian."
        if status == nil || status?.phase == .preparing || (status?.phase == .unknown && status?.sleepRestored == true) {
            do {
                if try confirmGuardianDidNotStart(files, checkSystemSleep: true) {
                    finishCancelledStartup()
                    return .completed
                }
                message = Self.recoveryFailure
                return .rejected(Self.recoveryFailure)
            } catch {
                message = stopFailure
                return .rejected(stopFailure)
            }
        }
        if let status, status.phase.expectsHeartbeat,
           operations.guardianResponding(status, operations.now()) {
            do {
                try sendGuardianStop(files)
                recoveryStartedAt = operations.now()
                recovering = true
                message = Self.recoveryProgress
                phase = .stopping
                return .pending(Self.recoveryProgress)
            } catch {
                message = stopFailure
                return .rejected(stopFailure)
            }
        }
        message = Self.recoveryProgress
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
        if phase == .failed { return .rejected(message ?? Self.recoveryFailure) }
        return needsRecovery ? .pending(waitingForPassword ? "Confirm the macOS authorization prompt." : Self.recoveryProgress) : .completed
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
