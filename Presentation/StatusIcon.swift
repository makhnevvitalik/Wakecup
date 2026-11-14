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
    let glyphSize = AppStyle.Icon.menuBarCupSize
    let glyph = WakecupBrand.mark(size: glyphSize, filled: state != .inactive,
                                 color: state == .attention ? .white : .black, emphasizeBoltTips: true)
    let image = NSImage(size: AppStyle.Icon.menuBarSize, flipped: false) { rect in
        glyph.draw(in: NSRect(x: rect.midX - glyphSize.width / 2, y: rect.midY - glyphSize.height / 2,
                              width: glyphSize.width, height: glyphSize.height))
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
    image.isTemplate = state != .attention
    image.accessibilityDescription = "Wakecup"
    return image
}
