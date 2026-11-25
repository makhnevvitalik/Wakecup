import AppKit
import SwiftUI

// Native text field and stepper keep the infinity state genuinely empty and
// editable. Partial input stays in AppKit's editor until it can form a time.
struct StopTimeField: NSViewRepresentable {
    let date: Date?
    let unresolvedTime: EndTimeSelection.ClockTime?
    let day: Date
    let now: Date
    let clock: StopTimeInput.Clock
    let invalid: Bool
    let replacementID: UUID?
    let edit: (EndTimeSelection.ClockEdit) -> Void
    let editingChanged: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled

    func makeNSView(context: Context) -> StopTimeFieldView { StopTimeFieldView() }
    func updateNSView(_ view: StopTimeFieldView, context: Context) {
        view.update(date: date, unresolvedTime: unresolvedTime, day: day, now: now, clock: clock, invalid: invalid,
                    enabled: enabled, replacementID: replacementID, edit: edit, editingChanged: editingChanged)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StopTimeFieldView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

final class StopTimeFieldView: NSView, NSTextFieldDelegate {
    private let field = StopTimeTextField()
    private let stepper = NSStepper()
    private let period = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatter = TimeTextFormatter()
    private var clock = StopTimeInput.Clock()
    private var calendar: Calendar { clock.calendar }
    private var date: Date?
    private var unresolvedTime: EndTimeSelection.ClockTime?
    private var day = Date()
    private var now = Date()
    private var textEdited = false
    private var replacementID: UUID?
    private var edit: (EndTimeSelection.ClockEdit) -> Void = { _ in }
    private var editingChanged: (Bool) -> Void = { _ in }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WakecupStopTimeField")
        field.identifier = NSUserInterfaceItemIdentifier("WakecupEndTime")
        field.font = AppStyle.Font.durationInput; field.alignment = .center
        field.bezelStyle = .roundedBezel; field.usesSingleLineMode = true
        field.controlSize = .small
        field.isEditable = true; field.isSelectable = true
        field.formatter = formatter; field.delegate = self
        period.identifier = NSUserInterfaceItemIdentifier("WakecupEndTimePeriod")
        period.controlSize = .small
        period.font = AppStyle.Font.controlLabel
        period.target = self; period.action = #selector(changePeriod(_:))
        stepper.controlSize = .small
        stepper.minValue = 0; stepper.maxValue = 1439; stepper.valueWraps = true
        stepper.target = self; stepper.action = #selector(step(_:))
        addSubview(field); addSubview(period); addSubview(stepper)
    }
    required init?(coder: NSCoder) { nil }

    func update(date: Date?, unresolvedTime: EndTimeSelection.ClockTime?, day: Date, now: Date,
                clock: StopTimeInput.Clock, invalid: Bool, enabled: Bool, replacementID: UUID? = nil,
                edit: @escaping (EndTimeSelection.ClockEdit) -> Void, editingChanged: @escaping (Bool) -> Void) {
        let replacesInput = self.replacementID != replacementID
        self.replacementID = replacementID
        let clearPeriod = (self.date != nil || self.unresolvedTime != nil) && date == nil && unresolvedTime == nil
        let showsNewUnresolvedTime = unresolvedTime != nil
            && (self.unresolvedTime != unresolvedTime || !clock.calendar.isDate(self.day, inSameDayAs: day))
        let canRenderValue = !invalid || showsNewUnresolvedTime
        self.date = date; self.unresolvedTime = unresolvedTime; self.day = day; self.now = now; self.clock = clock
        formatter.clock = clock
        self.edit = edit; self.editingChanged = editingChanged
        let currentTime = shownTime ?? EndTimeSelection.ClockTime(now, calendar: clock.calendar)
        let periodVisibilityChanged = period.isHidden != clock.periods.isEmpty
        if period.itemTitles != clock.periods || periodVisibilityChanged {
            period.removeAllItems(); period.addItems(withTitles: clock.periods)
            period.isHidden = clock.periods.isEmpty
            if !period.isHidden { syncPeriod(for: currentTime) }
            invalidateIntrinsicContentSize()
        }
        needsLayout = true
        if !period.isHidden, canRenderValue, shownTime != nil || clearPeriod || replacesInput || period.indexOfSelectedItem < 0 {
            syncPeriod(for: currentTime)
        }
        period.isEnabled = enabled
        period.setAccessibilityLabel(localized("Time of day"))
        field.isEnabled = enabled; field.isEditable = enabled; stepper.isEnabled = enabled
        field.textColor = invalid && field.currentEditor() == nil ? .systemRed : .labelColor
        field.setAccessibilityLabel(localized("End time"))
        field.toolTip = localizedFormat("Enter a time such as %@.", clock.example(on: now))
        stepper.setAccessibilityLabel(localized("End time"))
        stepper.doubleValue = Double(currentTime.hour * 60 + currentTime.minute)
        let description = unresolvedTime == nil
            ? date.map { clock.time($0) } ?? localized("Until stopped manually")
            : localized(EndTimeSelection.Issue.nonexistentTime.messageKey)
        stepper.setAccessibilityValueDescription(description)
        let editor = field.currentEditor() as? NSTextView
        if replacesInput {
            // The accepted automation value supersedes the unfinished local edit.
            textEdited = false
            if let editor {
                let text = shownTime.map { clock.editorText($0) } ?? ""
                editor.string = text
                editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
            }
        }
        if editor == nil && canRenderValue {
            field.stringValue = shownTime.map { clock.editorText($0) } ?? ""
        }
    }

    private var shownTime: EndTimeSelection.ClockTime? {
        unresolvedTime ?? date.map { EndTimeSelection.ClockTime($0, calendar: calendar) }
    }

    private var periodWidth: CGFloat {
        guard !clock.periods.isEmpty else { return 0 }
        let font = AppStyle.Font.controlLabel
        let titleWidth = clock.periods.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return ceil(titleWidth) + 29
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 94 + (periodWidth > 0 ? periodWidth + 4 : 0), height: 26)
    }

