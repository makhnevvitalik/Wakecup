import AppKit
import SwiftUI

// Offscreen only, with fake power/assertion/authorization operations.
@main struct ActiveDisplayControlLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        guard let resources = Bundle.main.resourceURL else { throw WakecupError(message: "Missing test bundle resources") }
        let translationsURL = resources.appendingPathComponent(language + ".lproj/Localizable.strings")
        let translationsData = try Data(contentsOf: translationsURL)
        let translations = try PropertyListSerialization.propertyList(from: translationsData, format: nil) as! [String: String]
        for key in ["Display backlight", "May turn off", "Keep on", "Backlight off", "Backlight shortcut", "Backlight turns off in %@", "%ld s", "Cancel backlight countdown", "Cancel turning off the backlight", "display.shortcut.summary", "Stop when hot", "thermal.stop.help", "Critical", "Serious"] {
            try expect(translations[key] != nil && localized(key) == translations[key], "Test must render the packaged language: \(key)")
        }
        let suite = "WakecupLiveDisplayLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var now: TimeInterval = 1000
        var operations = SessionOperations(now: { now }, readPower: { .init(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { try SessionFiles.create(at: root.appendingPathComponent($0.id), configuration: $0) },
            guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
            usesInstalledHelper: { false }, startHelper: { _, _, _ in },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        operations.enterBacklight = { _, complete in complete(.success(()), true) }
        var pressShortcut: (() -> Void)?
        operations.registerDisplayShortcut = { _, handler in pressShortcut = handler }
        operations.unregisterDisplayShortcut = { pressShortcut = nil }
        var deferRestoration = false
        var completeRestoration: ((Result<Bool, Error>) -> Void)?
        operations.restoreBacklight = { _, complete in
            if deferRestoration { completeRestoration = complete }
            else { complete(.success(true)) }
        }
        let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) },
            requestInformation: { _ in })
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        model.editClosedLid(false)
        try model.setDisplayShortcut(DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control))
        let content = WakecupLayoutFixture(model: model, updates: UpdateChecker(), showAbout: {})
            .background(Color(nsColor: .windowBackgroundColor)).tint(Color(AppStyle.Color.accent))
        let host = NSHostingController(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { model.stop(); window.orderOut(nil) }
        let shortcut = model.displayShortcut
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let assignedSize = host.view.fittingSize
        try model.setDisplayShortcut(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(host.view.fittingSize == assignedSize, "Assigning a shortcut must keep the same panel size")
        try model.setDisplayShortcut(shortcut)
        for preset in [180, 0] {
            model.stop(); model.selectEndTimePreset(preset); model.start()
            try expect(model.phase == .active, "Offscreen fixture did not start its fake timer")
            let deadline = model.deadline
            var baseline: NSSize?
            for mode: DisplayMode in [.mayTurnOff, .keepOn, .backlightOff, .keepOn, .mayTurnOff] {
                model.selectDisplayMode(mode)
                model.applySettingsDraft()
                if mode == .backlightOff {
                    try expect(model.backlightCountdown == 10, "Applying Backlight off must show a countdown")
                }
                for _ in 0..<3 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    host.view.layoutSubtreeIfNeeded()
                }
                let size = host.view.fittingSize
                try expect(abs(size.width - MenuLayout.width) < 1, "Display control widened the menu")
                if let baseline { try expect(abs(size.height - baseline.height) < 1, "Display change moved or resized the active menu") }
                baseline = size
                host.view.setFrameSize(size); window.setContentSize(size)
                host.view.layoutSubtreeIfNeeded()
                let switches = descendants(host.view).compactMap { $0 as? NSSwitch }
                try expect(switches.count == 2, "Unified settings must retain lid and battery switches")
                let display = descendants(host.view).compactMap { $0 as? NSPopUpButton }
                    .first { $0.identifier?.rawValue == "WakecupDisplayMode" }
                let modes: [DisplayMode] = [.mayTurnOff, .keepOn, .backlightOff]
                try expect(display?.numberOfItems == 3 && display?.indexOfSelectedItem == modes.firstIndex(of: mode),
                           "Three-choice native picker must follow the applied mode")
                try expect(display?.itemArray.filter { $0.state == .on } == [display?.selectedItem].compactMap { $0 },
                           "Only the current display mode should have a checkmark")
                try expect(display?.isEnabled == true && display?.font?.isEqual(AppStyle.Font.controlLabel) == true,
                           "Active display picker remains enabled with the shared control font")
                let controls = descendants(host.view).compactMap { $0 as? NSControl }
                guard let display,
                      let shortcutButton = controls.first(where: { $0.identifier?.rawValue == "WakecupConfigureDisplayShortcut" }) else {
                    throw WakecupError(message: "Expected native display mode and shortcut controls")
                }
                let buttonFrame = host.view.convert(shortcutButton.bounds, from: shortcutButton)
                let popupFrame = host.view.convert(display.bounds, from: display)
                try expect(abs(buttonFrame.maxX - popupFrame.maxX) < 1 && popupFrame.width + 0.5 >= display.fittingSize.width,
                           "The display menu must fit its largest label and align with the shortcut button")
                try expect(switches.allSatisfy { abs(host.view.convert($0.bounds, from: $0).height - buttonFrame.height) < 1 },
                           "The switches and text buttons must use the same visible height")
                try expect(model.phase == .active && model.deadline == deadline, "Display choice changed the running timer")
                host.view.displayIfNeeded()
                if preset == 180, let image = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                    host.view.cacheDisplay(in: host.view.bounds, to: image)
                    if let data = image.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-active-display-\(language)-\(mode).png"))
                    }
                }
            }
        }
        let pickers = descendants(host.view).compactMap { $0 as? NSPopUpButton }
        guard let thermalPicker = pickers.first(where: { $0.identifier?.rawValue == "WakecupThermalStopLevel" }),
              let displayPicker = pickers.first(where: { $0.identifier?.rawValue == "WakecupDisplayMode" }) else {
            throw WakecupError(message: "Missing thermal or display selector on the main panel")
        }
        let thermalY = thermalPicker.convert(thermalPicker.bounds, to: nil).midY
        let displayY = displayPicker.convert(displayPicker.bounds, to: nil).midY
        try expect(thermalY > displayY, "The thermal stop setting must be above display controls")
        try expect(thermalPicker.itemTitles == ["Critical", "Serious"].map(localized)
                   && thermalPicker.indexOfSelectedItem == 0, "The main panel must show both localized thresholds and select Critical by default")
        let deadlineBeforeSelection = model.deadline
        thermalPicker.selectItem(at: 1)
        thermalPicker.sendAction(thermalPicker.action, to: thermalPicker.target)
        try expect(model.thermalStopLevel == .serious && defaults.string(forKey: "thermalStopLevel") == "serious",
                   "Changing the threshold on the main panel must persist it immediately")
        try expect(model.deadline == deadlineBeforeSelection && !model.hasSettingsDraft,
                   "Changing the threshold must preserve the running timer")

        try model.setDisplayShortcut(nil)
        guard let display = descendants(host.view).compactMap({ $0 as? NSPopUpButton })
            .first(where: { $0.identifier?.rawValue == "WakecupDisplayMode" }) else {
            throw WakecupError(message: "Missing display picker")
        }
        // Recreate a stale AppKit item mark, then reject a selection that needs a shortcut.
        display.selectItem(at: 2)
        display.item(at: 1)?.state = .on
        display.sendAction(display.action, to: display.target)
        try expect(display.indexOfSelectedItem == 0 && model.displayMode == .mayTurnOff,
                   "Cancelling shortcut setup must retain the applied mode")
        try expect(display.itemArray.map(\.state) == [.on, .off, .off],
                   "A rejected choice must leave exactly one checkmark")
        model.stop()
        let updates = UpdateChecker()
        let about = AboutWindowController(updates: updates)
        let helperPresentation = HelperPresentation(activate: {}, settingsOwner: { nil })
        weak var panelSource: MenuPanelController?
        var helperInteraction = helperPresentation.interaction
        helperInteraction.leaveForExplanation = { panelSource?.leaveForAuxiliaryWindow() }
        let panelController = MenuPanelController(model: model, updates: updates, statusButton: { nil },
            showAbout: { about.show(returningTo: panelSource?.leaveForAuxiliaryWindow()) },
            helperInteraction: helperInteraction)
        panelSource = panelController
        panelController.show()
        let panelWindow = NSApp.windows.first(where: { $0.title == "Wakecup" && $0.isVisible })
        guard let panelWindow, let content = panelWindow.contentView,
              let shortcutControl = descendants(content).compactMap({ $0 as? NSButton }).first(where: {
                  $0.identifier?.rawValue == "WakecupConfigureDisplayShortcut"
              }), panelWindow.makeFirstResponder(shortcutControl) else {
            throw WakecupError(message: "The shortcut command must accept keyboard focus")
        }
        var standaloneResult: Bool?
        panelController.configureDisplayShortcut(requiresShortcut: false) { standaloneResult = $0 }
        let openWindows = NSApp.windows.filter(\.isVisible)
        guard let standalone = openWindows.first(where: { $0.title == localized("Backlight shortcut") }) else {
            throw WakecupError(message: "Expected a standalone shortcut editor from the menu bar")
        }
        try expect(!panelController.isVisible && standalone.sheetParent == nil && standalone.level == .normal
                   && !standalone.hidesOnDeactivate
                   && NSApp.modalWindow == nil && !openWindows.contains(where: { $0.title == localized("Wakecup Settings") }),
                   "The menu bar must present the shortcut editor by itself")
        panelController.show()
        try expect(!panelController.isVisible && standalone.isVisible, "The menu bar must raise the existing editor")
        panelController.reopen()
        try expect(standalone.isVisible && !NSApp.windows.contains(where: { $0.isVisible && $0.title == localized("Wakecup Settings") }),
                   "Reopening the application must raise the existing editor")
        standalone.performClose(nil)
        try expect(standaloneResult == false && !standalone.isVisible && panelController.isVisible
                   && panelWindow.firstResponder === shortcutControl,
                   "Cancel must release recording and restore the menu bar panel and its keyboard focus")
        guard let displayControl = descendants(content).compactMap({ $0 as? NSPopUpButton }).first(where: {
            $0.identifier?.rawValue == "WakecupDisplayMode"
        }), panelWindow.makeFirstResponder(displayControl) else {
            throw WakecupError(message: "The display mode picker must accept keyboard focus")
        }
        panelController.configureDisplayShortcut(requiresShortcut: true) { _ in }
        guard let setup = NSApp.windows.first(where: { $0.isVisible && $0.title == localized("Backlight shortcut") }) else {
            throw WakecupError(message: "Expected the first-use shortcut editor")
        }
        setup.performClose(nil)
        try expect(panelWindow.firstResponder === displayControl, "First-use setup must return focus to the mode picker")

        guard let gear = descendants(content).compactMap({ $0 as? AppStyle.SettingsMenuButton }).first,
              let menu = gear.menu,
              let helperMenu = menu.items.compactMap(\.submenu).first(where: { $0.item(withTitle: localized("Why install a helper?")) != nil }) else {
            throw WakecupError(message: "Expected the gear menu and helper submenu")
        }
        helperMenu.performActionForItem(at: helperMenu.indexOfItem(withTitle: localized("Why install a helper?")))
        guard let explanation = NSApp.windows.first(where: { $0.isVisible && $0.title == localized("Why install a helper?") }),
              let explanationBody = explanation.contentView,
              let closeExplanation = descendants(explanationBody).compactMap({ $0 as? NSButton }).first else {
            throw WakecupError(message: "Expected the independent helper explanation")
        }
        try expect(!panelController.isVisible, "The helper explanation must hide the menu bar panel")
        closeExplanation.performClick(nil)
        try expect(!explanation.isVisible && panelController.isVisible, "Closing the explanation must restore the menu bar panel")

        menu.performActionForItem(at: menu.indexOfItem(withTitle: localized("About Wakecup…")))
        guard let aboutWindow = NSApp.windows.first(where: { $0.isVisible && $0.title == localized("About Wakecup") }) else {
            throw WakecupError(message: "Expected the About window from the gear menu")
        }
        try expect(!panelController.isVisible, "About must hide the menu bar panel")
        aboutWindow.performClose(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(!aboutWindow.isVisible && panelController.isVisible, "Closing About must restore the menu bar panel")

        for (sourceMenu, item, title) in [
            (menu, "About Wakecup…", "About Wakecup"),
            (helperMenu, "Why install a helper?", "Why install a helper?")
        ] {
            panelController.showWindow()
            guard let firstSource = panelController.settingsSheetOwner() else {
                throw WakecupError(message: "Expected standalone settings before reopening an information window")
            }
            sourceMenu.performActionForItem(at: sourceMenu.indexOfItem(withTitle: localized(item)))
            guard let information = NSApp.windows.first(where: { $0.isVisible && $0.title == localized(title) }) else {
                throw WakecupError(message: "Expected the information window from standalone settings")
            }
            panelController.show()
            try expect(!firstSource.isVisible && panelController.isVisible, "Switching to the panel must hide standalone settings")
            sourceMenu.performActionForItem(at: sourceMenu.indexOfItem(withTitle: localized(item)))
            try expect(!panelController.isVisible && information.isVisible, "Reopening must raise the same information window")
            information.performClose(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            try expect(!information.isVisible && !firstSource.isVisible && panelController.isVisible,
                       "Closing a reused window must return to the most recent source")
        }

        panelController.showWindow()
        guard let owner = panelController.settingsSheetOwner() else {
            throw WakecupError(message: "Expected the existing settings window")
        }
        var editorAccepted: Bool?
        panelController.configureDisplayShortcut(requiresShortcut: false) { editorAccepted = $0 }
        guard let sheet = owner.attachedSheet else { throw WakecupError(message: "The shortcut editor must attach to settings") }
        try expect(NSApp.modalWindow == nil && sheet.sheetParent === owner, "The shortcut editor may only block settings")
        panelController.show()
        try expect(!panelController.isVisible && panelController.settingsSheetOwner() == nil && owner.attachedSheet === sheet,
                   "Reopening while a sheet is attached must retain its settings window and reject nesting")
        owner.endSheet(sheet, returnCode: .cancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(editorAccepted == false && panelController.settingsSheetOwner() === owner,
                   "Cancel must end editing and release the settings owner without replacing it")
        owner.close()

        let action = SessionActionsView(model: model)
        try model.setDisplayShortcut(DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control))
        model.selectEndTimePreset(60)
        model.start()
        pressShortcut?()
        try expect(model.isBacklightOff, "The registered shortcut must darken the display in the running session")
        deferRestoration = true
        model.stop()
        try expect(model.isReturningControl && action.actionTitle == localized("Restoring brightness…"),
                   "A pending stop must tell the user when brightness is being restored")
        try expect(SessionFeedback.current(for: model, placement: .footer)?.style == .progress,
                   "Brightness restoration progress must remain in the footer")
        completeRestoration?(.failure(WakecupError(message: "Fake backlight failure")))
        try expect(action.actionTitle == localized("Restore brightness"), "A failed restoration must offer a retry")
        try expect(SessionFeedback.current(for: model, placement: .primaryAction)?.style == .error,
                   "A failed brightness recovery must show context near the retry button")
        model.restoreBrightness()
        try expect(action.actionTitle == localized("Restoring brightness…"), "A retry must retain the brightness action while pending")
        completeRestoration?(.success(true))
        try expect(action.actionTitle == localized("Start"), "A successful restoration must re-enable Start")
        deferRestoration = false
        model.selectDisplayMode(.backlightOff)
        model.start()
        now += 7
        model.tick()
        try expect(model.backlightCountdown == 3, "The test session must have three seconds left before blackout")
        let editor = DisplayShortcutEditor.present(model: model, owner: nil, requiresShortcut: false) { _ in }
        defer { editor.cancelPressed() }
        let becameKey = Notification(name: NSWindow.didBecomeKeyNotification, object: editor.window)
        let resignedKey = Notification(name: NSWindow.didResignKeyNotification, object: editor.window)
        editor.windowDidBecomeKey(becameKey)
        pressShortcut?()
        now += 12
        model.tick()
        try expect(model.backlightCountdown == nil && !model.isBacklightOff,
                   "The key editor must pause blackout and suppress the shortcut to darken")
        editor.windowDidResignKey(resignedKey)
        try expect(model.backlightCountdown == 10, "Leaving the editor must restart the full countdown")
        now += 3
        model.tick()
        try expect(model.backlightCountdown == 7, "The countdown must run while the editor remains open in the background")
        editor.windowDidBecomeKey(becameKey)
        try expect(model.backlightCountdown == nil, "Returning to the editor must pause the countdown again")
        editor.windowDidResignKey(resignedKey)
        pressShortcut?()
        try expect(model.isBacklightOff, "The configured shortcut must darken the screen while the editor is in the background")
        pressShortcut?()
        try expect(!model.isBacklightOff, "The configured shortcut must still restore brightness")
        print("PASS: editor opening, focus return, background countdown, global shortcut and display layout (\(language))")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw WakecupError(message: message) }
    }
}
