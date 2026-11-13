import AppKit

// Original Wakecup artwork. No system symbol is used for the application's mark.
enum WakecupBrand {
    static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "WakecupIcon", withExtension: "png", subdirectory: "Artwork"),
           let image = NSImage(contentsOf: url) { return image }
        return mark(size: NSSize(width: 64, height: 64), filled: true, color: AppStyle.Color.accent)
    }()

    static func mark(size: NSSize, filled: Bool, color: NSColor, emphasizeBoltTips: Bool = false) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let bounds = NSRect(x: 4, y: 1, width: 94, height: 77)
            let scale = min(rect.width / bounds.width, rect.height / bounds.height)
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX - bounds.midX * scale, yBy: rect.midY - bounds.midY * scale)
            transform.scale(by: scale)
            transform.concat()
            color.set()

            let outlineWidth: CGFloat = 7.5
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 72, y: 60))
            handle.line(to: NSPoint(x: 82, y: 60))
            handle.curve(to: NSPoint(x: 94, y: 48), controlPoint1: NSPoint(x: 90, y: 60), controlPoint2: NSPoint(x: 94, y: 56))
            handle.line(to: NSPoint(x: 94, y: 37))
            handle.curve(to: NSPoint(x: 82, y: 25), controlPoint1: NSPoint(x: 94, y: 29), controlPoint2: NSPoint(x: 90, y: 25))
            handle.line(to: NSPoint(x: 69, y: 25))
            handle.lineWidth = outlineWidth
            handle.lineCapStyle = .round
            handle.stroke()

            let body = NSBezierPath()
            body.move(to: NSPoint(x: 12, y: 74))
            body.line(to: NSPoint(x: 70, y: 74))
            body.curve(to: NSPoint(x: 74, y: 70), controlPoint1: NSPoint(x: 73, y: 74), controlPoint2: NSPoint(x: 75, y: 73))
            body.line(to: NSPoint(x: 69, y: 20))
            body.curve(to: NSPoint(x: 54, y: 5), controlPoint1: NSPoint(x: 68, y: 10), controlPoint2: NSPoint(x: 63, y: 5))
            body.line(to: NSPoint(x: 28, y: 5))
            body.curve(to: NSPoint(x: 13, y: 20), controlPoint1: NSPoint(x: 19, y: 5), controlPoint2: NSPoint(x: 14, y: 10))
            body.line(to: NSPoint(x: 8, y: 70))
            body.curve(to: NSPoint(x: 12, y: 74), controlPoint1: NSPoint(x: 7, y: 73), controlPoint2: NSPoint(x: 9, y: 74))
            body.close()
            if filled {
                body.fill()
                let bolt = NSBezierPath()
                // Broad tips retain visible area at menu-bar resolution instead
                // of tapering to subpixel points. The large app mark is unchanged.
                let points: [NSPoint] = emphasizeBoltTips ? [
                    NSPoint(x: 46, y: 58), NSPoint(x: 25.75, y: 36), NSPoint(x: 39.5, y: 36),
                    NSPoint(x: 31, y: 19), NSPoint(x: 35.5, y: 19), NSPoint(x: 58.25, y: 44),
                    NSPoint(x: 44.5, y: 44), NSPoint(x: 50.5, y: 58)
                ] : [
                    NSPoint(x: 47, y: 58), NSPoint(x: 29, y: 36), NSPoint(x: 40, y: 36),
                    NSPoint(x: 35, y: 19), NSPoint(x: 55, y: 44), NSPoint(x: 44, y: 44)
                ]
                bolt.move(to: points[0])
                for point in points.dropFirst() { bolt.line(to: point) }
                bolt.close()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                bolt.fill()
            } else {
                body.lineWidth = outlineWidth
                body.lineJoinStyle = .round
                body.stroke()
            }
            return true
        }
    }
}
