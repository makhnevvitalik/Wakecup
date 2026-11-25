import AppKit

// Trust, installer and modal interaction are faked. Panels are laid out offscreen.
@main struct HelperDialogLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor private static func run() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let owner = NSWindow(contentRect: NSRect(x: 100, y: 150, width: 380, height: 460),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        let suite = "WakecupHelperDialogLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        for (name, state) in [("ready", HelperStatus.State.ready), ("update", .updateRequired),
                              ("unavailable", .unavailable), ("missing", .missing), ("long-error", .unavailable)] {
            for selected in [false, true] {
                defaults.set(selected, forKey: "useInstalledHelper")
                var captured: HelperSettingsDialog?
                var acceptChange = false
                var installationRequests = 0
                let helper = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in
                    installationRequests += 1
                    throw WakecupError(message: "Unexpected installation in layout test")
                }, inspectInstallation: { .init(state: state, detail: name == "long-error" ? String(repeating: "Long diagnostic message. ", count: 300) : "", manifest: state == .ready ? manifest : nil) },
                   requestInformation: { $0(.success(HelperInformation(manifest: manifest, clientConfirmed: true))) })
                let model = helperTestModel(defaults: defaults, helper: helper)
                let interaction = HelperPresentation(activate: {}, settingsOwner: { owner }, presentSettings: { alert, _, completion in
                    let dialog = HelperSettingsDialog(alert: alert, completion: completion)
                    captured = dialog
                    (acceptChange ? dialog.buttons.first : dialog.buttons.last)?.performClick(nil)
                }).interaction
                interaction.showSettings(for: model)
                guard let dialog = captured, let content = dialog.window.contentView else {
                    throw WakecupError(message: "Helper settings presenter was not used")
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                content.layoutSubtreeIfNeeded()
                try expect(content.frame.width == 560, "Helper dialog width must remain 560 points")
                try expect(dialog.window.frame.height <= (NSScreen.main?.visibleFrame.height ?? 800),
                           "Long diagnostics must not push the dialog beyond the visible screen")
                let mode = dialog.modeLabel
                try expect(!mode.isSelectable && !mode.acceptsFirstResponder, "Static summary must not take focus")
                let needed = mode.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: mode.frame.width, height: 1000)).height
                try expect(mode.frame.height + 1 >= needed, "Permission-mode explanation is clipped")
                let frames = dialog.buttons.map { content.convert($0.bounds, from: $0) }
                try expect(frames.allSatisfy { abs($0.midY - frames[0].midY) < 0.5 }, "Buttons must share one horizontal row")
                for (button, frame) in zip(dialog.buttons, frames) {
                    let textWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
                    try expect(frame.width >= textWidth && frame.minX >= 0 && frame.maxX <= content.bounds.maxX && frame.minY >= 0 && frame.maxY <= content.bounds.maxY,
                               "Helper action is clipped: " + button.title)
                }
                try expect(frames.first!.minX > frames.last!.minX, "Primary action belongs to the right of Close")
                try expect(dialog.buttons.first?.keyEquivalent == "\r" && dialog.buttons.last?.keyEquivalent == "\u{1b}",
                           "Enter must activate the primary action and Escape must close the dialog")
                try expect(helper.selected == selected, "Close must preserve the selected mode")
                content.wantsLayer = true
                content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                content.displayIfNeeded()
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: bitmap)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-helper-dialog-\(name)-\(selected)-\(language).png"))
                    }
                }
                dialog.window.orderOut(nil)
                if state == .ready {
                    try expect(dialog.buttons.first?.title == localized(selected ? "Switch to password prompts" : "Use helper"),
                               "Permission-mode action must explain its destination")
                    acceptChange = true
                    interaction.showSettings(for: model)
                    try expect(helper.selected != selected && helper.usesHelper != selected,
                               "Mode selection must switch helper usage without authorization or installation")
                }
                acceptChange = false
                model.start()
                try expect(model.phase == .active, "An active session must disable helper installation")
                interaction.showSettings(for: model)
                model.stop()
                try expect(captured?.buttons.first?.isEnabled == (state == .ready),
                           "Read-only settings must disable installation/update while allowing permission-mode selection")
                try expect(installationRequests == 0, "Layout and mode selection must not install the helper")
            }
        }
        try checkPresentation(owner: owner, defaults: defaults)
        print("PASS: attached helper management and removal, independent modeless alerts, and ten offscreen helper dialogs, including long diagnostics, are 560 pt wide with one unclipped button row; Close and mode selection work (\(language))")
    }
    @MainActor private static func checkPresentation(owner: NSWindow, defaults: UserDefaults) throws {
        let other = NSWindow(contentRect: NSRect(x: 500, y: 150, width: 220, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { owner.orderOut(nil); other.orderOut(nil) }
        owner.orderFront(nil)
        other.orderFront(nil)

        let presenter = HelperPresentation(activate: {}, settingsOwner: { owner.attachedSheet == nil ? owner : nil })
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        var available = false
        var installationRequests = 0
        let helper = PrivilegedHelperController(defaults: defaults, makeInstallationTask: { _ in
            installationRequests += 1
            throw WakecupError(message: "Fixture installation failure")
        }, inspectInstallation: { available ? .init(state: .ready, manifest: manifest) : .init(state: .updateRequired) },
           requestInformation: { $0(.success(HelperInformation(manifest: manifest, clientConfirmed: true))) })
        let model = helperTestModel(defaults: defaults, helper: helper)
        presenter.observeRecovery(of: model)
        let interaction = presenter.interaction
        let windowsBeforeExplanation = NSApp.windows.filter(\.isVisible)
        interaction.showExplanation()
        guard let explanation = NSApp.windows.first(where: { window in
            window.isVisible && !windowsBeforeExplanation.contains(where: { $0 === window })
        }) else { throw WakecupError(message: "Explanation must open an independent window") }
        defer { explanation.close() }
        try expect(explanation.level == .normal && explanation.sheetParent == nil && NSApp.modalWindow == nil,
                   "Explanation must allow continued settings work")
        guard let explanationContent = explanation.contentView,
              let close = findButton(in: explanationContent, titled: localized("Close")) else {
            throw WakecupError(message: "Explanation must have a Close button")
        }
        try expect(close.controlSize == .small && close.bezelStyle == .rounded && close.keyEquivalent == "\u{1b}",
                   "Explanation must use a compact, neutral Close button with Escape")

        interaction.showSettings(for: model)
        guard let settings = owner.attachedSheet, let body = settings.contentView,
              let remove = findButton(in: body, titled: localized("Remove")) else {
            throw WakecupError(message: "Manage helper must present an attached sheet with a Remove action")
        }
        let windowsBeforeFailure = NSApp.windows.filter(\.isVisible)
        interaction.changeInstallation(for: model, remove: false)
        guard let failure = NSApp.windows.first(where: { window in
            window.isVisible && !windowsBeforeFailure.contains(where: { $0 === window })
        }) else { throw WakecupError(message: "Operation failure must open an independent window") }
        defer {
            failure.close()
            if let sheet = owner.attachedSheet { owner.endSheet(sheet, returnCode: .cancel) }
        }
        try expect(failure.level == .normal && failure.sheetParent == nil && NSApp.modalWindow == nil
                   && owner.attachedSheet === settings && other.isVisible,
                   "An automatic failure must leave the sheet attached and other windows available")
        other.makeKeyAndOrderFront(nil)
        let windowsBeforeRepeat = NSApp.windows.filter(\.isVisible).count
        interaction.showExplanation()
        try expect(explanation.isVisible && NSApp.windows.filter(\.isVisible).count == windowsBeforeRepeat
                   && owner.attachedSheet === settings, "Repeating the explanation must raise the same window")
        remove.performClick(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let confirmation = owner.attachedSheet, confirmation !== settings else {
            throw WakecupError(message: "Remove from settings must replace the first sheet with an attached confirmation")
        }
        try expect(NSApp.modalWindow == nil && confirmation.sheetParent === owner,
                   "Removal confirmation must be scoped to the settings window")
        owner.endSheet(confirmation, returnCode: .cancel)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(owner.attachedSheet == nil && failure.isVisible && explanation.isVisible
                   && !helper.working && installationRequests == 1,
                   "Cancelling removal must release settings and preserve independent alerts")
        available = true
        helper.refresh()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try expect(helper.state == .ready && !failure.isVisible && explanation.isVisible,
                   "Actual helper recovery must close the stale failure and preserve the explanation")
    }

    private static func findButton(in view: NSView, titled title: String) -> NSButton? {
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0, titled: title) }.first
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WakecupError(message: message) }
    }
}
