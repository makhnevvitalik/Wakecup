import AppKit
import SwiftUI

// Native text field and stepper keep the infinity state genuinely empty and
// editable. Partial input stays in AppKit's editor until it can form a time.
struct StopTimeField: NSViewRepresentable {
    let date: Date?
    let day: Date
    let now: Date
    let calendar: Calendar
    let invalid: Bool
    let select: (Date) -> Void
    let validation: (Bool) -> Void
    let editingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> StopTimeFieldView { StopTimeFieldView() }
    func updateNSView(_ view: StopTimeFieldView, context: Context) {
        view.update(date: date, day: day, now: now, calendar: calendar, invalid: invalid, enabled: enabled,
                    select: select, validation: validation, editingChanged: editingChanged)
    }
}

final class StopTimeFieldView: NSView, NSTextFieldDelegate {
    private let field = NSTextField()
    private let stepper = NSStepper()
    private var date: Date?
    private var day = Date()
    private var now = Date()
    private var calendar = Calendar.current
    private var textEdited = false
    private var select: (Date) -> Void = { _ in }
    private var validation: (Bool) -> Void = { _ in }
    private var editingChanged: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WakecupStopTimeField")
        field.identifier = NSUserInterfaceItemIdentifier("WakecupEndTime")
        field.font = AppStyle.Font.durationInput; field.alignment = .center
        field.bezelStyle = .roundedBezel; field.usesSingleLineMode = true
        field.isEditable = true; field.isSelectable = true
        field.formatter = TimeTextFormatter(); field.delegate = self
        stepper.minValue = 0; stepper.maxValue = 1439; stepper.valueWraps = true
        stepper.target = self; stepper.action = #selector(step(_:))
        addSubview(field); addSubview(stepper)
    }
    required init?(coder: NSCoder) { nil }

    func update(date: Date?, day: Date, now: Date, calendar: Calendar, invalid: Bool, enabled: Bool,
                select: @escaping (Date) -> Void, validation: @escaping (Bool) -> Void, editingChanged: @escaping (Bool) -> Void) {
        self.date = date; self.day = day; self.now = now; self.calendar = calendar
        self.select = select; self.validation = validation; self.editingChanged = editingChanged
        field.isEnabled = enabled; field.isEditable = enabled; stepper.isEnabled = enabled
        field.textColor = invalid && field.currentEditor() == nil ? .systemRed : .labelColor
        field.setAccessibilityLabel(localized("End time"))
        field.toolTip = localized("Enter a time such as 18:30.")
        stepper.setAccessibilityLabel(localized("End time"))
        let seed = date ?? now
        stepper.doubleValue = Double(calendar.component(.hour, from: seed) * 60 + calendar.component(.minute, from: seed))
        stepper.setAccessibilityValueDescription(date.map { StopTimeInput.text(for: $0, calendar: calendar) } ?? localized("Until stopped manually"))
        if field.currentEditor() == nil && !invalid {
            field.stringValue = date.map { StopTimeInput.text(for: $0, calendar: calendar) } ?? ""
        }
    }
    override func layout() {
        super.layout()
        field.frame = NSRect(x: 0, y: 0, width: bounds.width - 24, height: 25)
        stepper.frame = NSRect(x: bounds.width - 19, y: 0, width: 19, height: 27)
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        textEdited = false; field.textColor = .labelColor; editingChanged(true)
    }
    func controlTextDidChange(_ notification: Notification) { textEdited = true; commit(final: false) }
    func controlTextDidEndEditing(_ notification: Notification) {
        defer { textEdited = false; editingChanged(false) }
        if textEdited { commit(final: true) }
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if textEdited { commit(final: true) }
            textEdited = false
            window?.makeFirstResponder(nil); return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            adjust(increasing: selector == #selector(NSResponder.moveUp(_:))); return true
        }
        return false
    }
    private func commit(final: Bool) {
        guard field.isEnabled else { return }
        guard let chosen = StopTimeInput.date(from: field.stringValue, on: day, calendar: calendar, final: final) else {
            // Merely tabbing through an empty infinity field isn't an edit.
            validation(!(date == nil && field.stringValue.isEmpty && final))
            return
        }
        date = chosen
        validation(false); select(chosen)
        if final { field.stringValue = StopTimeInput.text(for: chosen, calendar: calendar) }
    }
    @objc private func step(_ sender: NSStepper) {
        let seed = date ?? now
        let previous = calendar.component(.hour, from: seed) * 60 + calendar.component(.minute, from: seed)
        let difference = Int(sender.doubleValue) - previous
        adjust(increasing: difference == 1 || difference < -720)
    }
    private func adjust(increasing: Bool) {
        guard field.isEnabled else { return }
        window?.makeFirstResponder(nil)
        let chosen: Date
        if let date { chosen = date.addingTimeInterval(increasing ? 60 : -60) }
        else {
            chosen = calendar.nextDate(after: now.addingTimeInterval(1), matching: DateComponents(second: 0), matchingPolicy: .nextTime)!
        }
        date = chosen
        validation(false); select(chosen)
        field.stringValue = StopTimeInput.text(for: chosen, calendar: calendar)
        stepper.doubleValue = Double(calendar.component(.hour, from: chosen) * 60 + calendar.component(.minute, from: chosen))
        stepper.setAccessibilityValueDescription(field.stringValue)
    }
}

private final class TimeTextFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString; return true
    }
    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?, originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let text = partialStringPtr.pointee as String
        guard text.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) || $0 == 58 }) else { return false }
        // Let Backspace remove the separator; the mask must not trap the caret.
        let deletedColon = origString.contains(":") && origString.replacingOccurrences(of: ":", with: "") == text
        let addColon = !text.contains(":") && (3...4).contains(text.count) && !deletedColon
        let masked = addColon ? String(text.prefix(2)) + ":" + String(text.dropFirst(2)) : text
        let parts = masked.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return false }
        if parts.count == 1 {
            guard text.count <= 4 else { return false }
        } else {
            guard parts.allSatisfy({ $0.count <= 2 }) else { return false }
        }
        let hours = String(parts[0].prefix(2))
        guard hours.count < 2 || (Int(hours).map { $0 <= 23 } ?? false) else { return false }
        if parts.count == 2, parts[1].count == 2 {
            guard let minutes = Int(parts[1]), minutes <= 59 else { return false }
        }
        if addColon {
            partialStringPtr.pointee = masked as NSString
            if let selection = proposedSelRangePtr, selection.pointee.location >= 2 {
                selection.pointee.location += 1
            }
            return false // AppKit applies the replacement and proposed caret position.
        }
        return true
    }
}
