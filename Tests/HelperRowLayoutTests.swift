import AppKit
import SwiftUI

// Only offscreen hosting views and fake helper-state values; no dialogs or activation.
@main struct HelperRowLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let cases: [(String, PrivilegedHelperController.State, Bool, Bool, Bool, HelperStatusPresentation.Action, Bool)] = [
            ("ready", .ready, true, false, false, .settings, false),
            ("password", .ready, false, false, false, .settings, false),
            ("update", .updateRequired, true, false, false, .update, true),
            ("unused-update", .updateRequired, false, false, false, .settings, false),
            ("unavailable", .unavailable, true, false, false, .details, true),
            ("unused-unavailable", .unavailable, false, false, false, .settings, false),
            ("missing", .missing, false, false, false, .install, false),
            ("removed", .missing, true, false, false, .install, true),
            ("checking", .unavailable, true, false, true, .settings, false),
            ("working", .updateRequired, true, true, false, .settings, false)
        ]
        let absent = HelperStatusPresentation(state: .missing, selected: false, working: false, checking: false)
        let removed = HelperStatusPresentation(state: .missing, selected: true, working: false, checking: false)
        try expect(absent.statusKey == removed.statusKey && absent.descriptionKey == removed.descriptionKey,
                   "Missing helper wording must not depend on its previous selection")
        try expect(localized("helper.help") != "helper.help" && !localized("helper.help").isEmpty,
                   "The helper information popup must load the packaged translation")
        var initialSize: NSSize?
        for (name, state, selected, working, checking, action, warning) in cases {
            let presentation = HelperStatusPresentation(state: state, selected: selected, working: working, checking: checking)
            try expect(presentation.action == action && presentation.needsAttention == warning,
                       "Helper state must distinguish user preference from readiness: " + name)
            try expect(localized(presentation.descriptionKey) != presentation.descriptionKey || language == "en",
                       "Helper explanation is not translated: " + name)
            let statusSize = (localized(presentation.statusKey) as NSString).size(withAttributes: [.font: AppStyle.Font.supportingText])
            let availableWidth = MenuLayout.width - 2 * (MenuLayout.panelInset + MenuLayout.inset)
            try expect(ceil(statusSize.width) <= availableWidth,
                       "Helper status must fit one line without clipping: " + name)
            let view = MenuCard {
                MenuSectionHeading(title: localized("Mode"), symbol: "slider.horizontal.3")
                MenuToggleRow(title: localized("Keep awake with lid closed"), isOn: .constant(true), hint: localized("closed.lid.help"))
                HelperStatusRow(presentation: presentation, actionEnabled: !working && !checking, action: {})
                Divider()
                MenuToggleRow(title: localized("Keep awake on battery"), isOn: .constant(true))
            }.padding(MenuLayout.panelInset).frame(width: MenuLayout.width)
                .background(Color(nsColor: NSColor(calibratedWhite: 0.91, alpha: 1)))
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentRect: NSRect(x:0,y:0,width:MenuLayout.width,height:250),styleMask:[.titled],backing:.buffered,defer:false)
            window.contentViewController = hosting
            RunLoop.main.run(until:Date().addingTimeInterval(0.03))
            let size = hosting.view.fittingSize
            if let initialSize { try expect(size == initialSize, "Helper status changed panel geometry: " + name) }
            else { initialSize = size }
            hosting.view.setFrameSize(size);window.setContentSize(size)
            hosting.view.layoutSubtreeIfNeeded();hosting.view.displayIfNeeded()
            if let bitmap = hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds) {
                hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-helper-row-\(name)-\(language).png"))
                }
            }
            window.orderOut(nil)
        }
        print("PASS: helper preference/readiness policy and stable offscreen row layouts for ten states (\(language))")
    }
    private static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw WakecupError(message: message) }
    }
}
