import AppKit

@main
struct StatusIconTests {
    static func main() throws {
        var failures: [String] = []
        var inactivePixels = 0
        var activePixels = 0
        if StatusIconState(phase: .failed, needsRecovery: true) != .attention {
            failures.append("failed restoration must keep an attention state")
        }
        if StatusIconState(phase: .authorizing, needsRecovery: true) != .attention {
            failures.append("attention must remain while recovery is in progress")
        }
        if StatusIconState(phase: .idle, needsRecovery: false) != .inactive {
            failures.append("confirmed restoration returns the ordinary inactive state")
        }
        if StatusIconState(phase: .stopping, needsRecovery: false) != .active {
            failures.append("stopping must not look inactive before restoration finishes")
        }
        for state in [StatusIconState.inactive, .active, .attention] {
            guard let image = makeStatusIcon(state: state),
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot render test icon") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 80))
            NSGraphicsContext.restoreGraphicsState()
            var opaque = 0
            var clear = 0
            var wrongColor = 0
            var warningPixels = 0
            var minX = 80, minY = 80, maxX = -1, maxY = -1
            for x in 0..<80 {
                for y in 0..<80 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    if color.alphaComponent < 0.01 { clear += 1 }
                    if color.alphaComponent > 0.1 {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                    if color.alphaComponent > 0.95 {
                        opaque += 1
                        let values = [color.redComponent, color.greenComponent, color.blueComponent]
                        let orange = color.redComponent > 0.8 && color.greenComponent > 0.2
                            && color.greenComponent < 0.8 && color.blueComponent < 0.2
                        if orange { warningPixels += 1 }
                        let warmBadgeColor = color.redComponent > 0.98 && color.greenComponent > color.blueComponent + 0.005
                        if state == .attention ? (values.min()! < 0.98 && !warmBadgeColor) : values.max()! > 0.02 {
                            wrongColor += 1
                        }
                    }
                }
            }
            if image.size != NSSize(width: 18, height: 18) || maxX - minX + 1 < 72
                || !(51...72).contains(maxY - minY + 1) {
                failures.append("the icon must fill the shared canvas within its allowed glyph height")
            }
            if state == .inactive { inactivePixels = opaque }
            if state == .active { activePixels = opaque }
            if image.isTemplate != (state != .attention) {
                failures.append("only the colored recovery badge should require a non-template image")
            }
            if opaque == 0 || clear == 0 { failures.append("icon must contain glyph and transparent background") }
            if wrongColor > 0 { failures.append("unexpected glyph color for \(state)") }
            if state == .attention && warningPixels == 0 { failures.append("attention icon needs a visible orange badge") }
            if state != .attention && warningPixels != 0 { failures.append("ordinary icons must not show a warning badge") }
        }
        if activePixels <= inactivePixels { failures.append("active cup must be filled; inactive cup must remain outlined") }
        print("Status icon rendering checks: \(failures.isEmpty ? "PASS" : "FAIL")")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
