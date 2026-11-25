import AppKit

// Isolated native controls, without a model, helper or real power operations.
@main struct StopTimeDayTests {
 @MainActor static func main() throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  NSApplication.shared.finishLaunching()
  if CommandLine.arguments.contains("--fold") {
   try testRepeatedHour()
   return
  }
  if CommandLine.arguments.contains("--empty-step") {
   try testInitialStepper()
   return
  }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
  let clock = StopTimeInput.Clock(locale: Locale(identifier: "en-GB-u-hc-h23"), calendar: calendar)
  for (day, input, interval) in [(now, "2345", 900.0), (now, "0015", -83700.0),
                                  (calendar.date(byAdding: .day, value: 1, to: now)!, "0015", 2700.0)] {
   let view = StopTimeFieldView(frame: NSRect(x: 0, y: 0, width: 94, height: 26))
   let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
   window.contentView = view
   defer { window.orderOut(nil) }
   var selected: Date?
   view.update(date: nil, unresolvedTime: nil, day: day, now: now, clock: clock, invalid: false, enabled: true,
               edit: { if case .resolved(let date) = $0 { selected = date } }, editingChanged: { _ in })
   let field = view.subviews.compactMap { $0 as? NSTextField }.first!
   field.selectText(nil)
   let editor = window.fieldEditor(false, for: field) as! NSTextView
   editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
   guard let selected, calendar.isDate(selected, inSameDayAs: day), selected.timeIntervalSince(now) == interval else {
    fputs("FAIL: Clock input must preserve the selected day and never silently add a day\n", stderr); exit(1)
   }
  }
  let twelveHour = StopTimeInput.Clock(locale: Locale(identifier: "en-US-u-hc-h12"), calendar: calendar)
  let view = StopTimeFieldView(frame: NSRect(origin: .zero, size: NSSize(width: 160, height: 26)))
  let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = view
  defer { window.orderOut(nil) }
  var selected: Date?
  view.update(date: nil, unresolvedTime: nil, day: now, now: now, clock: twelveHour, invalid: false, enabled: true,
              edit: { if case .resolved(let date) = $0 { selected = date } }, editingChanged: { _ in })
  let period = view.subviews.compactMap { $0 as? NSPopUpButton }.first!
  precondition(!period.isHidden && period.itemTitles == ["AM", "PM"])
  period.selectItem(at: 0)
  period.sendAction(period.action, to: period.target)
  precondition(selected == nil, "Choosing AM alone must keep infinity")
  let field = view.subviews.compactMap { $0 as? NSTextField }.first!
  field.selectText(nil)
  let editor = window.fieldEditor(false, for: field) as! NSTextView
  editor.insertText("1200", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
  precondition(selected == calendar.startOfDay(for: now), "Typing 12:00 with AM must select midnight")
  window.makeFirstResponder(nil)
  period.selectItem(at: 1)
  period.sendAction(period.action, to: period.target)
  precondition(selected == calendar.startOfDay(for: now).addingTimeInterval(12 * 3600),
               "Changing AM to PM must switch to noon on the same day")
  var eastern = Calendar(identifier: .gregorian)
  eastern.timeZone = TimeZone(identifier: "America/New_York")!
  let gapClock = StopTimeInput.Clock(locale: Locale(identifier: "en-US-u-hc-h12"), calendar: eastern)
  let gapDay = eastern.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 14, minute: 30))!
  var invalid = false
  var unresolved: EndTimeSelection.ClockTime?
  selected = gapDay
  func renderGap() {
   view.update(date: selected, unresolvedTime: unresolved, day: gapDay, now: gapDay,
               clock: gapClock, invalid: invalid, enabled: true, edit: { edit in
    switch edit {
    case .resolved(let date): selected = date; unresolved = nil; invalid = false
    case .nonexistent(let time, _): unresolved = time; invalid = true
    case .incomplete, .empty: invalid = true
    }
   }, editingChanged: { _ in })
  }
  renderGap()
  period.selectItem(at: 0)
  period.sendAction(period.action, to: period.target)
  renderGap()
  precondition(invalid && period.indexOfSelectedItem == 0 && selected == gapDay,
               "Keep the attempted AM visible when that hour does not exist")
  period.selectItem(at: 1)
  period.sendAction(period.action, to: period.target)
  renderGap()
  precondition(!invalid && selected == gapDay, "Switching back to PM must clear the invalid state")
  print("PASS: infinity clock input preserves today, explicit tomorrow and past-time validation near midnight")
  try testStepperAtEndOfDayGap()
  try testCenteredClockText()
 }

 @MainActor private static func testCenteredClockText() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let date = calendar.date(from: DateComponents(year: 2027, month: 1, day: 3, hour: 18, minute: 30))!
  for locale in ["en-GB-u-hc-h23", "en-US-u-hc-h12"] {
   let clock = StopTimeInput.Clock(locale: Locale(identifier: locale), calendar: calendar)
   let view = StopTimeFieldView()
   view.update(date: date, unresolvedTime: nil, day: date, now: date, clock: clock, invalid: false,
               enabled: true, edit: { _ in }, editingChanged: { _ in })
   view.frame.size = view.intrinsicContentSize
   let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
   window.contentView = view
   defer { window.orderOut(nil) }
   view.layoutSubtreeIfNeeded()

   let field = view.subviews.compactMap { $0 as? NSTextField }.first!
   let displayTop = field.cell!.drawingRect(forBounds: field.bounds).minY
   field.selectText(nil)
   let editor = field.currentEditor() as! NSTextView
   let editingTop = editor.convert(editor.bounds, to: field).minY + editor.textContainerOrigin.y
   let font = field.font!
   let layout = editor.layoutManager!
   let lineCenter = editingTop + layout.defaultLineHeight(for: font) / 2
   let roundingAllowance = 0.5 / window.backingScaleFactor
   try expect(abs(lineCenter - field.bounds.midY) <= roundingAllowance,
              "Center the editable line, including the caret, for \(locale)")
   let figureCenter = layout.defaultBaselineOffset(for: font) - font.capHeight / 2
   for (state, top) in [("display", displayTop), ("editing", editingTop)] {
    try expect(abs(top + figureCenter - field.bounds.midY) <= 0.75,
               "Center the digits vertically in the bezel during \(state) for \(locale)")
   }
  }
  print("PASS: 12/24-hour digits stay vertically centered with and without editing")
 }

 @MainActor private static func testStepperAtEndOfDayGap() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/Nuuk")!
  let day = calendar.date(from: DateComponents(year: 2027, month: 3, day: 27, hour: 12))!
  let lastMinute = calendar.date(from: DateComponents(year: 2027, month: 3, day: 27, hour: 22, minute: 59))!
  let missing = EndTimeSelection.ClockTime(hour: 23, minute: 30)!
  let clock = StopTimeInput.Clock(locale: Locale(identifier: "en-GB-u-hc-h23"), calendar: calendar)
  let view = StopTimeFieldView(frame: NSRect(x: 0, y: 0, width: 94, height: 26))
  let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = view
  defer { window.orderOut(nil) }
  var selected: Date?
  view.update(date: nil, unresolvedTime: missing, day: day, now: day, clock: clock, invalid: true, enabled: true,
              edit: { if case .resolved(let date) = $0 { selected = date } }, editingChanged: { _ in })
  let stepper = view.subviews.compactMap { $0 as? NSStepper }.first!
  for _ in 0..<2 {
   stepper.integerValue += 1
   stepper.sendAction(stepper.action, to: stepper.target)
   try expect(selected == nil, "Repeated Up must leave a skipped final hour unresolved on the same day")
  }
  stepper.integerValue -= 1
  stepper.sendAction(stepper.action, to: stepper.target)
  try expect(selected == lastMinute, "Down after repeated Up must select the last real minute of the day")
  print("PASS: stepper handles both directions at a skipped final hour")
 }

 @MainActor private static func testRepeatedHour() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "America/New_York")!
  let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
  let secondOccurrence = start.addingTimeInterval(150 * 60)
  for (locale, now, existing) in [("en-US-u-hc-h12", secondOccurrence.addingTimeInterval(-20 * 60), nil),
                                  ("en-GB-u-hc-h23", start, secondOccurrence)] as [(String, Date, Date?)] {
   let clock = StopTimeInput.Clock(locale: Locale(identifier: locale), calendar: calendar)
   let view = StopTimeFieldView(frame: NSRect(x: 0, y: 0, width: 160, height: 26))
   let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
   window.contentView = view
   defer { window.orderOut(nil) }
   var selected: Date?
   view.update(date: existing, unresolvedTime: nil, day: start, now: now, clock: clock, invalid: false, enabled: true,
               edit: { if case .resolved(let date) = $0 { selected = date } }, editingChanged: { _ in })
   let field = view.subviews.compactMap { $0 as? NSTextField }.first!
   field.selectText(nil)
   let editor = window.fieldEditor(false, for: field) as! NSTextView
   editor.insertText("0130", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
   try expect(selected == secondOccurrence, "A repeated time must use its upcoming occurrence or keep the explicitly selected occurrence")
  }
  print("PASS: native 12/24-hour entry resolves both occurrences of a repeated hour")
 }

 @MainActor private static func testInitialStepper() throws {
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(secondsFromGMT: 0)!
  let clock = StopTimeInput.Clock(locale: Locale(identifier: "en-GB-u-hc-h23"), calendar: calendar)
  for (second, minutes) in [(50, 1), (55, 2)] {
   let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 30, second: second))!
   let view = StopTimeFieldView(frame: NSRect(x: 0, y: 0, width: 94, height: 26))
   let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
   window.contentView = view
   defer { window.orderOut(nil) }
   var selected: Date?
   view.update(date: nil, unresolvedTime: nil, day: now, now: now, clock: clock, invalid: false, enabled: true,
               edit: { if case .resolved(let date) = $0 { selected = date } }, editingChanged: { _ in })
   let stepper = view.subviews.compactMap { $0 as? NSStepper }.first!
   stepper.integerValue += 1
   stepper.sendAction(stepper.action, to: stepper.target)
   let expected = now.addingTimeInterval(Double(minutes * 60 - second))
   try expect(selected == expected, "The first step must choose the first minute that satisfies the minimum duration")
  }
  print("PASS: initial stepper uses the earliest valid minute")
 }

 private static func expect(_ value: Bool, _ message: String) throws {
  if !value { throw NSError(domain: "StopTimeDayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
 }
}
