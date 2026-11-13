import AppKit
import SwiftUI

// Read-only document viewer: body typography, paragraph reflow and native selection.
// Formatting affects only the display; the bundled license remains unchanged.
@MainActor
struct LicenseDocumentView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let document = NSTextView()
        document.isEditable = false
        document.isSelectable = true
        document.drawsBackground = false
        document.font = AppStyle.Font.body
        document.textContainerInset = NSSize(width: 10, height: 10)
        document.isVerticallyResizable = true
        document.isHorizontallyResizable = false
        document.autoresizingMask = [.width]
        document.textContainer?.widthTracksTextView = true
        document.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        document.setAccessibilityLabel(localized("Wakecup License"))
        document.identifier = NSUserInterfaceItemIdentifier("WakecupLicenseDocument")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = document
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let document = scroll.documentView as? NSTextView else { return }
        document.setAccessibilityLabel(localized("Wakecup License"))
        let rendered = LicenseDocumentRenderer.render(text)
        // Localization can refresh the surrounding window while the same English
        // legal document stays open. Preserve selection and scroll position then.
        guard document.string != rendered.string else { return }
        document.textStorage?.setAttributedString(rendered)
        document.scrollToBeginningOfDocument(nil)
    }
}
