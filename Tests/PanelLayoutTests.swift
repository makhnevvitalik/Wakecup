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
        model.power = .init(onAC: true, percent: 80)
        model.selectEndTimePreset(60)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: "Panel test")
        var reduceMotion = false
        let controller = MenuPanelController(model: model, updates: UpdateChecker(), statusButton: { item.button },
                                             reduceMotion: { reduceMotion })
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
        guard let content = window.contentView,
              content.bounds.maxY - scroll.frame.maxY >= AppStyle.Layout.headerHeight + AppStyle.Layout.sessionActionAreaHeight else {
            throw WakecupError(message: "The header and actions must stay outside the settings scroll view")
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
        model.discardSettingsDraft()
        model.phase = .failed
        guard let actionFeedback = content.constraints.first(where: {
            $0.firstItem === scroll && $0.firstAttribute == .top
        })?.secondItem as? NSView,
              let feedback = bottom.secondItem as? NSView, let incoming = feedback.subviews.last else {
            throw WakecupError(message: "Expected separate feedback regions above and below the settings")
        }
        let settingsTopInset = content.bounds.maxY - scroll.frame.maxY
        let originalDocumentHeight = document.frame.height
        let top = window.frame.maxY
        func transition(to message: SessionMessage?, animated: Bool = true) throws {
            let initialHeight = feedback.frame.height
            let initialWindowHeight = window.frame.height
            var samples: [(height: CGFloat, alpha: CGFloat, windowHeight: CGFloat)] = []
            model.message = message
            let deadline = Date().addingTimeInterval(0.23)
            repeat {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                samples.append((feedback.frame.height, incoming.alphaValue, window.frame.height))
                guard abs(window.frame.maxY - top) < 1 else {
                    throw WakecupError(message: "A feedback transition moved the top edge")
                }
            } while Date() < deadline

            let finalHeight = feedback.frame.height
            let difference = finalHeight - initialHeight
            guard difference != 0, abs(document.frame.height - originalDocumentHeight) < 1,
                  abs(content.bounds.maxY - scroll.frame.maxY - settingsTopInset) < 1,
                  abs(feedback.frame.maxY - scroll.frame.minY) < 1, actionFeedback.frame.height == 0 else {
                throw WakecupError(message: "Feedback must resize its own region without resizing the settings document")
            }
            let intermediate = samples.filter {
                $0.height > min(initialHeight, finalHeight) && $0.height < max(initialHeight, finalHeight)
            }
            if animated {
                guard !intermediate.isEmpty, intermediate.allSatisfy({
                    abs(($0.height - initialHeight) / difference - $0.alpha) <= 1 / abs(difference) + 0.01
                }) else {
                    throw WakecupError(message: "Feedback opacity and geometry must progress together")
                }
                if message?.key == "Short error.", window.frame.height > initialWindowHeight + 1 {
                    guard intermediate.contains(where: { $0.windowHeight > initialWindowHeight && $0.windowHeight < window.frame.height }) else {
                        throw WakecupError(message: "The window must resize on the same frames as the feedback")
                    }
                }
            } else if !intermediate.isEmpty {
                throw WakecupError(message: "Reduce Motion must set feedback height in one step")
            }
        }

        try transition(to: "Short error.")
        try transition(to: SessionMessage(reason: String(repeating: "Sleep restoration was refused by the helper. ", count: 160)))
        guard let screen = window.screen, screen.visibleFrame.contains(window.frame), scroll.frame.height > 0,
              abs(feedback.frame.height - MenuLayout.maximumFeedbackHeight - 2 * AppStyle.Layout.cardSpacing) < 1 else {
            throw WakecupError(message: "Long diagnostics must leave room for the main panel")
        }
        try transition(to: nil)
        reduceMotion = true
        try transition(to: "Short error.", animated: false)
        try transition(to: nil, animated: false)
        model.phase = .authorizing
        settle()
        guard actionFeedback.frame.height > 0, feedback.frame.height == 0,
              SessionFeedback.current(for: model, placement: .primaryAction) != nil else {
            throw WakecupError(message: "An authorization prompt must explain the required action near the main button")
        }
        model.phase = .failed
        model.message = "Short error."
        settle()
        guard actionFeedback.frame.height == 0, feedback.frame.height > 0, incoming.superview === feedback else {
            throw WakecupError(message: "Completing the operation must release the action region and show its result in the footer")
        }
        model.phase = .idle
        model.editAllowBattery(false)
        model.power = .init(onAC: false, percent: 70)
        model.message = "Session ended after power was disconnected."
        bottom.constant = -150
        settle()
        guard actionFeedback.frame.height > 0, feedback.frame.height > 0,
              SessionFeedback.current(for: model, placement: .footer)?.text == "Session ended after power was disconnected.",
              feedback.frame.maxY <= scroll.frame.minY, scroll.contentSize.height > 0 else {
            throw WakecupError(message: "A short panel must show the stop result and the restart restriction together")
        }
        model.power = .init(onAC: true, percent: 70)
        settle()
        guard actionFeedback.frame.height == 0, feedback.frame.height > 0 else {
            throw WakecupError(message: "Removing the power restriction must preserve the last operation result")
        }
        print("PASS: fixed panel actions, scroll position, calendar, independent action and footer feedback, animation and Reduce Motion")
    }

    private static func checkCalendarSelection(in window: NSWindow, model: SessionModel) throws {
        model.phase = .active
        defer { model.phase = .idle }
        settle()
        let before = window.frame
        guard let content = window.contentView,
              let day = descendants(content).compactMap({ $0 as? NSPopUpButton }).first(where: {
                  $0.identifier?.rawValue == "WakecupEndDay"
              }), let time = descendants(content).compactMap({ $0 as? StopTimeFieldView }).first,
              let field = time.subviews.compactMap({ $0 as? NSTextField }).first,
              let stepper = time.subviews.compactMap({ $0 as? NSStepper }).first else {
            throw WakecupError(message: "Missing a stop-time control")
        }
        let centers = [day as NSView, field, stepper].map { $0.convert($0.bounds, to: nil).midY }
        guard let top = centers.max(), let bottom = centers.min(), top - bottom <= 1 else {
            throw WakecupError(message: "The day picker, time field and stepper must share a vertical center")
        }
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
