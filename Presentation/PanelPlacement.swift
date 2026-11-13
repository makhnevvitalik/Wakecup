import Foundation
import CoreGraphics

func detachedPanelFrame(contentSize: CGSize, screenFrame: CGRect, visibleFrame: CGRect,
                        statusItemFrame: CGRect?, previousFrame: CGRect? = nil) -> CGRect {
    let safe = visibleFrame.insetBy(dx: 8, dy: 8)
    let width = min(max(1, contentSize.width), max(1, safe.width))
    // When the panel already fits, let the content scroll before moving its top.
    let availableHeight = previousFrame.flatMap { safe.contains($0) ? $0.maxY - safe.minY : nil } ?? safe.height
    let height = min(max(1, contentSize.height), max(1, availableHeight))
    let anchor = statusItemFrame.flatMap { rect -> CGRect? in
        guard rect.width > 0, rect.height > 0, screenFrame.intersects(rect),
              rect.maxY >= visibleFrame.maxY - 64 else { return nil }
        return rect
    }
    let desiredX = previousFrame?.minX ?? anchor.map { $0.midX - width / 2 } ?? (safe.maxX - width)
    let desiredTop = previousFrame?.maxY ?? anchor.map { $0.minY - 8 } ?? safe.maxY
    let x = min(max(desiredX, safe.minX), safe.maxX - width)
    let top = min(max(desiredTop, safe.minY + height), safe.maxY)
    return CGRect(x: x, y: top - height, width: width, height: height)
}
