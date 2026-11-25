import AppKit

// Uses process-local language defaults and fake update requests without starting a session.
@main struct AboutLayoutTests {
    @MainActor static func main() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        var requests: [UpdateChecker.Completion] = []
        let updates = UpdateChecker(currentVersion: { "1.0.0" }) { _, complete in
            requests.append(complete)
            return AboutUpdateRequest()
        }
        var openedURLs: [URL] = []
        let controller = AboutWindowController(updates: updates, openURL: { openedURLs.append($0) })
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
        guard let identity = name.superview as? NSStackView,
              let icon = controls.compactMap({ $0 as? NSImageView }).first(where: {
                  $0.frame.width == AppStyle.AboutLayout.iconSize
              }) else {
            throw WakecupError(message: "About header is missing its icon or identity")
        }
        let textBounds = identity.arrangedSubviews.reduce(NSRect.null) { bounds, label in
            bounds.union(content.convert(label.bounds, from: label))
        }
        let iconBounds = content.convert(icon.bounds, from: icon)
        try expect(abs(textBounds.midY - iconBounds.midY) < 1,
                   "The name and version must center as a block beside the icon")

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
        guard let checkButton = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == localized("Check for Updates") }) else {
            throw WakecupError(message: "Manual update check is missing")
        }
        let releaseURL = URL(string: "https://github.com/makhnevvitalik/Wakecup/releases/tag/v2.0.0")!
        let responseURL = UpdateChecker.latestReleaseAPIURL
        updates.check()
        try expect(requests.count == 1, "The updater should start the first background check")
        settle()
        try expect(!status.isHidden && status.stringValue == localized("Checking GitHub for updates…"),
                   "The first check uses the result line to describe progress")
        requests[0](Data(#"{"tag_name":"v2.0.0","html_url":"\#(releaseURL)"}"#.utf8),
                    HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        settle()
        try expect(checkButton.title == localized("Check for Updates") && checkButton.isEnabled,
                   "About must still offer a manual check after the background check finds an update")
        let releaseTitle = localizedFormat("%@ is available", "v2.0.0") + " ↗"
        guard let release = descendants(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == releaseTitle }) else {
            throw WakecupError(message: "About must show a separate link to the known release")
        }
        let availableHeight = window.frame.height
        checkButton.performClick(nil)
        settle()
        try expect(window.frame.height == availableHeight && status.isHidden,
                   "Repeating a check with a known release must retain one result line and keep the window height")
        try expect(requests.count == 2 && !checkButton.isEnabled,
                   "The manual check should start a new request and be disabled while checking")
        try expect(!release.isHidden && release.title == releaseTitle, "Keep the release link during a refresh")
        let tagline = controls.compactMap { $0 as? NSTextField }.first {
            $0.stringValue == localized("AI works. Your Mac stays wide awake.")
        }!
        let linkLeading = content.convert(release.alignmentRect(forFrame: release.frame), from: release.superview).minX
        let taglineLeading = content.convert(tagline.alignmentRect(forFrame: tagline.frame), from: tagline.superview).minX
        try expect(abs(linkLeading - taglineLeading) < 0.5,
                   "The release text must align with the About text at \(taglineLeading) pt, got \(linkLeading) pt")
        release.performClick(nil)
        try expect(openedURLs == [releaseURL], "The release link should open the known release during a refresh")
        requests[1](nil, nil, URLError(.notConnectedToInternet))
        settle()
        try expect(checkButton.isEnabled && checkButton.title == localized("Check for Updates")
                   && !release.isHidden && release.title == releaseTitle,
                   "A transient failure must preserve the release link and the Check for Updates action")
        try expect(!status.isHidden && status.stringValue == localized("Could not contact GitHub. Please try again."),
                   "A failed refresh still displays its error with the known release")
        release.performClick(nil)
        try expect(openedURLs == [releaseURL, releaseURL], "The release link should open the same release after a transient failure")
        checkButton.performClick(nil)
        settle()
        try expect(requests.count == 3, "A failed check should be retryable")
        requests[2](Data(#"{"tag_name":"v1.0.0"}"#.utf8),
                    HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        settle()
        try expect(release.isHidden, "An up-to-date result should remove the known release link")

        updates.check()
        let longTag = "9000000000000000000.9000000000000000000.9000000000000000000"
        try expect(requests.count == 4, "The next background check should run")
        requests[3](Data(#"{"tag_name":"\#(longTag)"}"#.utf8),
                    HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        settle()
        content.layoutSubtreeIfNeeded()
        let releaseFrame = content.convert(release.bounds, from: release)
        try expect(!release.isHidden && content.bounds.contains(releaseFrame) && release.toolTip?.contains(longTag) == true,
                   "A long tag should fit its link inside About and remain readable in the tooltip")
        license.performClick(nil)
        settle()
        guard let licenses = app.windows.first(where: { $0.title == localized("Wakecup License") }),
              let licenseContent = licenses.contentView else { throw WakecupError(message: "License did not open") }
        try expect(!descendants(licenseContent).contains { $0 is NSPopUpButton || $0 is NSSegmentedControl },
                   "A single license must not have an empty third-party selector")
        try expect(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt") == nil,
                   "Obsolete third-party notice must not remain bundled")
        print("PASS: About layout, independent update check and release link, single license (\(language))")
    }
    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)) }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
}

private final class AboutUpdateRequest: UpdateRequestTask {
    func resume() {}
    func cancel() {}
}
