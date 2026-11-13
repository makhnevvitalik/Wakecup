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
        let suite = "WakecupHelperDialogLayout-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let manifest = HelperManifest(protocolVersion: HelperConstants.protocolVersion, ownerUID: getuid(),
            clientHash: String(repeating: "a", count: 40), helperHash: HelperBuildIdentity.cdHash,
            helperSHA256: HelperBuildIdentity.sha256)
        for (name, state) in [("ready", PrivilegedHelperController.State.ready), ("update", .updateRequired),
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
                let interaction = HelperPresentation(activate: {}, presentAlert: { _ in .abort }, presentSettings: { alert in
                    var response: NSApplication.ModalResponse?
                    let dialog = HelperSettingsDialog(alert: alert) { response = $0 }
                    captured = dialog
                    (acceptChange ? dialog.buttons.first : dialog.buttons.last)?.performClick(nil)
                    return response ?? .abort
                }).interaction
                interaction.showSettings(for: helper)
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
                    interaction.showSettings(for: helper)
                    try expect(helper.selected != selected && helper.usesHelper != selected,
                               "Mode selection must switch helper usage without authorization or installation")
                }
                acceptChange = false
                interaction.showSettings(for: helper, allowInstallationChanges: false)
                try expect(captured?.buttons.first?.isEnabled == (state == .ready),
                           "Read-only settings must disable installation/update while allowing permission-mode selection")
                try expect(installationRequests == 0, "Layout and mode selection must not install the helper")
            }
        }
        print("PASS: ten offscreen helper dialogs, including long diagnostics, are 560 pt wide with one unclipped button row; Close and mode selection work (\(language))")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw WakecupError(message: message) }
    }
}