    override func layout() {
        super.layout()
        let stepSize = stepper.intrinsicContentSize
        let fieldHeight: CGFloat = stepSize.height - 2
        let extraWidth = periodWidth > 0 ? periodWidth + 4 : 0
        let fieldWidth = max(0, bounds.width - stepSize.width - 5 - extraWidth)
        let fieldX = bounds.minX + (clock.periodFirst ? extraWidth : 0)
        let periodX = clock.periodFirst ? bounds.minX : fieldX + fieldWidth + 4
        field.frame = NSRect(x: fieldX, y: bounds.midY - fieldHeight / 2, width: fieldWidth, height: fieldHeight)
        period.frame = NSRect(x: periodX, y: bounds.midY - fieldHeight / 2, width: periodWidth, height: fieldHeight)
        stepper.frame = NSRect(x: bounds.maxX - stepSize.width, y: bounds.midY - stepSize.height / 2,
                               width: stepSize.width, height: stepSize.height)
    }

    private func syncPeriod(for time: EndTimeSelection.ClockTime) {
        period.selectItem(at: time.hour < 12 ? 0 : 1)
    }

    @objc private func changePeriod(_ sender: NSPopUpButton) {
        guard sender.isEnabled, !field.stringValue.isEmpty else { return }
        commit(final: true)
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
        if final && field.stringValue.isEmpty {
            edit(.empty)
            return
        }
        guard let time = clock.clockTime(from: field.stringValue, afternoon: period.indexOfSelectedItem == 1,
                                         final: final) else {
            edit(.incomplete)
            return
        }
        if let chosen = time.date(on: day, calendar: calendar, from: now, preserving: date) {
            date = chosen
            unresolvedTime = nil
            edit(.resolved(chosen))
        } else {
            unresolvedTime = time
            edit(.nonexistent(time, on: day))
        }
        if final { field.stringValue = clock.editorText(time) }
    }
    @objc private func step(_ sender: NSStepper) {
        let seed = shownTime ?? EndTimeSelection.ClockTime(now, calendar: calendar)
        let previous = seed.hour * 60 + seed.minute
        let difference = Int(sender.doubleValue) - previous
        sender.doubleValue = Double(previous)
        adjust(increasing: difference == 1 || difference < -720)
    }
    private func adjust(increasing: Bool) {
        guard field.isEnabled else { return }
        window?.makeFirstResponder(nil)
        let next: Date?
        if let unresolvedTime {
            next = clock.steppedDate(from: unresolvedTime, on: day, increasing: increasing)
        } else if let date {
            next = clock.steppedDate(from: date, on: day, increasing: increasing)
        } else {
            next = EndTimeSelection.firstSelectableMinute(from: now, calendar: calendar)
        }
        guard let chosen = next else { return }
        let time = EndTimeSelection.ClockTime(chosen, calendar: calendar)
        date = chosen
        day = chosen
        unresolvedTime = nil
        edit(.resolved(chosen))
        field.stringValue = clock.editorText(time)
        if !period.isHidden { syncPeriod(for: time) }
        stepper.doubleValue = Double(time.hour * 60 + time.minute)
        stepper.setAccessibilityValueDescription(clock.time(chosen))
    }
}

