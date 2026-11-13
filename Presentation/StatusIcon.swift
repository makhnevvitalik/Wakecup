import AppKit

enum StatusIconState: Equatable {
    case inactive, active, attention

    init(phase: AppSessionPhase, needsRecovery: Bool) {
        if needsRecovery { self = .attention }
        else if phase == .active || phase == .stopping { self = .active }
        else { self = .inactive }
    }
}

func makeStatusIcon(active: Bool) -> NSImage? {
    makeStatusIcon(state: active ? .active : .inactive)
}

func makeStatusIcon(state: StatusIconState) -> NSImage? {
    let glyph = WakecupBrand.mark(size: AppStyle.Icon.menuBarSize,
                                 filled: state != .inactive, color: AppStyle.Color.menuBarForeground, emphasizeBoltTips: true)
    let image = NSImage(size: AppStyle.Icon.menuBarSize, flipped: false) { rect in
        glyph.draw(in: rect)
        if state == .attention {
            let side = AppStyle.Icon.recoveryBadgeDiameter
            let badge = NSRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
            AppStyle.Color.recoveryBadge.setFill()
            NSBezierPath(ovalIn: badge).fill()
            let mark = NSAttributedString(string: "!", attributes: [
                .font: AppStyle.Font.warningBadge, .foregroundColor: NSColor.white
            ])
            let size = mark.size()
            mark.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
        }
        return true
    }
    image.isTemplate = false
    image.accessibilityDescription = "Wakecup"
    return image
}
