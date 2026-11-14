import AppKit
import Foundation

// Runs in a macOS graphical session. Uses isolated preferences and never starts a sleep session.
@main struct PanelLayoutTests {
    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let suite = "WakecupPanelTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionModel(defaults: defaults)
        model.selectEndTimePreset(60)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Panel test")
        let controller = MenuPanelController(model: model, statusButton: { item.button }, configureDisplayShortcut: { _ in false })
        defer { controller.close(); NSStatusBar.system.removeStatusItem(item) }
        controller.show()
        settle()
        guard let window = app.windows.first(where: { $0.title == "Wakecup" }) else {
            throw WakecupError(message: "Panel did not open")
        }
        let initial = window.frame
        for preset in [180, 300, 0, 60] {
            model.selectEndTimePreset(preset)
            settle()
            guard window.frame == initial else {
                throw WakecupError(message: "Duration selection changed the panel size or position")
            }
        }
        for closedLid in [true, false] {
            model.editClosedLid(closedLid)
            settle()
            guard window.frame == initial else {
                throw WakecupError(message: "Closed-lid permission detail changed the panel frame")
            }
        }
        model.selectEndDate(model.currentDate.addingTimeInterval(2 * 3_600 + 35 * 60))
        settle()
        guard window.frame == initial else {
            throw WakecupError(message: "Entering a custom end time moved the panel")
        }
        model.setEndTimeInputInvalid(true)
        settle()
        guard window.frame == initial else {
            throw WakecupError(message: "Invalid time input moved the panel")
        }
        model.selectEndTimePreset(0)
        settle()
        guard window.frame == initial else {
            throw WakecupError(message: "Returning to infinity changed the panel frame")
        }
        guard let scroll = window.contentView?.subviews.compactMap({ $0 as? NSScrollView }).first,
              let document = scroll.documentView, abs(document.frame.height - document.fittingSize.height) < 1 else {
            throw WakecupError(message: "Hosting view clips the permanent duration editor")
        }
        item.isVisible = false
        settle()
        guard controller.isVisible, window.frame == initial else {
            throw WakecupError(message: "Hiding the status icon moved or closed the panel")
        }
        // Give the native clip view a shorter viewport without changing the Mac's screen settings.
        guard let bottom = window.contentView?.constraints.first(where: {
            $0.firstItem === scroll && $0.firstAttribute == .bottom
        }) else { throw WakecupError(message: "Scroll viewport constraint not found") }
        bottom.constant = -150
        window.contentView?.layoutSubtreeIfNeeded()
        settle()
        let available = document.bounds.height - scroll.contentSize.height
        guard available > 40 else { throw WakecupError(message: "Expected a scrollable test viewport") }
        let position: CGFloat = 40
        let origin = document.isFlipped ? position : available - position
        scroll.contentView.scroll(to: NSPoint(x: 0, y: origin))
        scroll.reflectScrolledClipView(scroll.contentView)
        let beforeResize = scroll.documentVisibleRect
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        settle()
        guard abs(scroll.documentVisibleRect.minY - beforeResize.minY) < 1 else {
            throw WakecupError(message: "Relayout reset the current scroll position")
        }
        controller.close()
        guard !controller.isVisible else { throw WakecupError(message: "Panel did not close") }
        controller.show()
        settle()
        let visible = scroll.documentVisibleRect
        let distanceFromTop = document.isFlipped ? visible.minY - document.bounds.minY : document.bounds.maxY - visible.maxY
        guard abs(distanceFromTop) < 1 else { throw WakecupError(message: "Reopened panel did not scroll to top") }
        bottom.constant = 0
        try checkCalendarSelection(in: window, model: model)
        print("PASS: panel dimensions, scroll position, reopening, icon hiding and calendar selection")
    }

    private static func checkCalendarSelection(in window: NSWindow, model: SessionModel) throws {
        model.phase = .active
        defer { model.phase = .idle }
        settle()
        let before = window.frame
        guard let content = window.contentView,
              let day = descendants(content).compactMap({ $0 as? NSPopUpButton }).first(where: {
                  $0.identifier?.rawValue == "WakecupEndDay"
              }) else { throw WakecupError(message: "End-day control is missing") }
        day.selectItem(at: day.numberOfItems - 1)
        day.sendAction(day.action, to: day.target)
        settle()
        let popoverViews = NSApp.windows.filter(\.isVisible).compactMap(\.contentView).flatMap(descendants)
        guard let picker = popoverViews.compactMap({ $0 as? NSDatePicker }).first(where: {
            $0.identifier?.rawValue == "WakecupCalendar"
        }), let future = Calendar.current.date(byAdding: .day, value: 16, to: model.currentDate) else {
            throw WakecupError(message: "The calendar did not open")
        }

        // Simulate a window adjustment during popover tracking.
        window.setFrame(window.frame.offsetBy(dx: 0, dy: -40), display: false)
        picker.dateValue = future
        picker.sendAction(picker.action, to: picker.target)
        settle()

        guard model.showsSettingsActions, let selected = model.selectedEndDate,
              Calendar.current.isDate(selected, inSameDayAs: future) else {
            throw WakecupError(message: "A future date must produce an unapplied edit")
        }
        guard let screen = window.screen, screen.visibleFrame.contains(window.frame),
              abs(window.frame.maxY - before.maxY) < 1,
              abs(window.frame.minX - before.minX) < 1 else {
            throw WakecupError(message: "Picking a date moved the panel away from its anchor")
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private static func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
}