private final class StopTimeTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { StopTimeTextFieldCell.self }
        set { super.cellClass = newValue }
    }
}

private final class StopTimeTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let drawing = super.drawingRect(forBounds: rect)
        guard let font else { return drawing }
        // The field editor draws its insertion point across the full line height.
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        return drawing.offsetBy(dx: 0, dy: rect.midY - drawing.minY - lineHeight / 2)
    }
}

private final class TimeTextFormatter: Formatter {
    var clock = StopTimeInput.Clock()
    override func string(for obj: Any?) -> String? { obj as? String }
    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        obj?.pointee = string as NSString; return true
    }
    override func isPartialStringValid(_ partialStringPtr: AutoreleasingUnsafeMutablePointer<NSString>,
        proposedSelectedRange proposedSelRangePtr: NSRangePointer?, originalString origString: String,
        originalSelectedRange origSelRange: NSRange,
        errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        let proposedText = partialStringPtr.pointee as String
        let original = clock.input(origString)
        if let selection = proposedSelRangePtr, selection.pointee.length == 0,
           let separator = original?.separatorRange,
           Self.deletedPart(of: separator, in: origString, toProduce: proposedText, at: selection.pointee.location) {
            partialStringPtr.pointee = origString.replacingCharacters(in: separator, with: "") as NSString
            selection.pointee.location = NSRange(separator, in: origString).location
            return false
        }

        guard let input = clock.input(proposedText), input.digitsAndColon.count <= 5 else { return false }
        let text = input.digitsAndColon
        // Let Backspace remove the separator; the mask must not trap the caret.
        let deletedSeparator = original?.separatorRange != nil
            && original?.digitsAndColon.replacingOccurrences(of: ":", with: "") == text
        let addSeparator = input.separatorRange == nil && (3...4).contains(text.count) && !deletedSeparator
        let masked = addSeparator ? String(text.prefix(2)) + ":" + String(text.dropFirst(2)) : text
        let parts = masked.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, parts.allSatisfy({ $0.count <= (parts.count == 1 ? 4 : 2) }) else { return false }
        let maximumHour: Int
        switch clock.hourCycle {
        case .zeroToEleven: maximumHour = 11
        case .oneToTwelve: maximumHour = 12
        case .oneToTwentyFour: maximumHour = 24
        default: maximumHour = 23
        }
        let hours = parts[0].prefix(2)
        guard hours.count < 2 || (Int(hours).map { $0 <= maximumHour } ?? false) else { return false }
        if parts.count == 2, parts[1].count == 2 {
            guard let minutes = Int(parts[1]), minutes <= 59 else { return false }
        }
        let replacement: Range<String.Index>
        if addSeparator {
            let insertion = proposedText.index(proposedText.startIndex, offsetBy: 2)
            replacement = insertion..<insertion
        } else if let separator = input.separatorRange, proposedText[separator] != clock.separator {
            replacement = separator
        } else {
            return true
        }

        partialStringPtr.pointee = proposedText.replacingCharacters(in: replacement, with: clock.separator) as NSString
        if let selection = proposedSelRangePtr {
            let replaced = NSRange(replacement, in: proposedText)
            let delta = clock.separator.utf16.count - replaced.length
            let start = Self.offset(selection.pointee.location, afterReplacing: replaced, delta: delta)
            let end = Self.offset(NSMaxRange(selection.pointee), afterReplacing: replaced, delta: delta)
            selection.pointee = NSRange(location: start, length: end - start)
        }
        return false // AppKit applies the replacement and proposed caret position.
    }

    private static func deletedPart(of separator: Range<String.Index>, in original: String,
                                    toProduce proposed: String, at location: Int) -> Bool {
        let bounds = NSRange(separator, in: original)
        let removed = original.utf16.count - proposed.utf16.count
        guard removed > 0, removed < bounds.length, NSLocationInRange(location, bounds),
              removed <= NSMaxRange(bounds) - location,
              let range = Range(NSRange(location: location, length: removed), in: original) else { return false }
        return original.replacingCharacters(in: range, with: "") == proposed
    }

    private static func offset(_ location: Int, afterReplacing range: NSRange, delta: Int) -> Int {
        if location < range.location { return location }
        if location >= NSMaxRange(range) { return location + delta }
        return range.location
    }
}
