import AppKit

enum StatusIconNotice {
    case restoreBrightness, restoreSleep, updateHelper, updateApp, none

    init(needsBrightnessRecovery: Bool, needsSleepRecovery: Bool, helperNeedsUpdate: Bool, hasAppUpdate: Bool) {
        if needsBrightnessRecovery { self = .restoreBrightness }
        else if needsSleepRecovery { self = .restoreSleep }
        else if helperNeedsUpdate { self = .updateHelper }
        else if hasAppUpdate { self = .updateApp }
        else { self = .none }
    }

    var titleKey: String {
        switch self {
        case .restoreBrightness: "Wakecup — restore brightness"
        case .restoreSleep: "Wakecup — restore normal sleep"
        case .updateHelper: "Wakecup — helper update required"
        case .updateApp: "Wakecup — update available"
        case .none: "Wakecup"
        }
    }
}

enum StatusIconState: CaseIterable {
    case inactive, active, attention, inactiveWithAttention, inactiveWithUpdate, activeWithUpdate

    init(phase: AppSessionPhase, notice: StatusIconNotice) {
        let active = phase == .active || phase == .stopping
        switch notice {
        case .restoreBrightness, .restoreSleep: self = .attention
        case .updateHelper: self = active ? .attention : .inactiveWithAttention
        case .updateApp: self = active ? .activeWithUpdate : .inactiveWithUpdate
        case .none: self = active ? .active : .inactive
        }
    }

    var badgeColor: NSColor? {
        switch self {
        case .attention, .inactiveWithAttention: .systemOrange
        case .inactiveWithUpdate, .activeWithUpdate: .systemBlue
        case .inactive, .active: nil
        }
    }
}

func makeStatusIcon(state: StatusIconState) -> NSImage {
    let glyphSize = AppStyle.Icon.menuBarCupSize
    let filled = state == .active || state == .attention || state == .activeWithUpdate
    let glyph = WakecupBrand.mark(size: glyphSize, filled: filled, color: .black, emphasizeBoltTips: true)
    let showsBadge = state.badgeColor != nil
    let image = NSImage(size: AppStyle.Icon.menuBarSize, flipped: false) { rect in
        glyph.draw(in: NSRect(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2,
                              width: glyphSize.width, height: glyphSize.height))
        if showsBadge {
            // Leave space in the template for the separate colored badge.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setFill()
            NSBezierPath(ovalIn: statusBadgeRect(in: rect).insetBy(dx: -0.8, dy: -0.8)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Wakecup"
    return image
}

private func statusBadgeRect(in imageRect: NSRect) -> NSRect {
    let side = AppStyle.Icon.menuBarBadgeDiameter
    return NSRect(x: imageRect.maxX - side, y: imageRect.maxY - side, width: side, height: side)
}

// Overlay the image rect so a countdown can extend the button without moving the badge off the cup.
final class StatusBadge: NSView {
    var color: NSColor? {
        didSet {
            isHidden = color == nil
            needsDisplay = true
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let color, let button = superview as? NSButton, let cell = button.cell,
              button.image != nil else { return }
        let imageRect = convert(cell.imageRect(forBounds: button.bounds), from: button)
        color.setFill()
        NSBezierPath(ovalIn: statusBadgeRect(in: imageRect)).fill()
    }
}
