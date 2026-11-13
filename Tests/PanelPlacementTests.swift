import Foundation
import CoreGraphics

@main
struct PanelPlacementTests {
    static func main() {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 836)
        let icon = CGRect(x: 1300, y: 876, width: 24, height: 24)
        let size = CGSize(width: 380, height: 540)
        let opened = detachedPanelFrame(contentSize: size, screenFrame: screen, visibleFrame: visible, statusItemFrame: icon)
        expect(visible.contains(opened), "initial panel remains within visible screen")
        expect(opened.maxY <= icon.minY - 8, "visible gap below menu bar icon")
        let hiddenIcon = CGRect(x: -9000, y: 876, width: 24, height: 24)
        let collapsed = detachedPanelFrame(contentSize: size, screenFrame: screen, visibleFrame: visible, statusItemFrame: hiddenIcon, previousFrame: opened)
        expect(collapsed == opened, "collapsing icon cannot move already open panel")
        let expanded = detachedPanelFrame(contentSize: CGSize(width: 380, height: 650), screenFrame: screen,
            visibleFrame: visible, statusItemFrame: hiddenIcon, previousFrame: opened)
        expect(expanded.maxY == opened.maxY && expanded.minX == opened.minX, "content grows down without moving left or above screen")
        let smaller = detachedPanelFrame(contentSize: CGSize(width: 380, height: 240), screenFrame: screen,
            visibleFrame: visible, statusItemFrame: nil, previousFrame: opened)
        expect(smaller.maxY == opened.maxY && smaller.minX == opened.minX, "active session shrink preserves top and horizontal position")
        let hiddenOpen = detachedPanelFrame(contentSize: size, screenFrame: screen, visibleFrame: visible, statusItemFrame: hiddenIcon)
        expect(visible.contains(hiddenOpen), "opening while icon is hidden uses safe fallback")
        let oversized = detachedPanelFrame(contentSize: CGSize(width: 380, height: 1_000), screenFrame: screen,
            visibleFrame: visible, statusItemFrame: nil, previousFrame: opened)
        expect(visible.contains(oversized) && oversized.maxY == opened.maxY && oversized.minX == opened.minX,
            "a footer that would overflow the screen must keep the top fixed and limit the scroll viewport")
        let leftScreen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftVisible = CGRect(x: -1920, y: 30, width: 1920, height: 1026)
        let leftIcon = CGRect(x: -1850, y: 1056, width: 24, height: 24)
        let left = detachedPanelFrame(contentSize: size, screenFrame: leftScreen, visibleFrame: leftVisible, statusItemFrame: leftIcon)
        expect(leftVisible.contains(left), "secondary screen with negative coordinates")
        let shortVisible = CGRect(x: 0, y: 40, width: 1000, height: 400)
        let short = detachedPanelFrame(contentSize: size, screenFrame: CGRect(x: 0, y: 0, width: 1000, height: 464), visibleFrame: shortVisible, statusItemFrame: nil)
        expect(shortVisible.contains(short), "small screen limits viewport height for scrolling")
        print("Panel placement checks: \(checks), failures: \(failures.count)")
        failures.forEach { print("FAIL: " + $0) }
        exit(failures.isEmpty ? 0 : 1)
    }
}
