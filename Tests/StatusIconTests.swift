import AppKit

@main
struct StatusIconTests {
    static func main() throws {
        var failures: [String] = []
        var inactivePixels = 0
        var activePixels = 0
        if StatusIconState(phase: .failed, notice: .restoreSleep) != .attention {
            failures.append("failed restoration must keep an attention state")
        }
        if StatusIconState(phase: .authorizing, notice: .restoreBrightness) != .attention {
            failures.append("attention must remain while recovery is in progress")
        }
        if StatusIconState(phase: .idle, notice: .none) != .inactive {
            failures.append("confirmed restoration returns the ordinary inactive state")
        }
        if StatusIconState(phase: .stopping, notice: .none) != .active {
            failures.append("stopping must not look inactive before restoration finishes")
        }
        if StatusIconState(phase: .idle, notice: .updateApp) != .inactiveWithUpdate
            || StatusIconState(phase: .active, notice: .updateApp) != .activeWithUpdate {
            failures.append("An update keeps the cup's inactive or active state")
        }
        if StatusIconNotice(needsBrightnessRecovery: true, needsSleepRecovery: true, helperNeedsUpdate: true, hasAppUpdate: true) != .restoreBrightness
            || StatusIconNotice(needsBrightnessRecovery: false, needsSleepRecovery: true, helperNeedsUpdate: true, hasAppUpdate: true) != .restoreSleep {
            failures.append("Recovery must take priority over both updates")
        }
        let helperNotice = StatusIconNotice(needsBrightnessRecovery: false, needsSleepRecovery: false, helperNeedsUpdate: true, hasAppUpdate: true)
        if helperNotice != .updateHelper
            || StatusIconState(phase: .idle, notice: helperNotice) != .inactiveWithAttention
            || StatusIconState(phase: .active, notice: helperNotice) != .attention {
            failures.append("A helper update must take priority over an app update and preserve the cup's fill")
        }
        if StatusIconNotice(needsBrightnessRecovery: false, needsSleepRecovery: false, helperNeedsUpdate: false, hasAppUpdate: true) != .updateApp {
            failures.append("An app update must become visible when the helper stops needing an update")
        }
        let filledWithBadge = render(makeStatusIcon(state: .activeWithUpdate), appearance: .aqua)
        let outlinedWithBadge = render(makeStatusIcon(state: .inactiveWithUpdate), appearance: .aqua)
        for state in StatusIconState.allCases {
            let expectedColor: NSColor? = switch state {
            case .attention, .inactiveWithAttention: .systemOrange
            case .inactiveWithUpdate, .activeWithUpdate: .systemBlue
            case .inactive, .active: nil
            }
            if state.badgeColor != expectedColor { failures.append("Unexpected status badge color for \(state)") }
            let image = makeStatusIcon(state: state)
            let bitmap = render(image, appearance: .aqua)
            var opaque = 0
            var clear = 0
            var wrongColor = 0
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
                        if max(color.redComponent, color.greenComponent, color.blueComponent) > 0.02 {
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
            if !image.isTemplate { failures.append("Every cup state must use a system template") }
            if opaque == 0 || clear == 0 { failures.append("icon must contain glyph and transparent background") }
            if wrongColor > 0 { failures.append("The template must contain only the cup for \(state)") }
            if state == .attention && bitmap.tiffRepresentation != filledWithBadge.tiffRepresentation {
                failures.append("Orange and blue badges must share the same space on a filled cup")
            }
            if state == .inactiveWithAttention && bitmap.tiffRepresentation != outlinedWithBadge.tiffRepresentation {
                failures.append("Orange and blue badges must share the same space on an outlined cup")
            }
        }
        if activePixels <= inactivePixels { failures.append("active cup must be filled; inactive cup must remain outlined") }
        print("Status icon rendering checks: \(failures.isEmpty ? "PASS" : "FAIL")")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }

    static func render(_ image: NSImage, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 80,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap),
              let appearance = NSAppearance(named: appearance) else { fatalError("Cannot render test icon") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(in: NSRect(x: 0, y: 0, width: 80, height: 80))
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
}
