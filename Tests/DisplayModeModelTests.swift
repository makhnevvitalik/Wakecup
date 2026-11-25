import AppKit
import Foundation

@main struct DisplayModeModelTests {
    static func main() {
        do { try run(); print("PASS: configurable display exit, live mode transactions, lifecycle restoration and stale callbacks") }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static let shortcut = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control | DisplayShortcut.option | DisplayShortcut.command)
    static func check(_ value: Bool, _ message: String) throws { if !value { throw WakecupError(message: message) } }
    static func run() throws {
        try shortcutConflictsAreCheckedBeforeSaving()
        try shortcutRegistrationIsScopedToTheSession()
        try shortcutBlackoutPreservesTheSavedMode()
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        model.selectDisplayMode(.backlightOff)
        try check(model.displayMode == .mayTurnOff && model.displayControlError != nil && fixture.entries == 0, "A missing escape shortcut must prevent blackout")
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        try check(model.displayMode == .backlightOff && model.keepDisplayOn && !model.isBacklightOff && fixture.entries == 0, "Idle selection must configure the next start without darkening now")
        model.start()
        let deadline = model.deadline
        try check(model.phase == .active && !model.isBacklightOff && fixture.entries == 0,
                  "Starting with backlight off must leave the screen visible during the countdown")
        fixture.now += 9
        model.tick()
        try check(!model.isBacklightOff && fixture.entries == 0, "Backlight must stay on for the first nine seconds")
        fixture.now += 1
        model.tick()
        try check(model.phase == .active && model.isBacklightOff && fixture.entries == 1 && fixture.assertions == [true], "Start must hold display awake before darkening")
        try check(!model.canChangeDisplayShortcut, "The only exit must remain configured while dark")
        do { try model.setDisplayShortcut(nil); throw WakecupError(message: "Shortcut unexpectedly removed while dark") }
        catch { try check(model.displayShortcut == shortcut, "Failed removal must retain escape shortcut") }
        fixture.pressShortcut?()
        try check(model.displayMode == .mayTurnOff && !model.isBacklightOff && fixture.restores == 1 && model.deadline == deadline && fixture.assertions.last == false, "Shortcut must restore brightness, restore the previous mode and preserve the timer")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        try check(model.isBacklightOff && fixture.entries == 2, "The next blackout must still work after using the shortcut")
        fixture.pressShortcut?()
        model.selectDisplayMode(.mayTurnOff)
        model.applySettingsDraft()
        try check(!model.keepDisplayOn && fixture.assertions.last == false, "Ordinary display sleep remains available")
        fixture.entryFailure = true
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        try check(model.displayMode == .mayTurnOff && !model.isBacklightOff && model.phase == .active && model.deadline == deadline && fixture.assertions.last == false, "Failed blackout must roll back display assertion and leave timer intact")
        fixture.entryFailure = false
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        fixture.restoreFailure = true
        fixture.pressShortcut?()
        try check(model.isBacklightOff && model.displayControlError != nil && !model.canChangeDisplayShortcut, "A failed restore must retain the exit path")
        fixture.restoreFailure = false
        fixture.pressShortcut?()
        try check(!model.isBacklightOff && model.displayMode == .mayTurnOff, "The same shortcut can retry and restore the previous mode")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        model.stop()
        try check(!model.isBacklightOff && model.phase == .idle && fixture.events.suffix(2) == ["restore", "stopAssertions"], "Stopping the timer must restore brightness before releasing assertions")
        model.selectDisplayMode(.keepOn)
        fixture.validationFailure = true
        do { try model.setDisplayShortcut(DisplayShortcut(keyCode: 122, modifiers: DisplayShortcut.control)); throw WakecupError(message: "Conflicting shortcut unexpectedly saved") }
        catch { try check(model.displayShortcut == shortcut, "A conflict must preserve the working shortcut") }
        fixture.validationFailure = false
        try model.setDisplayShortcut(nil)
        try check(model.displayShortcut == nil, "A shortcut can be cleared after brightness is restored")
        try shortcutRegistrationRecoversAtStart()
        try immediateShortcut()
        try thermalStop()
        try thermalStopWithClosedLid()
        try resetAndStartupFailure()
        try firstUseDisplayModeBelongsToTheOriginatingSession()
        try cancelPausedCountdownReconcilesDisplayDraft()
        try expiryAndHealth()
        try brightnessChangedOutsideWakecup()
        try shortcutWinsWhileBrightnessCheckIsPending()
        try stopWhileConfirmingVisibleBrightness()
        try uncertainEntryRetainsEscape()
        try stopDuringBacklightEntry()
        try pendingDisplayApplyProtectsDraft()
        try stopDuringModeChange()
        try thermalStopBeforeModeChangeCompletion()
        try draftAndCountdown()
        try nonDisplayDraftsPauseCountdown()
        try expiryDuringCountdown()
        try settingsFailureDuringCountdown()
        try cancelBacklightCountdown()
    }

