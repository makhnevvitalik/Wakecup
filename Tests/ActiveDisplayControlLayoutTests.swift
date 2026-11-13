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
        for key in ["Display backlight", "May turn off", "Keep on", "Backlight off", "Restore brightness", "Backlight turns off in %ld s", "Only in Backlight off mode"] {
            try expect(translations[key] != nil && localized(key) == translations[key], "Test must render the packaged language: \(key)")
        }
        let suite = "WakecupLiveDisplayLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        var operations = SessionOperations(now: { 1000 }, readPower: { .init(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { try SessionFiles.create(at: root.appendingPathComponent($0.id), configuration: $0) },
            guardianResponding: { _, _ in false }, authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
            usesInstalledHelper: { false }, startHelper: { _, _, _ in },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        operations.enterBacklight = { _, _, complete in complete(.success(()), true) }
        operations.restoreBacklight = { $0(.success(())) }
        operations.validateDisplayShortcut = { _ in }
        let helper = PrivilegedHelperController(defaults: defaults, inspectInstallation: { .init(state: .missing) },
            requestInformation: { _ in }, interaction: .inert)
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        model.editClosedLid(false)
        try model.setDisplayShortcut(DisplayShortcut(keyCode: 120, modifiers: DisplayShortcut.control))
        let content = WakecupView(model: model, showAbout: {}, configureDisplayShortcut: { _ in false })
            .background(Color(nsColor: .windowBackgroundColor)).tint(Color(AppStyle.Color.accent))
        let host = NSHostingController(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { model.stop(); window.orderOut(nil) }
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
        print("PASS: native live display modes match state with a configured exit shortcut, RU/EN layout fits, finite/infinite timers and menu dimensions stay unchanged (\(language))")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func expect(_ value: Bool, _ message: String) throws {
        guard value else { throw WakecupError(message: message) }
    }
}
