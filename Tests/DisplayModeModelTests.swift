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
        let oldCallback = fixture.callbacks[0]
        oldCallback()
        try check(model.displayMode == .mayTurnOff && !model.isBacklightOff && fixture.restores == 1 && model.deadline == deadline && fixture.assertions.last == false, "Shortcut must restore brightness, restore the previous mode and preserve the timer")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        fixture.advance(10, model)
        oldCallback()
        try check(model.isBacklightOff && fixture.entries == 2, "Queued shortcut from a prior registration cannot exit a new blackout")
        fixture.callbacks.last!()
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
        fixture.callbacks.last!()
        try check(model.isBacklightOff && model.displayControlError != nil && !model.canChangeDisplayShortcut, "A failed restore must retain the exit path")
        fixture.restoreFailure = false
        fixture.callbacks.last!()
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
        try resetAndStartupFailure()
        try expiryAndHealth()
        try uncertainEntryRetainsEscape()
        try stopDuringBacklightEntry()
        try stopDuringModeChange()
        try draftAndCountdown()
        try expiryDuringCountdown()
        try settingsFailureDuringCountdown()
        try cancelBacklightCountdown()
    }
    static func resetAndStartupFailure() throws {
        let fixture = try Fixture()
        fixture.defaults.set(Data(#"{"keyCode":15,"modifiers":8}"#.utf8), forKey: "displayRestoreShortcut")
        fixture.defaults.set(DisplayMode.backlightOff.rawValue, forKey: "displayMode")
        let model = fixture.model()
        try check(model.displayMode == .keepOn && model.displayShortcut == nil
            && fixture.defaults.data(forKey: "displayRestoreShortcut") == nil
            && fixture.defaults.string(forKey: "displayMode") == DisplayMode.keepOn.rawValue,
            "Unsupported old chords must be deleted and blackout disarmed without a compatibility path")
        model.editClosedLid(false)
        try model.setDisplayShortcut(shortcut)
        model.selectDisplayMode(.backlightOff)
        let reopened = fixture.model()
        try check(reopened.displayShortcut == shortcut && reopened.displayMode == .backlightOff,
                  "A supported saved F-key chord must remain configured without migration")
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
        try check(model.phase == .idle && model.isBacklightOff, "Failed stop restoration must remain visible and retryable")
        model.start()
        try check(model.phase == .idle && model.isBacklightOff, "Unconfirmed brightness restoration must prevent starting a new timer")
        fixture.restoreFailure = false
        fixture.callbacks.last!()
        try check(!model.isBacklightOff && model.displayMode == .mayTurnOff, "Retained shortcut must recover after failed entry and stop")
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
        try check(model.phase == .active && model.display.transitioning && fixture.restores == 0,
                  "The timer starts while the display worker is still preparing")
        model.stop()
        try check(model.phase == .idle && !fixture.events.contains("stopAssertions"),
                  "Stopping during entry must wait before releasing display assertions")
        model.start()
        try check(model.phase == .idle, "Starting again must wait for the old display transaction")
        fixture.completeEntry?()
        try check(model.isBacklightOff && model.display.transitioning && fixture.restores == 1,
                  "Brightness is restored as soon as the delayed entry finishes")
        fixture.completeRestore?()
        try check(!model.isBacklightOff && !model.display.transitioning && fixture.events.last == "stopAssertions",
                  "Brightness restoration finishes before assertions are released")
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
        try check(model.display.transitioning && !model.canChangeDisplayShortcut,
                  "The escape shortcut stays configured while restoration is pending")
        model.stop()
        fixture.completeRestore?()
        try check(fixture.assertions == [true] && fixture.restores == 1 && fixture.events.last == "stopAssertions",
                  "A display change finishing after Stop cannot reapply display assertions")
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
                fixture.callbacks.last?()
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
        var now = 1000.0
        var assertions: [Bool] = []
        var entries = 0
        var restores = 0
        var callbacks: [() -> Void] = []
        var events: [String] = []
        var entryFailure = false
        var partialEntry = false
        var needsRestoration = false
        var restoreFailure = false
        var validationFailure = false
        var healthy = true
        var lidState: Bool? = false
        var deferEntry = false
        var deferRestore = false
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
        func model() -> SessionModel {
            var ops = SessionOperations(now: { self.now }, readPower: { .init(onAC: true, percent: 80) }, readSleepDisabled: { false },
                startAssertions: { self.assertions.append($0); self.events.append("assertions") },
                stopAssertions: { self.events.append("stopAssertions") },
                createFiles: { try SessionFiles.create(at: self.root.appendingPathComponent($0.id), configuration: $0) },
                guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
                usesInstalledHelper: { false }, startHelper: { _, _, _ in },
                loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}), scheduleTicks: { _ in {} },
                readLidClosed: { self.lidState }, guardianIsRunning: { _ in false },
                enterBacklight: { _, callback, complete in
                    if self.entryFailure {
                        if self.partialEntry { self.needsRestoration = true; self.callbacks.append(callback) }
                        complete(.failure(WakecupError(message: "Fake blackout rejection")), self.needsRestoration)
                        return
                    }
                    self.entries += 1; self.callbacks.append(callback); self.events.append("enter")
                    if self.deferEntry { self.completeEntry = { complete(.success(()), true) } }
                    else { complete(.success(()), true) }
                }, restoreBacklight: { complete in
                    if self.restoreFailure { complete(.failure(WakecupError(message: "Fake restore rejection"))); return }
                    self.restores += 1; self.events.append("restore"); self.needsRestoration = false
                    if self.deferRestore { self.completeRestore = { complete(.success(())) } }
                    else { complete(.success(())) }
                }, validateDisplayShortcut: { _ in if self.validationFailure { throw WakecupError(message: "display.shortcut.conflict") } },
                checkBacklightHealth: { $0(self.healthy) })
            ops.wallNow = { Date(timeIntervalSince1970: 1_794_309_600 + self.now - 1_000) }
            let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in }, interaction: .inert)
            return SessionModel(defaults: defaults, operations: ops, helper: helper)
        }
    }
}
