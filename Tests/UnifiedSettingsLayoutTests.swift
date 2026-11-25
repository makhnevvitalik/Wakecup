import AppKit
import SwiftUI

// Offscreen only. Every power, assertion, authorization, helper and liveness
// operation is fake; the isolated suite never reads the user's saved session.
@main struct UnifiedSettingsLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        NSTimeZone.default = TimeZone(identifier: "Asia/Yekaterinburg")!
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        guard let resources = Bundle.main.resourceURL else { throw WakecupError(message: "Missing test bundle resources") }
        let data = try Data(contentsOf: resources.appendingPathComponent(language + ".lproj/Localizable.strings"))
        let translations = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
        for key in ["Run time", "Stop at", "Today", "Tomorrow", "Choose date…", "End time", "Until %@ (%@)", "%@ tomorrow", "New stop time", "Enter a time such as %@.", "Active until %@", "Choose an end date within the next 30 days.", "Until stopped manually", "Apply", "Cancel edits", "Backlight turns off in %@", "%ld s", "Cancel backlight countdown", "Cancel turning off the backlight", "Applying settings…", "The Wakecup timer ended. “Keep awake with lid closed” was not changed.", "Display backlight", "May turn off", "Keep on", "Backlight off", "Backlight shortcut", "Configure…", "Change…", "Not assigned", "Configure backlight shortcut", "Change backlight shortcut"] {
            try expect(translations[key] != nil && localized(key) == translations[key], "Fixture must load the real \(language) translation: \(key)")
        }
        let suite = "WakecupUnifiedSettings-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "closedLid")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let fixture = Fixture()
        let helper = PrivilegedHelperController(defaults: defaults,
            makeInstallationTask: { _ in throw WakecupError(message: "Unexpected helper installation") },
            inspectInstallation: { .init(state: .unavailable) }, requestInformation: { _ in })
        var operations = SessionOperations(now: { fixture.now }, readPower: { .init(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in
                if fixture.rejectDisplay { throw WakecupError(message: "Fake display assertion failure") }
            }, stopAssertions: {}, createFiles: {
                let files = try SessionFiles.create(at: directory.appendingPathComponent($0.id), configuration: $0)
                fixture.files = files
                return files
            }, guardianResponding: { _, _ in true },
            authorization: { _, _ in .init(run: { fixture.authorization = $0 }, cancel: {}) },
            usesInstalledHelper: { false }, startHelper: { _, _, _ in fixture.unexpectedHelperCall = true },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} }, readLidClosed: { fixture.lidState }, guardianIsRunning: { _ in false })
        operations.wallNow = { Date(timeIntervalSince1970: 1_794_309_600 + fixture.now - 1000) }
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        let host = NSHostingController(rootView: WakecupLayoutFixture(model: model, updates: UpdateChecker(), showAbout: {})
            .environment(\.locale, Locale(identifier: "en-GB-u-hc-h23"))
            .background(Color(nsColor: NSColor(calibratedWhite: 0.91, alpha: 1))))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { model.stop(); window.orderOut(nil) }

        @MainActor func layout(_ name: String) throws -> NSSize {
            for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.04)); host.view.layoutSubtreeIfNeeded() }
            let size = host.view.fittingSize
            try expect(abs(size.width - MenuLayout.width) < 1, "Unified settings widened the menu: \(name)")
            if model.settingsMessage == nil && model.displayControlError == nil {
                try expect(size.height <= 760, "Normal menu must fit a 760-point height without smaller text or scrolling: \(name), \(size.height)")
            }

            host.view.setFrameSize(size); window.setContentSize(size); host.view.layoutSubtreeIfNeeded()
            host.view.displayIfNeeded()
            if model.phase == .active && model.durationEditDirty,
               let heading = descendants(host.view).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == localized("Run time") }) {
                let needed = (heading.stringValue as NSString).size(withAttributes: [.font: AppStyle.Font.sectionTitle]).width
                try expect(heading.bounds.width + 1 >= needed, "The time heading must fit while editing: " + name)
            }
            if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-unified-\(language)-\(name).png"))
                }
            }
            return size
        }
        func fields() -> [NSTextField] {
            descendants(host.view).compactMap { $0 as? NSTextField }
                .filter { $0.identifier?.rawValue == "WakecupEndTime" }
                .sorted { $0.identifier!.rawValue < $1.identifier!.rawValue }
        }
        func checkControls(enabled: Bool) throws {
            let all = descendants(host.view)
            let switches = all.compactMap { $0 as? NSSwitch }
            try expect(switches.count == 2, "Lid and battery switches must remain visible beside the three-mode display picker")
            // SwiftUI owns accessibility names above the AppKit bridge; this
            // known options tree exposes native switches in lid/battery order.
            let preferences = [("lid", model.selectedClosedLid), ("battery", model.selectedAllowBattery)]
            for (toggle, preference) in zip(switches, preferences) {
                try expect(toggle.state == (preference.1 ? .on : .off), "Native switch must show the current preference: \(preference.0)")
            }
            let display = all.compactMap { $0 as? NSPopUpButton }.first { $0.identifier?.rawValue == "WakecupDisplayMode" }
            try expect(display?.numberOfItems == 3 && display?.isEnabled == enabled, "All three native display choices must follow transition availability")
            let modes: [DisplayMode] = [.mayTurnOff, .keepOn, .backlightOff]
            try expect(display?.indexOfSelectedItem == modes.firstIndex(of: model.displayModeDraft ?? model.displayMode), "The picker must show the draft when present")
            try expect(all.compactMap { $0 as? NSSlider }.count == 1, "The battery threshold slider must remain visible")
            let pickers = all.compactMap { $0 as? NSSegmentedControl }
            try expect(pickers.count == 1 && pickers[0].segmentCount == 4, "All duration presets must remain visible")
            try expect(pickers[0].isEnabled == enabled, "Native preset control must follow transition availability")
            try expect(fields().count == 1 && fields().allSatisfy { $0.isEnabled == enabled && $0.isEditable == enabled },
                       "The native end-time editor must follow transition availability")
        }
        var setupRequests = 0
        var completeSetup: ((Bool) -> Void)?
        func requestSetup(_ completion: @escaping (Bool) -> Void) {
            setupRequests += 1
            completeSetup = completion
        }
        model.selectDisplayMode(.keepOn)
        model.selectDisplayMode(.backlightOff, configureShortcut: requestSetup)
        try expect(setupRequests == 1 && model.displayMode == .keepOn && model.displayShortcut == nil,
                   "The editor must leave the previous mode selected while setup is open")
        completeSetup?(false)
        try expect(model.displayMode == .keepOn && model.displayShortcut == nil,
                   "First-use Cancel must keep the previous display mode")
        model.selectDisplayMode(.backlightOff, configureShortcut: requestSetup)
        completeSetup?(true)
        try expect(model.displayMode == .keepOn, "Closing setup without a shortcut cannot select Backlight off")
        let chosen = DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control | DisplayShortcut.option)
        model.selectDisplayMode(.backlightOff, configureShortcut: requestSetup)
        try model.setDisplayShortcut(chosen)
        try expect(model.displayMode == .keepOn, "Do not change the mode while setup is still open")
        completeSetup?(true)
        try expect(setupRequests == 3 && model.displayMode == .backlightOff && !model.isBacklightOff,
                   "Successful first-use setup must select the requested idle mode without darkening")
        model.selectDisplayMode(.mayTurnOff)
        model.selectDisplayMode(.backlightOff, configureShortcut: requestSetup)
        try expect(setupRequests == 3 && model.displayMode == .backlightOff,
                   "An existing shortcut must avoid repeated setup prompts")
        model.selectDisplayMode(.mayTurnOff)
        try model.setDisplayShortcut(nil)
        let card = StopTimeCard(model: model)
        let clock = StopTimeInput.Clock(locale: Locale(identifier: "en-GB-u-hc-h23"))
        let idleCaption = card.caption(using: clock)
        let offSize = try layout("off")
        try checkControls(enabled: true)
        model.selectEndDate(model.currentDate.addingTimeInterval(-60))
        let invalidSize = try layout("invalid-off")
        try expect(!model.durationInputIsValid && abs(invalidSize.height - offSize.height) < 1,
                   "Invalid duration must expose its correction in place without changing the panel height")
        model.selectEndTimePreset(60)
        let originalEditors = fields()
        let switches = descendants(host.view).compactMap { $0 as? NSSwitch }
        let toggleWidth = switches.map { $0.fittingSize.width }.max() ?? 40
        for key in ["Keep awake with lid closed", "Keep awake on battery"] {
            let hintWidth: CGFloat = 24
            let available = MenuLayout.width - 2 * (AppStyle.Layout.panelInset + AppStyle.Layout.cardInset) - toggleWidth - AppStyle.Layout.rowItemSpacing - hintWidth
            try expect((localized(key) as NSString).size(withAttributes: [.font: AppStyle.Font.body]).width < available,
                       "Translated option label must fit beside its switch: \(key)")
        }
        model.start()
        try expect(model.phase == .active, "Fake open-lid session must start")
        let activeSize = try layout("active")
        try expect(abs(activeSize.height - offSize.height) < 1,
                   "Starting must preserve the panel height; status belongs in the existing header")

        try checkControls(enabled: true)
        try expect(zip(originalEditors, fields()).allSatisfy { $0 === $1 }, "Starting must retain the same duration controls")

        let originalEnd = model.endDate
        let statusView = SessionStatusView(model: model, releaseURL: nil)
        let appliedTitle = statusView.title(using: clock)
        try expect(appliedTitle.contains("10 Nov 2026") && appliedTitle.contains("17:20"),
                   "The active header must show the complete date, even for today")
        let oneHour = card.caption(using: clock)
        model.selectEndTimePreset(300)
        let formatter = DateComponentsFormatter()
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: language)
        formatter.calendar = calendar
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        let difference = formatter.string(from: 4 * 3600)!
        let initial = localizedFormat("Until %@ (%@)", "17:20", formatter.string(from: 3600)!)
        try expect(idleCaption == initial && oneHour == initial, "Idle and running timers must use the same caption")
        try expect(card.caption(using: clock) == localizedFormat("Until %@ (%@)", "21:20", "+" + difference) && model.endDate == originalEnd,
                   "Preview must compare the five-hour choice with the applied one-hour deadline")
        _ = try layout("extension")
        try expect(statusView.title(using: clock) == appliedTitle,
                   "The active header must keep the applied deadline while the card shows the draft")
        let tomorrow = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: model.currentDate)!)
        model.selectEndDate(tomorrow.addingTimeInterval(30 * 60))
        let overnight = localizedFormat("Until %@ (%@)", localizedFormat("%@ tomorrow", "00:30"),
                                       "+" + formatter.string(from: (7 * 60 + 10) * 60)!)
        try expect(card.caption(using: clock) == overnight, "An overnight draft must name tomorrow and its exact stop time")
        model.selectEndDate(model.currentDate.addingTimeInterval(30 * 60))
        try expect(card.caption(using: clock) == localizedFormat("Until %@ (%@)", "16:50", "−" + formatter.string(from: 30 * 60)!),
                   "A shorter session must show the earlier clock time and the negative difference")
        model.discardSettingsDraft()
        try expect(card.caption(using: clock) == oneHour, "Cancel must restore the applied countdown")
        model.selectEndTimePreset(0)
        try expect(card.caption(using: clock) == localized("Until stopped manually"), "Unlimited drafts must use the manual-stop caption")
        model.applySettingsDraft()
        let unlimitedSize = try layout("unlimited")
        try expect(model.endDate == nil && abs(unlimitedSize.height - activeSize.height) < 1,
                   "Infinity must omit the countdown and keep all settings on the same page")
        model.selectEndDate(EndTimeSelection.endOfWindow(from: model.currentDate).addingTimeInterval(-60)); model.applySettingsDraft()
        _ = try layout("maximum")
        model.selectEndTimePreset(60); model.applySettingsDraft()
        _ = try layout("active-restored")
        model.editAllowBattery(false)
        model.applySettingsDraft()
        let acOnlySize = try layout("ac-only")
        try expect(abs(acOnlySize.height - activeSize.height) < 1, "Normal live changes must preserve active menu geometry")
        model.editAllowBattery(true)
        model.applySettingsDraft()
        let restoredSize = try layout("battery-enabled")
        try expect(abs(restoredSize.height - activeSize.height) < 1, "Restoring the battery option must preserve active menu geometry")
        let draftDate = model.currentDate.addingTimeInterval(180)
        model.selectEndDate(draftDate)
        let durationDraftSize = try layout("draft")
        try expect(abs(durationDraftSize.height - activeSize.height) < 1,
                   "Draft actions must replace Stop without adding a row")
        fixture.now += 12
        model.tick()
        _ = try layout("draft-tick")
        try expect(fields().map(\.stringValue) == [clock.editorText(draftDate)], "The time field must retain the exact dirty endpoint across ticks")
        model.discardSettingsDraft()
        let cancelledSize = try layout("cancelled")
        try expect(abs(cancelledSize.height - activeSize.height) < 1,
                   "Cancelling must return to the applied timer without resizing the panel")
        model.selectEndDate(model.currentDate.addingTimeInterval(35 * 60))
        model.applySettingsDraft()
        let appliedSize = try layout("applied")
        model.editClosedLid(true)
        model.editThreshold(26)
        model.selectEndDate(model.currentDate.addingTimeInterval(40 * 60))
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try expect(model.isRestarting && model.phase == .authorizing && model.showsSettingsActions,
                   "A combined lid transition must show the internal restart")
        let restartingSize = try layout("restart")
        let helpFooterHeight = MenuLayout.helpLinkHeight + AppStyle.Layout.panelInset
        let actionNoticeHeight = MenuLayout.feedbackRowHeight + AppStyle.Layout.cardSpacing
        let footerNoticeHeight = actionNoticeHeight + AppStyle.Layout.cardSpacing
        try checkControls(enabled: false)
        try expect(abs(restartingSize.height - appliedSize.height - actionNoticeHeight) < 1,
                   "System confirmation must add one notice directly below the actions")
        guard let files = fixture.files else { throw WakecupError(message: "Missing fake guardian files") }
        let newDeadline = fixture.now + 40 * 60
        try files.write(SessionStatus(phase: .active, deadline: newDeadline), to: "status.json")
        model.tick()
        model.selectDisplayMode(.mayTurnOff)
        model.applySettingsDraft()
        _ = try layout("closed-active")
        try checkControls(enabled: true)
        let beforePending = host.view.fittingSize
        model.editThreshold(25)
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        let pendingSize = try layout("pending")
        try expect(abs(pendingSize.height - beforePending.height - footerNoticeHeight) < 1,
                   "Applying settings must add a single progress notice")
        let control = try files.read("control.json", as: SessionControl.self)
        guard let update = control.update else { throw WakecupError(message: "Missing fake live update") }
        var status = SessionStatus(phase: .active, deadline: update.deadline)
        status.settingsRevision = update.revision
        status.powerMode = update.powerMode
        status.threshold = update.threshold
        try files.write(status, to: "status.json")
        model.tick()
        model.selectDisplayMode(.mayTurnOff)
        model.applySettingsDraft()
        let acknowledgedSize = try layout("acknowledged")
        try expect(abs(pendingSize.height - acknowledgedSize.height - footerNoticeHeight) < 1, "Acknowledgement must remove the progress notice")
        fixture.rejectDisplay = true
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try expect(model.displayControlError != nil && !model.keepDisplayOn && model.displayModeDraft == .keepOn,
                   "Display rejection must retain the draft and leave the applied preference unchanged")
        _ = try layout("display-error")
        model.editThreshold(30)
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try expect(model.settingsApplying && model.displayControlError != nil, "Pending settings must coexist with a display error")
        _ = try layout("display-error-pending")
        let rejectedControl = try files.read("control.json", as: SessionControl.self)
        guard let rejectedUpdate = rejectedControl.update else { throw WakecupError(message: "Missing rejected fake update") }
        status.settingsRevision = rejectedUpdate.revision
        status.settingsError = "Invalid live settings."
        try files.write(status, to: "status.json")
        model.tick()
        try expect(!model.settingsApplying && model.settingsMessage != nil && model.displayControlError != nil,
                   "Both independent error results must remain available to the action area")
        let bothErrorsSize = try layout("both-errors")
        try expect(abs(bothErrorsSize.height - acknowledgedSize.height - actionNoticeHeight) < 1,
                   "Concurrent issues must share one visible message row")
        try checkControls(enabled: true)
        model.discardSettingsDraft()
        _ = try layout("cancelled-after-error")
        try checkControls(enabled: true)
        try expect(!fixture.unexpectedHelperCall, "The offscreen fixture must never use a helper")
        // A short screen still needs scrolling; its scrollbar must not steal
        // width from the fixed-width document and clip the right controls.
        let panelController = MenuPanelController(model: model, updates: UpdateChecker(), statusButton: { nil })
        guard let panel = NSApp.windows.first(where: { $0.title == "Wakecup" }),
              let scroll = panel.contentView.flatMap({ descendants($0).compactMap { $0 as? NSScrollView }.first }) else {
            throw WakecupError(message: "Missing hidden menu panel")
        }
        panel.setContentSize(NSSize(width: MenuLayout.width, height: 400))
        scroll.hasVerticalScroller = true
        panel.contentView?.layoutSubtreeIfNeeded()
        try expect(scroll.scrollerStyle == .overlay && abs(scroll.contentSize.width - MenuLayout.width) < 1,
                   "Small-screen scrolling must leave the full control width available")
        let pinnedHeight = AppStyle.Layout.panelInset + AppStyle.Layout.headerHeight
            + 2 * AppStyle.Layout.cardSpacing + AppStyle.Layout.sessionActionAreaHeight
        let shortViewportHeight = 400 - helpFooterHeight - pinnedHeight
        func expectViewportHeight(withNotice: Bool = false) throws {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
            panel.contentView?.layoutSubtreeIfNeeded()
            let expected = shortViewportHeight - (withNotice ? footerNoticeHeight : 0)
            try expect(abs(scroll.contentSize.height - expected) < 1,
                       "The header and actions must stay pinned above the settings, with space for a notice when needed")
        }
        try expect(!model.showsSettingsActions && model.displayControlError != nil,
                   "Discarding a failed display draft must leave the error available")
        try expectViewportHeight(withNotice: true)
        fixture.rejectDisplay = false
        model.selectDisplayMode(.keepOn)
        model.applySettingsDraft()
        try expectViewportHeight()
        if let document = scroll.documentView {
            document.setFrameSize(document.fittingSize)
            let bottom = max(0, document.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: document.isFlipped ? bottom : 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        let viewportBeforeDraft = scroll.documentVisibleRect
        model.editThreshold(28)
        try expectViewportHeight()
        try expect(model.showsSettingsActions && scroll.documentVisibleRect == viewportBeforeDraft,
                   "Showing Apply and Cancel above the scroller must leave the viewport on the edited setting")
        model.discardSettingsDraft()
        try expectViewportHeight()
        try expect(!panelController.isVisible, "Panel geometry check must stay offscreen")
        fixture.rejectDisplay = false
        try model.setDisplayShortcut(chosen)
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()
        try expect(model.backlightCountdown == 10, "Applying the blackout must start a visible countdown")
        let countdownSize = try layout("countdown")
        try expect(abs(countdownSize.height - acknowledgedSize.height) < 1,
                   "The two-line countdown must replace Stop without expanding the action area")
        fixture.now += 1
        model.tick()
        let nextSecondSize = try layout("countdown-next-second")
        try expect(model.backlightCountdown == 9 && abs(nextSecondSize.height - countdownSize.height) < 1,
                   "A countdown tick must keep the action area at the same height")
        fixture.lidState = nil
        model.editClosedLid(false)
        model.applySettingsDraft()
        try expect(model.settingsMessage != nil && model.displayMode == .keepOn && model.backlightCountdown == nil,
                   "A rejected lid change must expose the error and cancel the pending blackout")
        let applyErrorSize = try layout("apply-error")
        try expect(abs(applyErrorSize.height - countdownSize.height - actionNoticeHeight) < 1,
                   "A rejected Apply must add one notice below the draft actions")
        fixture.lidState = false
        model.discardSettingsDraft()
        try expect(model.backlightCountdown == nil, "Clearing the error must not restart the countdown")
        model.selectDisplayMode(.backlightOff)
        model.applySettingsDraft()

        model.selectDisplayMode(.keepOn)
        try expect(model.displayModeDraft == .keepOn && model.displayMode == .backlightOff && model.backlightCountdown == nil,
                   "Editing the active display mode pauses the countdown")
        _ = try layout("display-draft")
        panelController.close()
        try expect(model.displayModeDraft == nil && model.displayMode == .backlightOff && model.backlightCountdown == 10,
                   "Closing the panel must discard the draft and restart the applied countdown")
        fixture.now += 10
        model.tick()
        try expectViewportHeight(withNotice: true)
        try expect(model.displayControlError != nil && !model.showsSettingsActions,
                   "A failure after the countdown must show an error without draft actions")
        model.selectDisplayMode(.mayTurnOff)
        model.applySettingsDraft()
        for (text, isLong) in [("Short details", false), (String(repeating: "A long system error with details. ", count: 500), true)] {
            let details = NSHostingController(rootView: MenuFeedbackPopover(text: text))
            details.view.layoutSubtreeIfNeeded()
            let size = details.view.fittingSize
            try expect(abs(size.width - MenuLayout.tooltipWidth) < 1 && size.height <= MenuLayout.tooltipMaximumHeight,
                       "Error details must fit the popup width and maximum height")
            if isLong {
                try expect(descendants(details.view).contains { $0 is NSScrollView }, "Long errors must remain scrollable")
            } else {
                try expect(size.height < 100, "Short error details must not reserve an empty large popup")
            }
        }
        model.stop()
        try files.write(SessionStatus(phase: .stopped, reason: "зарядка отключена", sleepRestored: true), to: "status.json")
        model.tick()
        try expectViewportHeight(withNotice: true)
        try expect(model.phase == .idle && model.message != nil && !model.showsSettingsActions,
                   "A stop caused by disconnecting power must show its reason without draft actions")
        model.message = nil
        try expectViewportHeight()
        try expect(activeSize.height > 0, "Active layout must be measurable")
        print("PASS: unified off/active controls, translated labels, dirty duration, Apply, action replacement, countdown, and inline feedback layout (\(language))")
    }

    private final class Fixture {
        var now: TimeInterval = 1000
        var files: SessionFiles?
        var authorization: ((CommandOutput) -> Void)?
        var rejectDisplay = false
        var lidState: Bool? = false
        var unexpectedHelperCall = false
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
}
