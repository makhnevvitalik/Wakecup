import AppKit
import SwiftUI

// The charge uses the full 1–100 scale. The native slider occupies only its
// 10–90 region, retaining AppKit tracking, focus, keyboard and accessibility.
struct BatteryLevelControl: NSViewRepresentable {
    @Binding var threshold: Double
    let charge: Int?
    var thresholdEnabled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> BatteryLevelScaleView { BatteryLevelScaleView() }
    func updateNSView(_ view: BatteryLevelScaleView, context: Context) {
        view.update(threshold: threshold, charge: charge, enabled: isEnabled && thresholdEnabled) { threshold = $0 }
    }
}

final class BatteryLevelScaleView: NSView {
    private let slider = NSSlider()
    private let lowerLabel = NSTextField(labelWithString: "1%")
    private let upperLabel = NSTextField(labelWithString: "100%")
    private let chargeLabel = NSTextField(labelWithString: "")
    private var charge: Int?
    private var onChange: (Double) -> Void = { _ in }
    private(set) var trackRect = NSRect.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("WakecupBatteryScale")
        slider.cell = BatteryThresholdCell()
        slider.controlSize = .small
        slider.minValue = Double(BatteryThreshold.range.lowerBound); slider.maxValue = Double(BatteryThreshold.range.upperBound)
        slider.numberOfTickMarks = BatteryThreshold.range.count; slider.allowsTickMarkValuesOnly = true
        slider.isContinuous = true
        slider.identifier = NSUserInterfaceItemIdentifier("WakecupBatteryThreshold")
        slider.target = self; slider.action = #selector(changeThreshold(_:))
        addSubview(slider)
        for label in [lowerLabel, upperLabel, chargeLabel] {
            label.font = AppStyle.Font.supportingText
            label.textColor = .secondaryLabelColor
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(label)
        }
        chargeLabel.alignment = .center
        lowerLabel.setAccessibilityElement(false)
        upperLabel.setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func update(threshold: Double, charge: Int?, enabled: Bool, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.charge = charge.flatMap { (0...100).contains($0) ? $0 : nil }
        slider.doubleValue = threshold
        slider.isEnabled = enabled
        slider.isHidden = !enabled
        slider.setAccessibilityLabel(localized("Minimum battery level"))
        slider.setAccessibilityValueDescription(localizedFormat("%d percent", Int(threshold)))
        slider.toolTip = localized("battery.threshold.scale.help")
        slider.setAccessibilityHelp(slider.toolTip)
        let description = self.charge.map { localizedFormat("Current charge: %d%%", $0) }
            ?? localized("Current charge: unavailable")
        chargeLabel.stringValue = self.charge.map { "\($0)%" } ?? "—"
        chargeLabel.setAccessibilityLabel(description)
        chargeLabel.toolTip = description
        chargeLabel.textColor = chargeColor
        needsLayout = true; needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard let cell = slider.cell as? NSSliderCell else { return }
        // Measure the system knob at both ends before shortening the slider.
        // Keeping its native end insets makes both scales share exact positions.
        slider.frame = NSRect(x: 0, y: 19, width: bounds.width, height: 24)
        let value = slider.doubleValue
        slider.doubleValue = slider.minValue
        let left = cell.knobRect(flipped: false).midX
        slider.doubleValue = slider.maxValue
        let right = cell.knobRect(flipped: false).midX
        slider.doubleValue = value
        let bar = slider.convert(cell.barRect(flipped: false), to: self)
        trackRect = NSRect(x: left, y: bar.midY - 2, width: max(0, right - left), height: 4)
        slider.frame.origin.x = trackRect.width * CGFloat(slider.minValue - 1) / 99
        slider.frame.size.width = left + trackRect.width * CGFloat(slider.maxValue - slider.minValue) / 99 + (bounds.width - right)
        lowerLabel.sizeToFit(); upperLabel.sizeToFit(); chargeLabel.sizeToFit()
        lowerLabel.frame.origin = NSPoint(x: 0, y: 0)
        upperLabel.frame.origin = NSPoint(x: bounds.width - upperLabel.frame.width, y: 0)
        let anchor = charge.map { position(for: Double($0)) } ?? bounds.midX
        let minimum = lowerLabel.frame.maxX + 8
        let maximum = upperLabel.frame.minX - 8 - chargeLabel.frame.width
        chargeLabel.frame.origin = NSPoint(x: min(maximum, max(minimum, anchor - chargeLabel.frame.width / 2)), y: 0)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()
        if let charge {
            chargeColor.setFill()
            let fill = NSRect(x: trackRect.minX, y: trackRect.minY,
                              width: position(for: Double(charge)) - trackRect.minX, height: trackRect.height)
            NSBezierPath(roundedRect: fill, xRadius: 2, yRadius: 2).fill()
            // A small marker distinguishes actual charge from the white cutoff thumb.
            NSBezierPath(ovalIn: NSRect(x: position(for: Double(charge)) - 3, y: trackRect.midY - 3, width: 6, height: 6)).fill()
        }
        NSColor.tertiaryLabelColor.setStroke()
        let limits = NSBezierPath()
        for endpoint in [slider.minValue, slider.maxValue] {
            let x = position(for: endpoint)
            limits.move(to: NSPoint(x: x, y: trackRect.minY - 4))
            limits.line(to: NSPoint(x: x, y: trackRect.minY - 1))
        }
        limits.lineWidth = 1; limits.stroke()
    }

    private var chargeColor: NSColor {
        slider.isEnabled && charge != nil ? AppStyle.Color.accent : .secondaryLabelColor
    }

    private func position(for percent: Double) -> CGFloat {
        trackRect.minX + trackRect.width * CGFloat(min(100, max(1, percent)) - 1) / 99
    }

    @objc private func changeThreshold(_ sender: NSSlider) {
        guard sender.isEnabled else { return }
        let value = min(slider.maxValue, max(slider.minValue, sender.doubleValue.rounded()))
        sender.doubleValue = value
        sender.setAccessibilityValueDescription(localizedFormat("%d percent", Int(value)))
        onChange(value)
    }
}

private final class BatteryThresholdCell: NSSliderCell {
    override func drawBar(inside rect: NSRect, flipped: Bool) {}
    override func drawTickMarks() {}
}
