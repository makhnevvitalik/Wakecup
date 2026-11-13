import AppKit
import SwiftUI

// Enforces the shared typographic contract and checks the native controls after
// SwiftUI has hosted them. No sleep session or global preferences are changed.
@main struct StyleContractTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let referenceScale: [(NSFont, CGFloat)] = [
            (AppStyle.Font.body, 13), (AppStyle.Font.emphasizedBody, 13),
            (AppStyle.Font.controlLabel, 13), (AppStyle.Font.statusText, 13),
            (AppStyle.Font.supportingText, 12), (AppStyle.Font.secondaryAction, 12), (AppStyle.Font.metadata, 12),
            (AppStyle.Font.sectionTitle, 13), (AppStyle.Font.appName, 16),
            (AppStyle.Font.windowTitle, 20)
        ]
        for (font, size) in referenceScale {
            try expect(font.pointSize == size, "Text role differs from the Lang Switcher scale")
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let forbidden = try NSRegularExpression(pattern:
            #"NSFont\s*\(|(?:NSFont|Font)\.(?:systemFont|system|monospacedSystemFont|monospacedDigitSystemFont|custom)\s*\(|\.font\s*=\s*\.(?:systemFont|monospacedSystemFont|monospacedDigitSystemFont)\s*\(|\.font\s*\(\s*\.(?:system|title|body|caption|headline|subheadline|footnote)|pointSize:\s*[0-9]"#)
        for directory in ["Presentation", "App"] {
            let urls = FileManager.default.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)!
            for case let file as URL in urls where file.pathExtension == "swift" && file.lastPathComponent != "AppStyle.swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                let range = NSRange(source.startIndex..., in: source)
                try expect(forbidden.firstMatch(in: source, range: range) == nil,
                           "Choose an AppStyle text/icon role instead of a local font: " + file.lastPathComponent)
            }
        }
        let suite = "WakecupStyleTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionModel(defaults: defaults)
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: MenuLayout.width, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: WakecupView(model: model, showAbout: {}, configureDisplayShortcut: { _ in false }))
        defer { window.orderOut(nil) }
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let controls = descendants(window.contentView!)
        guard let settings = controls.compactMap({ $0 as? NSPopUpButton }).first,
              let menu = settings.menu,
              let languages = menu.items.compactMap({ $0.submenu }).first,
              let presets = controls.compactMap({ $0 as? NSSegmentedControl }).first else {
            throw WakecupError(message: "Native menu controls are missing")
        }
        try expect(settings.font?.isEqual(AppStyle.Font.body) == true, "Settings popup must use the body text role")
        try expect(menu.font.isEqual(AppStyle.Font.body), "Menu text must use the same role as setting labels")
        try expect(languages.font.isEqual(AppStyle.Font.body), "Language submenu must use the same menu text role")
        guard let helperMenu = menu.items.first(where: { $0.title == localized("Closed-lid permission") })?.submenu,
              let password = helperMenu.item(withTitle: localized("Ask for a password each session")),
              let installed = helperMenu.item(withTitle: localized("Use installed helper")),
              let install = helperMenu.item(withTitle: localized(model.helper.installed ? "Update helper…" : "Install helper…")),
              let explanation = helperMenu.item(withTitle: localized("Why install a helper?")) else {
            throw WakecupError(message: "Both permission modes, installation and explanation must appear in settings")
        }
        try expect(helperMenu.font.isEqual(AppStyle.Font.body), "Helper submenu must use the shared menu text role")
        try expect(password.state == (model.helper.selected ? .off : .on)
                   && installed.state == (model.helper.selected ? .on : .off)
                   && installed.isEnabled == (model.canSelectHelperMode && model.helper.state == .ready)
                   && install.isEnabled == model.canChangeHelper && explanation.isEnabled,
                   "Permission-mode controls must reflect the actual helper state")

        try expect(presets.font?.isEqual(AppStyle.Font.controlLabel) == true, "Preset buttons must use the shared control role")
        let durationEditors = controls.compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        try expect(durationEditors.count == 1, "The end-time input field must be visible")
        for editor in durationEditors {
            try expect(editor.font?.pointSize == AppStyle.Font.body.pointSize,
                       "Time input must use the body text size")
            try expect(editor.font.map { NSFontManager.shared.weight(of: $0) }
                       == NSFontManager.shared.weight(of: AppStyle.Font.body),
                       "Time input must use the regular body text weight")
        }
        let headings = controls.compactMap { $0 as? NSStackView }.filter {
            $0.identifier?.rawValue == "WakecupSectionHeading"
        }
        try expect(headings.count == 2, "Both card headings must use the shared heading component")
        var textOffsets: [CGFloat] = []
        for heading in headings {
            heading.layoutSubtreeIfNeeded()
            guard let icon = heading.arrangedSubviews.first as? NSImageView,
                  let label = heading.arrangedSubviews.last as? NSTextField else {
                throw WakecupError(message: "Section heading is missing its icon or text")
            }
            let iconFrame = heading.convert(icon.alignmentRect(forFrame: icon.frame), from: icon.superview)
            let textFrame = heading.convert(label.alignmentRect(forFrame: label.frame), from: label.superview)
            try expect(abs(iconFrame.midY - textFrame.midY) < 0.1,
                       "Heading icon and text must share the same vertical center: \(iconFrame), \(textFrame)")
            try expect(abs(textFrame.minX - iconFrame.maxX - MenuLayout.headingSpacing) < 0.1,
                       "Heading icon-to-text spacing must match the shared layout")
            try expect(abs(heading.frame.height - MenuLayout.sectionHeight) < 0.1,
                       "Native heading must preserve the approved section height")
            try expect(label.font?.isEqual(AppStyle.Font.sectionTitle) == true,
                       "Native heading must use the section text role")
            textOffsets.append(textFrame.minX)
        }
        try expect(abs(textOffsets[0] - textOffsets[1]) < 0.1, "Card heading titles must share the same leading edge")
        print("PASS: shared text scale, native menu/control roles and aligned card heading icons/text")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw WakecupError(message: message) }
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
