import AppKit
import SwiftUI

struct CalendarDayPicker: NSViewRepresentable {
    let date: Date
    let now: Date
    let calendar: Calendar
    let select: (Date) -> Void

    func makeNSView(context: Context) -> CalendarDayPickerView { CalendarDayPickerView() }
    func updateNSView(_ view: CalendarDayPickerView, context: Context) {
        view.update(date: date, now: now, calendar: calendar, select: select)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CalendarDayPickerView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

// Magnify the native fixed-size grid using AppKit coordinates, rather than
// stretching a bitmap or replacing its date selection and keyboard handling.
final class CalendarDayPickerView: NSView {
    private let picker = NSDatePicker()
    private var select: (Date) -> Void = { _ in }
    private var configuredCalendar: Calendar?
    private var sourceDay: Date?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.datePickerStyle = .clockAndCalendar
        picker.datePickerElements = .yearMonthDay
        picker.focusRingType = .none
        picker.isBordered = false
        picker.drawsBackground = false
        picker.font = AppStyle.Font.body
        picker.target = self; picker.action = #selector(changed(_:))
        picker.identifier = NSUserInterfaceItemIdentifier("WakecupCalendar")
        addSubview(picker)
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let native = picker.intrinsicContentSize
        return NSSize(width: native.width * AppStyle.CalendarLayout.magnification,
                      height: native.height * AppStyle.CalendarLayout.magnification)
    }
    override func layout() {
        super.layout()
        let size = picker.intrinsicContentSize
        if bounds.size != size { setBoundsSize(size) }
        picker.frame = NSRect(origin: .zero, size: size)
    }
    func update(date: Date, now: Date, calendar: Calendar, select: @escaping (Date) -> Void) {
        self.select = select
        let calendarChanged = configuredCalendar != calendar
        if calendarChanged {
            picker.calendar = calendar; picker.locale = calendar.locale; picker.timeZone = calendar.timeZone
            configuredCalendar = calendar
        }
        let minimum = calendar.startOfDay(for: now)
        let maximum = EndTimeSelection.endOfWindow(from: now, calendar: calendar).addingTimeInterval(-1)
        if picker.minDate != minimum { picker.minDate = minimum }
        if picker.maxDate != maximum { picker.maxDate = maximum }
        let clampedDate = min(max(date, minimum), maximum)
        let incomingDay = calendar.startOfDay(for: clampedDate)
        if sourceDay != incomingDay || calendarChanged {
            picker.dateValue = clampedDate
            sourceDay = incomingDay
        }
        picker.setAccessibilityLabel(localized("End day"))
        needsLayout = true
    }
    @objc private func changed(_ sender: NSDatePicker) {
        select(sender.dateValue)
    }
}
