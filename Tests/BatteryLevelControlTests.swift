import AppKit

@main struct BatteryLevelControlTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.finishLaunching()
        let view = BatteryLevelScaleView(frame: NSRect(x: 0, y: 0, width: 332, height: 44))
        let window = NSWindow(contentRect: view.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.orderOut(nil) }
        var changes: [Double] = []
        func configure(_ threshold: Double, _ charge: Int?, enabled: Bool = true) {
            view.update(threshold: threshold, charge: charge, enabled: enabled) { changes.append($0) }
            view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        }
        configure(30, 72)
        let slider = view.subviews.compactMap { $0 as? NSSlider }.first!
        let cell = slider.cell as! NSSliderCell
        try expect(slider.minValue == 10 && slider.maxValue == 90 && slider.doubleValue == 30,
                   "The native slider must expose only the editable threshold range")
        try expect(slider.isEnabled && slider.numberOfTickMarks == 81 && slider.allowsTickMarkValuesOnly,
                   "Native pointer and keyboard input must use whole percentages")
        for threshold in [10.0, 30, 50, 90] {
            configure(threshold, 72)
            let knob = view.convert(cell.knobRect(flipped: false), from: slider)
            let expected = view.trackRect.minX + view.trackRect.width * (threshold - 1) / 99
            try expect(abs(knob.midX - expected) < 1.5, "Threshold thumb must align with the 1–100 charge scale: \(threshold), \(knob.midX), \(expected)")
        }
        configure(30, 72)
        _ = slider.accessibilityPerformIncrement()
        try expect(changes.last == 31 && slider.doubleValue == 31, "VoiceOver increment must change the threshold by one percent")
        _ = slider.accessibilityPerformDecrement()
        try expect(changes.last == 30, "VoiceOver decrement must change the threshold by one percent")
        for threshold in [10.0, 90] {
            configure(threshold, 72)
            _ = threshold == 10 ? slider.accessibilityPerformDecrement() : slider.accessibilityPerformIncrement()
            try expect(slider.doubleValue == threshold, "Accessibility cannot move beyond the allowed threshold")
        }
        configure(30, 72)
        try expect(window.makeFirstResponder(slider), "The slider must accept keyboard focus")
        for (code, character, expected) in [(UInt16(124), NSRightArrowFunctionKey, 31.0), (UInt16(123), NSLeftArrowFunctionKey, 30.0)] {
            let arrow = String(UnicodeScalar(character)!)
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                isARepeat: false, keyCode: code)!
            slider.keyDown(with: event)
            try expect(changes.last == expected && slider.doubleValue == expected,
                       "Keyboard arrows must change the threshold by one percent")
        }
        let count = changes.count
        configure(30, 72, enabled: false)
        slider.sendAction(slider.action, to: slider.target)
        try expect(changes.count == count, "Disabled threshold cannot update settings")
        let baseline = view.frame.size
        for charge in [0, 1, 5, 10, 11, 30, 50, 90, 99, 100, nil] as [Int?] {
            configure(30, charge)
            let labels = view.subviews.compactMap { $0 as? NSTextField }.sorted { $0.frame.minX < $1.frame.minX }
            try expect(view.frame.size == baseline && labels.count == 3, "Charge updates must not resize or remove scale labels")
            for label in labels { try expect(view.bounds.contains(label.frame), "Charge captions must fit at either end of the scale") }
            try expect(labels[0].frame.maxX <= labels[1].frame.minX && labels[1].frame.maxX <= labels[2].frame.minX,
                       "Current charge caption must not overlap the 1% or 100% endpoints")
            try expect(slider.doubleValue == 30, "Incoming charge updates must not move the chosen threshold")
        }
        print("PASS: common charge/threshold geometry, native accessibility steps and bounds, disabled input, unknown/low/full charge captions")
    }
    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "BatteryLevelControlTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
}
