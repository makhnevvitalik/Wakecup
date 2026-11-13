import AppKit

@main struct CalendarDayPickerTests {
    @MainActor static func main() {
        do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let day = Date(timeIntervalSince1970: 1_794_396_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
        for language in ["en", "ru"] {
            calendar.locale = Locale(identifier: language)
            let view = CalendarDayPickerView()
            var selected: [Date] = []
            view.update(date: day, now: day, calendar: calendar) { selected.append($0) }
            let size = view.intrinsicContentSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            view.wantsLayer = true; view.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            for _ in 0..<3 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)); view.layoutSubtreeIfNeeded() }
            let picker = view.subviews.compactMap { $0 as? NSDatePicker }.first!
            let firstDay = calendar.startOfDay(for: day)
            let dayAfterLimit = calendar.date(byAdding: .day, value: 31, to: firstDay)!
            try expect(picker.minDate == firstDay && picker.maxDate == dayAfterLimit.addingTimeInterval(-1),
                       "The native calendar must expose today and exactly thirty more dates")
            let rendered = picker.convert(picker.bounds, to: nil)
            try expect(abs(rendered.width - view.frame.width) < 1 && abs(rendered.height - view.frame.height) < 1,
                       "The native calendar grid must fill its scaled view rather than adding empty padding")
            try expect(picker.isEnabled && picker.focusRingType == .none && window.makeFirstResponder(picker),
                       "The calendar must retain keyboard focus without a frame around the whole grid")
            try expect(selected.isEmpty, "Preparing the calendar must not apply a date or close the popover")
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
            let arrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            let right = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                isARepeat: false, keyCode: 124)!
            picker.keyDown(with: right)
            try expect(selected.isEmpty, "Keyboard navigation must not close the calendar or apply a date before confirmation")
            view.update(date: day, now: day, calendar: calendar) { selected.append($0) }
            try expect(calendar.isDate(picker.dateValue, inSameDayAs: tomorrow), "A normal view refresh must not reset keyboard navigation or the browsed month")
            let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49)!
            picker.keyDown(with: space)
            try expect(selected == [tomorrow], "Confirming the enlarged native calendar must deliver the highlighted day")
            view.displayIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-calendar-\(language).png"))
            }
            window.orderOut(nil)
        }
        print("PASS: enlarged native calendar coordinates, keyboard focus, no outer focus ring, date callback and no changes on setup")
    }
    static func expect(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "CalendarDayPickerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
