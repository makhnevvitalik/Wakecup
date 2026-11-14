import AppKit
import SwiftUI

// Renders active-session states with fake system operations; never changes sleep.
@main struct SessionStatusLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.finishLaunching()
        let suite = "WakecupStatusLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let clock = Clock()
        let operations = SessionOperations(now: { clock.now }, readPower: { PowerState(onAC: true, percent: 80) },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { try SessionFiles.create(at: directory.appendingPathComponent($0.id), configuration: $0) },
            guardianResponding: { _, _ in false },
            authorization: { _, _ in .init(run: { _ in }, cancel: {}) },
            usesInstalledHelper: { clock.useHelper }, startHelper: { _, _, _ in },
            loginItem: LoginItemController(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        let helper = PrivilegedHelperController(defaults: defaults,
            inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        model.editClosedLid(false)
        let updates = UpdateChecker(currentVersion: { "1.0.0" }) { request, completion in
            UpdateFixtureTask {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)
                completion(Data(#"{"tag_name":"1.1.0"}"#.utf8), response, nil)
            }
        }
        let root = StatusFixture(model: model, updates: updates)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = hosting
        defer { model.stop(); window.orderOut(nil) }
        var baseline: NSSize?
        @discardableResult
        @MainActor func render(_ state: String) throws -> Data {
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); hosting.view.layoutSubtreeIfNeeded() }
            let size = hosting.view.fittingSize
            try expect(abs(size.width - MenuLayout.width) < 1, "Status widened the panel: " + state)
            if let baseline { try expect(abs(size.height - baseline.height) < 1, "Status changed panel height: " + state) }
            else { baseline = size }
            hosting.view.setFrameSize(size); window.setContentSize(size)
            hosting.view.layoutSubtreeIfNeeded(); hosting.view.displayIfNeeded()
            guard let bitmap = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) else {
                throw WakecupError(message: "Could not capture panel: " + state)
            }
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-header-\(language)-\(state).png"))
            }
            // Compare only the header so that changes to the rest of the panel do not affect these assertions.
            let scale = CGFloat(bitmap.pixelsHigh) / size.height
            let headerRect = CGRect(x: 0, y: 0, width: CGFloat(bitmap.pixelsWide),
                                    height: (AppStyle.Layout.panelInset + AppStyle.Layout.headerHeight) * scale)
            guard let header = bitmap.cgImage?.cropping(to: headerRect),
                  let snapshot = NSBitmapImageRep(cgImage: header).representation(using: .png, properties: [:]) else {
                throw WakecupError(message: "Could not capture header: " + state)
            }
            return snapshot
        }
        let idleWithoutUpdate = try render("off")
        model.selectEndTimePreset(60)
        model.start()
        try expect(model.phase == .active, "Fake timer must become active")
        let activeWithoutUpdate = try render("active-before-update")
        try expect(activeWithoutUpdate != idleWithoutUpdate, "Active status must be visible in the header")

        updates.check()
        let activeWithUpdate = try render("active-with-update")
        guard case .finished(.updateAvailable) = updates.state else {
            throw WakecupError(message: "The update link fixture must report a newer release")
        }
        try expect(activeWithUpdate == activeWithoutUpdate, "Active status must take priority over the update link")
        model.stop()
        let idleWithUpdate = try render("update")
        try expect(idleWithUpdate != idleWithoutUpdate, "Update link must be visible when idle")
        for (minutes, name) in [(1, "minute"), (72, "hour"), (-1, "maximum"), (0, "unlimited")] {
            model.stop(); clock.now = 1_000
            if minutes == 0 { model.selectEndTimePreset(0) }
            else if minutes < 0 {
                model.selectEndDate(EndTimeSelection.endOfWindow(from: model.currentDate).addingTimeInterval(-60))
            }
            else { model.selectEndDate(model.currentDate.addingTimeInterval(Double(minutes * 60))) }
            model.start(); clock.now += 7; model.tick()
            try expect(model.phase == .active, "Fake timer must become active")
            try render(name)
            for threshold in [10, 20, 50] { model.editThreshold(Double(threshold)); model.applySettingsDraft(); try render(name + "-battery-" + String(threshold)) }
            model.editAllowBattery(false); model.applySettingsDraft(); try render(name + "-ac")
            model.editAllowBattery(true)
            model.applySettingsDraft()
        }
        model.stop(); try render("stopped")
        model.phase = .stopping; try render("stopping")
        model.phase = .authorizing; try render("password")
        model.phase = .failed; model.message = "Could not read guardian state."; try render("failed")
        model.phase = .idle; model.message = SessionMessage("Session ended: %@.", arguments: ["зарядка отключена"])
        try render("automatic-stop")
        model.message = nil; model.editClosedLid(true); clock.useHelper = true
        model.start()
        try expect(model.phase == .authorizing && !model.waitingForPassword, "Fake helper startup must be pending")
        try render("helper-start")
        print("PASS: header update visibility, status priority and panel geometry for off, active, final selectable day, infinity, transitions, errors and automatic stop (\(language))")
    }
    private final class Clock { var now: TimeInterval = 1_000; var useHelper = false }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WakecupError(message: message) }
    }
}

// Observe the same root used by the application, including its real header.
private struct StatusFixture: View {
    @ObservedObject var model: SessionModel
    let updates: UpdateChecker
    var body: some View {
        WakecupView(model: model, updates: updates, showAbout: {}, configureDisplayShortcut: { _ in false })
            .background(Color(nsColor: NSColor(calibratedWhite: 0.91, alpha: 1)))
    }
}

private final class UpdateFixtureTask: UpdateRequestTask {
    let complete: () -> Void
    init(complete: @escaping () -> Void) { self.complete = complete }
    func resume() { complete() }
    func cancel() {}
}
