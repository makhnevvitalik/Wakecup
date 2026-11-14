import AppKit

// Uses process-local language defaults and never requests updates or starts a session.
@main struct AboutLayoutTests {
    @MainActor static func main() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let controller = AboutWindowController()
        controller.show()
        settle()
        guard let window = app.windows.first(where: { $0.title == localized("About Wakecup") }),
              let content = window.contentView else { throw WakecupError(message: "About did not open") }
        defer { app.windows.forEach { $0.orderOut(nil) } }
        let frame = window.frame
        try expect(content.bounds.width == AppStyle.AboutLayout.width && (170...230).contains(content.bounds.height),
                   "About must fit its content at the shared width")
        let controls = descendants(content)
        guard let status = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.identifier?.rawValue == "WakecupUpdateStatus" }),
              let license = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == localized("License…") }) else {
            throw WakecupError(message: "About actions/status are missing")
        }
        try expect(controls.compactMap { $0 as? NSTextField }.allSatisfy { !$0.isSelectable && !$0.acceptsFirstResponder },
                   "Static About labels must not accept focus when the update button is disabled")
        try expect(status.frame.height >= AppStyle.AboutLayout.statusHeight, "Update status must reserve a compact line")
        let name = controls.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Wakecup" }!
        try expect(name.font?.isEqual(AppStyle.Font.windowTitle) == true, "About name must use the window title role")
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let label = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == version }) {
            try expect(label.font?.isEqual(AppStyle.Font.metadata) == true, "About version must use the header metadata role")
            try expect(label.superview === name.superview && (label.superview as? NSStackView)?.orientation == .vertical
                       && content.convert(label.bounds, from: label).maxY <= content.convert(name.bounds, from: name).minY,
                       "The version must sit below the name")
        }
        let links = controls.compactMap { $0 as? NSButton }.filter { $0.title == "GitHub ↗" || $0.title == localized("License…") }
        try expect(links.count == 2 && links.allSatisfy { $0.font?.isEqual(AppStyle.Font.secondaryAction) == true }, "All About links must share one role")
        for text in ["", localized("Checking GitHub for updates…"), localized("You’re up to date."),
                     localized("The repository or a public release has not been published yet."),
                     localized("Could not contact GitHub. Please try again."),
                     localized("GitHub returned an invalid response."),
                     localized("GitHub returned invalid update information."),
                     localized("Could not determine the installed app version."),
                     localized("GitHub’s request limit was reached. Please try again later."),
                     localizedFormat("GitHub returned HTTP %d.", 403)] {
            status.stringValue = text
            content.layoutSubtreeIfNeeded()
            guard let stack = status.superview as? NSStackView else { throw WakecupError(message: "Missing About layout") }
            AppStyle.sizeAboutWindow(window, to: stack)
            content.layoutSubtreeIfNeeded()
            let textWidth = (text as NSString).size(withAttributes: [.font: status.font!]).width
            if textWidth <= status.frame.width {
                try expect(window.frame == frame, "One-line update status must keep About stable")
            } else {
                try expect(window.frame.height > frame.height, "Long update status must grow About")
            }
            for control in controls where control is NSButton || control is NSTextField || control is NSImageView {
                let rect = content.convert(control.bounds, from: control)
                try expect(rect.minX >= -2 && rect.maxX <= content.bounds.maxX + 2
                           && rect.minY >= 0 && rect.maxY <= content.bounds.maxY,
                           "About control is clipped: \(control), \(rect)")
            }
        }
        status.stringValue = ""
        content.layoutSubtreeIfNeeded()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        content.displayIfNeeded()
        if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
            content.cacheDisplay(in: content.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-about-\(language).png"))
            }
        }
        license.performClick(nil)
        settle()
        guard let licenses = app.windows.first(where: { $0.title == localized("Wakecup License") }),
              let licenseContent = licenses.contentView else { throw WakecupError(message: "License did not open") }
        try expect(!descendants(licenseContent).contains { $0 is NSPopUpButton || $0 is NSSegmentedControl },
                   "A single license must not have an empty third-party selector")
        try expect(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") == nil,
                   "Obsolete third-party notice must not remain bundled")
        print("PASS: compact About, unclipped controls and stable update status; single license (\(language))")
    }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
}