    static func shortcutConflictsAreCheckedBeforeSaving() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        try model.setDisplayShortcut(shortcut)
        let candidate = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control)
        let warning = DisplayShortcutConflict.documentedSystemCommand("Focus Dock")
        fixture.shortcutConflict = warning
        do {
            try model.setDisplayShortcut(candidate)
            throw WakecupError(message: "Unreviewed warning unexpectedly saved")
        } catch let issue as DisplayShortcutReviewRequired {
            try check(issue.conflict == warning && model.displayShortcut == shortcut, "Saving must preserve the existing shortcut until the warning is accepted")
        }
        fixture.shortcutConflict = .system
        do {
            try model.setDisplayShortcut(candidate, reviewedConflict: warning)
            throw WakecupError(message: "New system conflict unexpectedly saved")
        } catch let issue as DisplayShortcutReviewRequired {
            try check(issue.conflict == .system && model.displayShortcut == shortcut, "A new system conflict must block the save")
        }
        fixture.shortcutConflict = warning
        try model.setDisplayShortcut(candidate, reviewedConflict: warning)
        try check(model.displayShortcut == candidate, "The current warning can be confirmed")
        try model.setDisplayShortcut(nil)
        try check(model.displayShortcut == nil, "Clearing requires no conflict confirmation")
    }
    static func shortcutRegistrationIsScopedToTheSession() throws {
        let fixture = try Fixture()
        fixture.defaults.set(try JSONEncoder().encode(LegacyDisplayShortcut(shortcut)), forKey: "displayRestoreShortcut")
        try SettingsMigrator.run(defaults: fixture.defaults)
        let model = fixture.model()
        try check(fixture.pressShortcut == nil, "Launching idle must not register a saved hotkey")
        let replacement = DisplayShortcut(keyCode: 8, modifiers: DisplayShortcut.command)
        try model.setDisplayShortcut(replacement)
        try check(fixture.pressShortcut == nil, "Saving a hotkey while idle must not capture it")
        model.editClosedLid(false)
        model.start()
        try check(model.phase == .active && fixture.pressShortcut != nil,
                  "Starting the timer must activate the saved hotkey")
        model.stop()
        try check(model.phase == .idle && fixture.pressShortcut == nil && model.displayShortcut == replacement,
                  "Stopping a visible session must free the hotkey and keep its setting")
        model.selectEndTimePreset(60)
        model.start()
        fixture.advance(3600, model)
        try check(model.phase == .idle && fixture.pressShortcut == nil, "Timer expiry must free the hotkey")
    }

    static func shortcutBlackoutPreservesTheSavedMode() throws {
        for mode in [DisplayMode.mayTurnOff, .keepOn] {
            let fixture = try Fixture()
            fixture.defaults.set(mode.rawValue, forKey: "displayMode")
            var model: SessionModel? = fixture.model()
            model?.editClosedLid(false)
            try model?.setDisplayShortcut(shortcut)
            model?.start()
            fixture.pressShortcut?()
            try check(model?.isBacklightOff == true, "The shortcut must turn off the backlight immediately")
            model = nil // Simulate the model disappearing without its shutdown path.
            let reopened = fixture.model()
            reopened.start()
            try check(reopened.phase == .active && reopened.displayMode == mode && reopened.backlightCountdown == nil,
                      "A temporary blackout must not be saved as the display mode for the next timer")
        }
    }

    static func shortcutRegistrationRecoversAtStart() throws {
        let fixture = try Fixture()
        fixture.defaults.set(try JSONEncoder().encode(shortcut), forKey: SettingsKey.displayRestoreShortcut)
        fixture.validationFailure = true
        let model = fixture.model()
        model.editClosedLid(false)
        try check(fixture.pressShortcut == nil && model.displayControlError == nil,
                  "An idle launch does not try to register a conflicting saved hotkey")

        model.start()
        try check(model.phase == .active && model.displayControlError?.key == "display.shortcut.conflict",
                  "A persistent conflict must stay visible without preventing the timer")
        model.stop()

        fixture.validationFailure = false
        model.start()
        try check(model.phase == .active && model.displayControlError == nil,
                  "Starting a new timer must clear a resolved conflict")
        fixture.pressShortcut?()
        try check(model.isBacklightOff, "The saved chord must work again without reconfiguring it")
    }

    static func immediateShortcut() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(DisplayShortcut(keyCode: 0, modifiers: DisplayShortcut.control))
        fixture.pressShortcut?()
        try check(model.phase == .idle && fixture.entries == 0, "The shortcut must do nothing without a timer")
        model.start()
        let deadline = model.deadline
        fixture.pressShortcut?()
        try check(model.isBacklightOff && model.backlightCountdown == nil, "The shortcut must darken immediately")
        fixture.pressShortcut?()
        try check(!model.isBacklightOff && model.deadline == deadline, "The same shortcut must restore brightness without stopping the timer")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        try check(model.backlightCountdown == 10, "Selecting the mode through the menu must still start a countdown")
        fixture.pressShortcut?()
        try check(model.isBacklightOff && model.backlightCountdown == nil && model.deadline == deadline,
                  "The shortcut must finish an existing countdown immediately")
    }

    static func thermalStop() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        fixture.thermalState = .serious
        try model.setDisplayShortcut(shortcut)
        model.start()
        try check(model.phase == .active, "The default critical threshold must allow serious")
        fixture.pressShortcut?()
        fixture.thermalState = .critical
        fixture.checkTemperature()
        model.tick()
        try check(model.phase == .idle && !model.isBacklightOff && fixture.events.suffix(2) == ["stopAssertions", "restore"],
                  "Critical must release sleep assertions independently of brightness restoration")
        try check(model.message?.key == "Wakecup stopped because the Mac is too hot.", "The status must explain the stop")
        model.start()
        try check(model.phase != .active, "An already critical Mac must not start a session")
        fixture.thermalState = .nominal
        model.tick()
        try check(model.phase != .active, "Cooling down must not restart the session")
        model.setThermalStopLevel(.serious)
        let reopened = fixture.model()
        try check(reopened.thermalStopLevel == .serious, "The selected thermal threshold must persist")
        reopened.start()
        fixture.thermalState = .serious
        fixture.checkTemperature()
        reopened.tick()
        try check(reopened.phase == .idle && reopened.message?.key == "Wakecup stopped because the Mac is too hot.",
                  "The earlier threshold must stop the session at serious")
    }

    static func thermalStopWithClosedLid() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(true)
        try model.setDisplayShortcut(shortcut)
        model.start()
        guard let files = fixture.sessionFiles else { throw WakecupError(message: "Missing closed-lid session files") }
        var status = SessionStatus(phase: .active, helperPID: getpid(), phaseChangedAt: fixture.now,
                                   ownsSleepChange: true, sleepRestored: false)
        try files.write(status, to: "status.json")
        model.tick()
        try check(model.phase == .active, "The guardian must first be active")
        fixture.pressShortcut?()
        fixture.deferRestore = true
        fixture.thermalState = .critical
        fixture.checkTemperature()
        model.tick()
        let control = try files.read("control.json", as: SessionControl.self)
        try check(model.phase == .stopping && control.stop && control.thermalStopRequested == true,
                  "A thermal stop must latch a typed request for the guardian to restore sleep")
        status.phase = .stopped
        status.reason = "остановлено"
        status.sleepRestored = true
        try files.write(status, to: "status.json")
        model.tick()
        try check(model.busy && model.isBacklightOff && fixture.pressShortcut != nil,
                  "The guardian can finish before brightness and the shortcut are released")
        model.tick()
        fixture.completeRestore?()
        try check(!model.busy && !model.isBacklightOff && fixture.pressShortcut == nil,
                  "Returning control must finish after both guardian and display are done")
        try check(model.phase == .idle && !model.needsRecovery && model.message?.key == "Wakecup stopped because the Mac is too hot.",
                  "Wait for the guardian and retain the thermal stop reason")
    }

    static func firstUseDisplayModeBelongsToTheOriginatingSession() throws {
        for startReplacement in [false, true] {
            let fixture = try Fixture()
            let model = fixture.model()
            model.editClosedLid(false)
            model.start()
            var finishShortcutSetup: ((Bool) -> Void)?
            model.selectDisplayMode(.backlightOff) { finishShortcutSetup = $0 }
            try check(finishShortcutSetup != nil && !model.hasSettingsDraft, "The mode must wait for a shortcut")
            fixture.advance(3601, model)
            try check(model.phase == .idle, "The original session must expire while shortcut setup is open")
            if startReplacement { model.start() }
            try model.setDisplayShortcut(shortcut)
            finishShortcutSetup?(true)
            try check(model.displayShortcut == shortcut && model.displayMode == .mayTurnOff && !model.hasSettingsDraft,
                      "Saving a shortcut must not apply an expired request to another session or the idle preferences")
        }

        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        model.start()
        var finishShortcutSetup: ((Bool) -> Void)?
        model.selectDisplayMode(.backlightOff) { finishShortcutSetup = $0 }
        try model.setDisplayShortcut(shortcut)
        finishShortcutSetup?(true)
        try check(model.displayMode == .mayTurnOff && model.displayModeDraft == .backlightOff && model.showsSettingsActions,
                  "Finishing setup in the original session must stage the requested mode for Apply")
    }

    static func cancelPausedCountdownReconcilesDisplayDraft() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.keepOn)
        model.selectDisplayMode(.backlightOff)
        model.start()
        try check(model.backlightCountdown != nil, "Backlight off must start the countdown")
        model.selectDisplayMode(.keepOn)
        try check(model.backlightCountdown == nil && model.showsSettingsActions, "A display draft must pause the countdown")
        model.cancelBacklightCountdown()
        try check(model.displayMode == .keepOn && !model.showsSettingsActions,
                  "Cancel must restore the previous mode and clear a matching draft")
        fixture.advance(15, model)
        try check(fixture.entries == 0, "Cancelling a paused countdown must prevent blackout")
    }

    static func resetAndStartupFailure() throws {
        let fixture = try Fixture()
        fixture.defaults.set(Data(#"{"keyCode":15,"modifiers":1}"#.utf8), forKey: "displayRestoreShortcut")
        try SettingsMigrator.run(defaults: fixture.defaults)
        fixture.defaults.set(DisplayMode.backlightOff.rawValue, forKey: "displayMode")
        let model = fixture.model()
        try check(model.displayMode == .keepOn && model.displayShortcut == nil
            && fixture.defaults.data(forKey: "displayRestoreShortcut") == nil
            && fixture.defaults.string(forKey: "displayMode") == DisplayMode.keepOn.rawValue,
            "Incompatible stored chords must be cleared and blackout disarmed")
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        let reopened = fixture.model()
        try check(reopened.displayShortcut == shortcut && reopened.displayMode == .backlightOff,
                  "Reopening must retain a saved F-key chord in the current format")
        fixture.entryFailure = true
        model.start()
        fixture.advance(10, model)
        try check(model.phase == .active && model.displayMode == .keepOn && !model.isBacklightOff && model.displayControlError != nil, "Failed startup blackout must keep a visible active timer")
        model.stop()
    }
    static func expiryAndHealth() throws {
        for healthFailure in [false, true] {
            let fixture = try Fixture()
            let model = fixture.model()
            model.editClosedLid(false)
            try model.setDisplayShortcut(shortcut)
            model.selectEndDate(model.currentDate.addingTimeInterval(60))
            model.selectDisplayMode(.backlightOff); model.start()
            fixture.advance(10, model)
            if healthFailure { fixture.healthy = false }
            else { fixture.now += 60 }
            model.tick()
            try check(!model.isBacklightOff && fixture.restores == 1, "Expiry or restorer loss must restore brightness")
            try check(model.phase == (healthFailure ? .active : .idle), "Restorer loss must not reset/stop a healthy sleep timer")
            model.stop()
        }
    }
    static func brightnessChangedOutsideWakecup() throws {
        for previousMode: DisplayMode in [.mayTurnOff, .keepOn] {
            let fixture = try Fixture()
            let model = fixture.model()
            model.editClosedLid(false)
            try model.setDisplayShortcut(shortcut)
            model.selectDisplayMode(previousMode)
            model.selectDisplayMode(.backlightOff)
            model.start()
            let deadline = model.deadline
            fixture.advance(10, model)
            fixture.brightnessReturned = true
            fixture.advance(1, model)
            try check(!model.isBacklightOff && model.displayMode == previousMode
                      && model.phase == .active && model.deadline == deadline
                      && fixture.assertions.last == previousMode.keepsDisplayOn && fixture.restores == 0,
                      "Brightness changes outside Wakecup must return to the previous mode without writing brightness or stopping the timer")
            try check(fixture.defaults.string(forKey: "displayMode") == previousMode.rawValue,
                      "The previous display mode must also be saved")
            model.stop()
            fixture.pressShortcut?()
            try check(fixture.restorationPolicies == [.visibleOnly] && fixture.restores == 0 && fixture.entries == 1,
                      "Stopping after manual restore and pressing the idle shortcut must leave brightness alone")
        }
    }

    static func shortcutWinsWhileBrightnessCheckIsPending() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)

        fixture.brightnessReturned = true
        fixture.deferBacklightCheck = true
        fixture.deferRestore = true
        fixture.advance(1, model)
        fixture.pressShortcut?()
        fixture.completeBacklightCheck?()
        try check(fixture.restorationPolicies == [.saved] && model.isDisplayTransitioning,
                  "A pending read must not replace the accepted hotkey restore")
        fixture.completeRestore?()
        try check(!model.isBacklightOff && model.displayMode == .mayTurnOff && fixture.restores == 1,
                  "The accepted hotkey restore must return to the previous mode")
        model.stop()
    }

    static func stopWhileConfirmingVisibleBrightness() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)

        fixture.brightnessReturned = true
        fixture.deferRestore = true
        fixture.advance(1, model)
        model.stop()
        try check(model.busy && !model.canEditSessionSettings
                  && fixture.restorationPolicies == [.visibleOnly] && !fixture.events.contains("stopAssertions"),
                  "Stopping stays in progress while the brightness confirmation is pending")
        fixture.brightnessReturned = false
        fixture.completeRestore?()
        try check(fixture.restorationPolicies == [.visibleOnly, .preserveVisible] && model.isDisplayTransitioning,
                  "Stopping must still restore brightness if the display went dark again")
        fixture.completeRestore?()
        try check(!model.isBacklightOff && model.phase == .idle && fixture.events.last == "stopAssertions",
                  "Stopping must clear the blackout before releasing display assertions")
    }

    static func uncertainEntryRetainsEscape() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.start()
        fixture.entryFailure = true; fixture.partialEntry = true; fixture.restoreFailure = true
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        try check(model.isBacklightOff && !model.canChangeDisplayShortcut && model.displayControlError != nil,
                  "Uncertain entry rollback must retain the registered escape action")
        model.stop()
        try check(model.phase == .idle && model.isBacklightOff && fixture.pressShortcut != nil,
                  "Failed stop restoration must remain visible and keep the escape hotkey")
        model.start()
        try check(model.phase == .idle && model.isBacklightOff, "Unconfirmed brightness restoration must prevent starting a new timer")
        fixture.restoreFailure = false
        fixture.pressShortcut?()
        try check(!model.isBacklightOff && model.displayMode == .mayTurnOff && fixture.pressShortcut == nil,
                  "Successful recovery after stop must release the escape hotkey")
    }
    static func stopDuringBacklightEntry() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        fixture.deferEntry = true
        fixture.deferRestore = true
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)
        try check(model.phase == .active && model.isDisplayTransitioning && fixture.restores == 0,
                  "The timer starts while the display worker is still preparing")
        model.stop()
        try check(model.busy && !fixture.events.contains("stopAssertions"),
                  "Stopping during entry must stay busy until display assertions can be released")
        model.start()
        try check(model.busy && fixture.assertions.count == 1, "Starting again must wait for the old display transaction")
        fixture.completeEntry?()
        try check(model.isBacklightOff && model.isDisplayTransitioning && fixture.restores == 1,
                  "Brightness is restored as soon as the delayed entry finishes")
        fixture.completeRestore?()
        try check(!model.busy && !model.isBacklightOff && !model.isDisplayTransitioning
                  && fixture.events.last == "stopAssertions" && fixture.pressShortcut == nil,
                  "Brightness restoration and resource release must finish before the session becomes idle")
    }

    static func pendingDisplayApplyProtectsDraft() throws {
        for combined in [false, true] {
            let fixture = try Fixture()
            let model = fixture.model()
            model.editClosedLid(false)
            try model.setDisplayShortcut(shortcut)
            model.selectDisplayMode(.backlightOff)
            model.start()
            defer { model.stop() }
            fixture.advance(10, model)
            fixture.deferRestore = true
            model.selectDisplayMode(.keepOn)
            if combined { model.editThreshold(30) }

            model.applySettingsDraft()
            try check(model.settingsApplying && model.isDisplayTransitioning && model.showsSettingsActions
                      && !model.canEditSettingsDraft && !model.canApplySettingsDraft,
                      "Applying must stay in progress until brightness restoration finishes")
            model.discardSettingsDraft()
            model.editThreshold(35)
            try check(model.displayModeDraft == .keepOn && model.selectedThreshold == (combined ? 30 : 20),
                      "Cancel, panel close and further edits must leave the pending apply intact")

            fixture.restoreFailure = true
            fixture.completeRestore?()
            try check(!model.settingsApplying && model.canEditSettingsDraft && model.canApplySettingsDraft
                      && model.displayMode == .backlightOff && model.displayModeDraft == .keepOn
                      && model.settingsMessage != nil && model.deadline != nil
                      && model.threshold == (combined ? 30 : 20),
                      "A failed restore must preserve the unapplied display draft and any confirmed settings")

            fixture.restoreFailure = false
            model.applySettingsDraft()
            try check(model.settingsApplying && model.displayModeDraft == .keepOn,
                      "Retrying must track the new brightness restore")
            fixture.completeRestore?()
            try check(!model.settingsApplying && model.displayMode == .keepOn && model.settingsMessage == nil
                      && !model.showsSettingsActions && model.phase == .active,
                      "Only a successful display apply may clear the draft")
        }
    }

    static func stopDuringModeChange() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)
        fixture.deferRestore = true
        model.selectDisplayMode(.mayTurnOff)
        model.applySettingsDraft()
        try check(model.isDisplayTransitioning && !model.canChangeDisplayShortcut,
                  "The escape shortcut stays configured while restoration is pending")
        model.stop()
        fixture.completeRestore?()
        try check(fixture.assertions == [true] && fixture.restores == 1 && fixture.events.last == "stopAssertions",
                  "A display change finishing after Stop cannot reapply display assertions")
    }

    static func thermalStopBeforeModeChangeCompletion() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)
        fixture.deferRestore = true
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try check(model.isDisplayTransitioning && model.isBacklightOff, "The mode change must wait for brightness restoration")

        fixture.thermalState = .critical
        fixture.checkTemperature()
        // Deliver the queued display callback before processing the thermal model callback.
        fixture.completeRestore?()
        try check(model.displayMode == .mayTurnOff && fixture.defaults.string(forKey: "displayMode") == "mayTurnOff",
                  "A late display change must not save its requested mode after the thermal stop")
        model.tick()
        try check(model.phase == .idle && model.message?.key == SessionTermination.thermal.text,
                  "The late display callback must still let the model finish with the thermal reason")
    }

    static func draftAndCountdown() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        model.selectDisplayMode(.keepOn)
        try check(model.displayMode == .keepOn && model.displayModeDraft == nil && model.canChangeDisplayShortcut,
                  "An open but idle Wakecup applies display choices immediately and allows shortcut editing")
        try model.setDisplayShortcut(shortcut)
        model.start()
        model.selectDisplayMode(.backlightOff)
        try check(model.displayModeDraft == .backlightOff && model.displayMode == .keepOn && model.backlightCountdown == nil,
                  "An active session requires Apply before a blackout countdown")
        fixture.advance(11, model)
        try check(fixture.entries == 0, "An unapplied draft cannot darken the screen")
        model.discardSettingsDraft()
        try check(model.displayModeDraft == nil && model.displayMode == .keepOn, "Cancel keeps the current mode")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        try check(model.displayModeDraft == nil && model.backlightCountdown == 10 && model.canChangeDisplayShortcut,
                  "Applying the mode starts a visible countdown and leaves shortcut editing available")
        fixture.advance(7, model)
        model.beginDisplayShortcutEditing()
        fixture.advance(12, model)
        try check(fixture.entries == 0, "The shortcut editor cannot be darkened by a countdown")
        model.endDisplayShortcutEditing()
        try check(model.backlightCountdown == 10, "Closing the editor starts a fresh countdown")
        model.selectDisplayMode(.mayTurnOff)
        fixture.advance(12, model)
        try check(fixture.entries == 0 && model.displayMode == .backlightOff,
                  "A pending display draft pauses the countdown")
        model.applySettingsDraft()
        fixture.advance(12, model)
        try check(fixture.entries == 0 && model.displayMode == .mayTurnOff && model.backlightCountdown == nil,
                  "Applying a different mode cancels the countdown")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        model.stop()
        fixture.advance(12, model)
        try check(fixture.entries == 0 && model.phase == .idle && model.backlightCountdown == nil,
                  "Stop cancels the countdown before any brightness write")
    }

    static func nonDisplayDraftsPauseCountdown() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        defer { model.stop() }

        for edit in [{ model.editThreshold(30) }, { model.editClosedLid(true) }] {
            edit()
            try check(model.showsSettingsActions && model.backlightCountdown == nil,
                      "Both power edits and lid edits must suspend the countdown on their own")
            model.discardSettingsDraft()
            try check(model.backlightCountdown == 10, "Discarding the draft must restart the countdown")
        }
        model.selectEndTimePreset(180)
        try check(model.backlightCountdown == nil, "A time edit alone must suspend the countdown")
        model.editThreshold(30)
        model.editClosedLid(true)
        try check(model.showsSettingsActions && model.backlightCountdown == nil,
                  "A settings draft must suspend the countdown before replacing its cancel button")
        fixture.advance(12, model)
        try check(fixture.entries == 0, "The backlight must stay on while the draft is pending")

        model.editClosedLid(false)
        model.editThreshold(20)
        try check(model.showsSettingsActions && model.backlightCountdown == nil,
                  "Reverting two edits must keep the countdown suspended while a time edit remains")
        model.applySettingsDraft()
        try check(!model.showsSettingsActions && model.backlightCountdown == 10,
                  "Applying an unrelated edit must start a fresh countdown")

        fixture.advance(4, model)
        model.setEndTimeInputInvalid(true)
        try check(model.showsSettingsActions && !model.canApplySettingsDraft && model.backlightCountdown == nil,
                  "Invalid time input must suspend the countdown and leave only Cancel available")
        fixture.advance(12, model)
        try check(fixture.entries == 0, "Invalid time input must keep the backlight on")
        model.discardSettingsDraft()
        try check(!model.showsSettingsActions && model.backlightCountdown == 10,
                  "Discarding a draft must start a fresh countdown")
    }

    static func cancelBacklightCountdown() throws {
        for previousMode: DisplayMode in [.mayTurnOff, .keepOn] {
            for chooseBeforeStart in [false, true] {
                let fixture = try Fixture()
                var model = fixture.model()
                model.editClosedLid(false)
                try model.setDisplayShortcut(shortcut)
                model.selectDisplayMode(previousMode)
                if chooseBeforeStart {
                    model.selectDisplayMode(.backlightOff)
                    model = fixture.model()
                }
                model.start()
                let deadline = model.deadline
                if !chooseBeforeStart {
                    model.selectDisplayMode(.backlightOff)
                    model.applySettingsDraft()
                }
                try check(model.backlightCountdown == 10, "Backlight off must show a countdown")
                model.cancelBacklightCountdown()
                fixture.advance(12, model)
                try check(model.displayMode == previousMode && model.backlightCountdown == nil
                    && model.phase == .active && model.deadline == deadline && fixture.entries == 0
                    && fixture.assertions.last == previousMode.keepsDisplayOn,
                    "Cancelling must restore the previous display mode and its assertion without touching brightness or the sleep timer")
                model.selectDisplayMode(.backlightOff)
                model.applySettingsDraft()
                fixture.advance(10, model)
                try check(model.isBacklightOff && fixture.entries == 1, "Applying blackout again must still work")
                fixture.pressShortcut?()
                try check(!model.isBacklightOff && model.displayMode == previousMode && model.deadline == deadline
                    && fixture.restores == 1 && fixture.assertions.last == previousMode.keepsDisplayOn,
                    "The shortcut must restore brightness and the same previous mode without changing the timer")
                model.stop()
            }
        }
    }

    static func expiryDuringCountdown() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectEndDate(model.currentDate.addingTimeInterval(10))
        model.selectDisplayMode(.backlightOff)
        model.start()
        fixture.advance(10, model)
        try check(model.phase == .idle && fixture.entries == 0 && model.backlightCountdown == nil,
                  "Session expiry wins when it coincides with the countdown deadline")
    }

    static func settingsFailureDuringCountdown() throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        model.start()
        let deadline = model.deadline
        fixture.lidState = nil
        model.editClosedLid(true)
        model.applySettingsDraft()
        try check(model.settingsMessage?.key == "Open the lid before changing closed-lid mode.",
                  "A failed lid change must report the error immediately")
        fixture.advance(11, model)
        try check(fixture.entries == 0 && model.phase == .active && model.deadline == deadline
                  && model.displayMode == .mayTurnOff && model.backlightCountdown == nil,
                  "A failed Apply must cancel an existing blackout and restore the previous display mode")
        model.discardSettingsDraft()
        fixture.advance(11, model)
        try check(fixture.entries == 0 && model.backlightCountdown == nil,
                  "Dismissing the error must not re-arm the blackout")
        model.editClosedLid(true)
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(11, model)
        try check(model.settingsMessage != nil && model.displayModeDraft == .backlightOff
                  && model.displayMode == .mayTurnOff && model.backlightCountdown == nil
                  && fixture.entries == 0 && model.deadline == deadline,
                  "A new blackout request must stay unapplied when the earlier lid change fails")
        model.stop()
    }

    final class Fixture {
        let suite = "WakecupDisplayModeTest-" + UUID().uuidString
        let defaults: UserDefaults
        let root: URL
        var sessionFiles: SessionFiles?
        var now = 1000.0
        var thermalState: ProcessInfo.ThermalState = .nominal
        var checkTemperature: () -> Void = {}
        var pressShortcut: (() -> Void)?
        var assertions: [Bool] = []
        var entries = 0
        var restores = 0
        var restorationPolicies: [DisplayModeController.RestorationPolicy] = []
        var events: [String] = []
        var entryFailure = false
        var partialEntry = false
        var needsRestoration = false
        var restoreFailure = false
        var validationFailure = false
        var healthy = true
        var brightnessReturned = false
        var lidState: Bool? = false
        var deferEntry = false
        var deferRestore = false
        var deferBacklightCheck = false
        var completeBacklightCheck: (() -> Void)?
        var completeEntry: (() -> Void)?
        var completeRestore: (() -> Void)?
        init() throws {
            defaults = UserDefaults(suiteName: suite)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        deinit { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        func advance(_ seconds: TimeInterval, _ model: SessionModel) {
            now += seconds
            model.tick()
        }
        var shortcutConflict: DisplayShortcutConflict?

        func model() -> SessionModel {
            var ops = SessionOperations(now: { self.now }, readPower: { .init(onAC: true, percent: 80) }, readSleepDisabled: { false },
                startAssertions: { self.assertions.append($0); self.events.append("assertions") },
                stopAssertions: { self.events.append("stopAssertions") },
                createFiles: { configuration in
                    let files = try SessionFiles.create(at: self.root.appendingPathComponent(configuration.id), configuration: configuration)
                    self.sessionFiles = files
                    return files
                },
                guardianResponding: { _, _ in true }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
                usesInstalledHelper: { false }, startHelper: { _, _, _ in },
                loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}), scheduleTicks: { _ in {} },
                readLidClosed: { self.lidState }, guardianIsRunning: { _ in false },
                enterBacklight: { _, complete in
                    if self.entryFailure {
                        if self.partialEntry { self.needsRestoration = true }
                        complete(.failure(WakecupError(message: "Fake blackout rejection")), self.needsRestoration)
                        return
                    }
                    self.entries += 1; self.events.append("enter")
                    if self.deferEntry { self.completeEntry = { complete(.success(()), true) } }
                    else { complete(.success(()), true) }
                }, restoreBacklight: { policy, complete in
                    self.restorationPolicies.append(policy)
                    let finish = {
                        if self.restoreFailure {
                            complete(.failure(WakecupError(message: "Fake restore rejection")))
                        } else {
                            if policy != .visibleOnly { self.needsRestoration = false }
                            complete(.success(policy != .visibleOnly || self.brightnessReturned))
                        }
                    }
                    if !self.restoreFailure && policy != .visibleOnly {
                        self.restores += 1; self.events.append("restore")
                    }
                    if self.deferRestore { self.completeRestore = finish }
                    else { finish() }
                }, validateDisplayShortcut: { _ in if self.validationFailure { throw WakecupError(message: "display.shortcut.conflict") } },
                checkBacklight: { complete in
                    let state: DisplayModeController.BacklightState
                    if self.brightnessReturned { state = .brightnessReturned }
                    else { state = self.healthy ? .monitoring : .restorerStopped }
                    if self.deferBacklightCheck { self.completeBacklightCheck = { complete(state) } }
                    else { complete(state) }
                })
            ops.checkDisplayShortcutConflict = { _ in self.shortcutConflict }
            ops.readThermalState = { self.thermalState }
            ops.scheduleThermalChecks = { [weak self] check in
                self?.checkTemperature = check
                return {}
            }
            ops.registerDisplayShortcut = { _, handler in
                if self.validationFailure { throw WakecupError(message: "display.shortcut.conflict") }
                self.pressShortcut = handler
            }
            ops.unregisterDisplayShortcut = { self.pressShortcut = nil }
            ops.wallNow = { Date(timeIntervalSince1970: 1_794_309_600 + self.now - 1_000) }
            let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
            return SessionModel(defaults: defaults, operations: ops, helper: helper)
        }
    }
}
