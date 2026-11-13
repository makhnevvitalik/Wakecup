import AppKit

// Isolated native controls, without a model, helper or real power operations.
@main struct StopTimeDayTests {
 @MainActor static func main() throws {
  NSApplication.shared.setActivationPolicy(.prohibited)
  NSApplication.shared.finishLaunching()
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "Asia/Yekaterinburg")!
  let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 30))!
  for (day, input, interval) in [(now, "2345", 900.0), (now, "0015", -83700.0),
                                  (calendar.date(byAdding: .day, value: 1, to: now)!, "0015", 2700.0)] {
   let view = StopTimeFieldView(frame: NSRect(x: 0, y: 0, width: 94, height: 26))
   let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
   window.contentView = view
   defer { window.orderOut(nil) }
   var selected: Date?
   view.update(date: nil, day: day, now: now, calendar: calendar, invalid: false, enabled: true,
               select: { selected = $0 }, validation: { _ in }, editingChanged: { _ in })
   let field = view.subviews.compactMap { $0 as? NSTextField }.first!
   field.selectText(nil)
   let editor = window.fieldEditor(false, for: field) as! NSTextView
   editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
   guard let selected, calendar.isDate(selected, inSameDayAs: day), selected.timeIntervalSince(now) == interval else {
    fputs("FAIL: Clock input must preserve the selected day and never silently add a day\n", stderr); exit(1)
   }
  }
  print("PASS: infinity clock input preserves today, explicit tomorrow and past-time validation near midnight")
 }
}
