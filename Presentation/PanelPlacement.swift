import Foundation
import CoreGraphics

func detachedPanelFrame(contentSize: CGSize, screenFrame: CGRect, visibleFrame: CGRect,
                        statusItemFrame: CGRect?, previousFrame: CGRect? = nil) -> CGRect {
    let safe = visibleFrame.insetBy(dx: 8, dy: 8)
    let width = min(max(1, contentSize.width), max(1, safe.width))
    let anchor = statusItemFrame.flatMap { rect -> CGRect? in
        guard rect.width > 0, rect.height > 0, screenFrame.intersects(rect),
              rect.maxY >= visibleFrame.maxY - 64 else { return nil }
        return rect
    }
    let desiredX = previousFrame?.minX ?? anchor.map { $0.midX - width / 2 } ?? (safe.maxX - width)
    let desiredTop = previousFrame?.maxY ?? anchor.map { $0.minY - 8 } ?? safe.maxY
    let x = min(max(desiredX, safe.minX), safe.maxX - width)
    // Keep the anchor fixed and shorten the scroll viewport if the panel grows.
    let top = min(max(desiredTop, safe.minY + 1), safe.maxY)
    let height = min(max(1, contentSize.height), top - safe.minY)
    return CGRect(x: x, y: top - height, width: width, height: height)
}
