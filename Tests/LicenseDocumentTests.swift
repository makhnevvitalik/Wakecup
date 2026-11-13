import AppKit
import SwiftUI

// Offscreen reader tests: no SessionModel, helper, system preferences or real windows.
@main struct LicenseDocumentTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n",stderr); exit(1) }
    }
    @MainActor static func run() throws {
        let language = CommandLine.arguments[2]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey:language],forName:UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let source = try String(contentsOfFile:CommandLine.arguments[1]+"/LICENSE",encoding:.utf8)
        let original = Data(source.utf8)
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentViewController = NSHostingController(rootView:LicenseDocumentView(text:source))
        defer { window.orderOut(nil) }
        for width:CGFloat in [450,600,850] {
            window.setContentSize(NSSize(width:width,height:330))
            window.contentView!.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.08))
            guard let text = descendants(window.contentView!).compactMap({$0 as? NSTextView}).first else {
                throw NSError(domain:"License reader must expose selectable native document text",code:1)
            }
            try expect(text.font?.pointSize == 13,"License text must use the same readable 13-point scale as Lang Switcher")
            try expect(!text.isEditable && text.isSelectable,"Document must be selectable and read-only")
            let canonical:(String)->String = { $0.components(separatedBy:.whitespacesAndNewlines).joined() }
            try expect(canonical(text.string)==canonical(source),"License wording, punctuation or ordering changed")
            try expect(text.string.contains("IN NO EVENT SHALL THE AUTHORS"),"MIT disclaimer still contains source wrapping")
            try expect(text.string.contains("ARISING FROM, OUT OF OR"),"MIT disclaimer still contains a hard line break")
            let container=text.textContainer!, layout=text.layoutManager!
            layout.ensureLayout(for:container)
            let glyphs=layout.glyphRange(for:container)
            try expect(glyphs.length==layout.numberOfGlyphs,"Some document glyphs were not laid out")
            var clipped=false
            layout.enumerateLineFragments(forGlyphRange:glyphs) { _,used,_,_,_ in
                if used.minX < -1 || used.maxX > container.containerSize.width+1 { clipped=true }
            }
            try expect(!clipped,"Document text exceeds the reader width")
            text.scrollToEndOfDocument(nil)
            try expect(layout.usedRect(for:container).maxY+text.textContainerOrigin.y <= text.visibleRect.maxY+2,"License ending is not reachable by scrolling")
            text.scrollToBeginningOfDocument(nil)
            let view=window.contentView!;view.wantsLayer=true;view.layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
            view.displayIfNeeded()
            if let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                view.cacheDisplay(in:view.bounds,to:bitmap)
                try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:"/private/tmp/wakecup-license-\(language)-\(Int(width)).png"))
            }
        }
        try expect(try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]+"/LICENSE")) == original,"License source file changed")
        print("PASS: \(language) Wakecup license, all wording preserved, 13-point text, reflow and scrolling at three widths")
    }
    static func descendants(_ v:NSView)->[NSView] { [v]+v.subviews.flatMap(descendants) }
    static func expect(_ condition:Bool,_ message:String) throws {
        if !condition { throw NSError(domain:message,code:1) }
    }
}
