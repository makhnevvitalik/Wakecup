import AppKit
import Combine
import SwiftUI

final class SleepHelpWindowController {
    private var window: NSWindow?
    private var languageObserver: AnyCancellable?

    init() {
        languageObserver = AppLocalization.shared.$language.sink { [weak self] _ in
            DispatchQueue.main.async { self?.window?.title = SleepRecoveryGuide.title }
        }
    }

    func show() {
        if window == nil {
            let helpWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            helpWindow.title = SleepRecoveryGuide.title
            helpWindow.isReleasedWhenClosed = false
            helpWindow.contentViewController = NSHostingController(rootView: SleepHelpView())
            helpWindow.minSize = NSSize(width: 460, height: 380)
            helpWindow.setContentSize(NSSize(width: 540, height: 620))
            helpWindow.center()
            window = helpWindow
        }
        window?.title = SleepRecoveryGuide.title
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SleepHelpView: View {
    @ObservedObject private var localization = AppLocalization.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(SleepRecoveryGuide.title).font(Font(AppStyle.Font.windowTitle))
                Text(SleepRecoveryGuide.introduction).font(Font(AppStyle.Font.body))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(SleepRecoveryGuide.sections.indices, id: \.self) { index in
                    let section = SleepRecoveryGuide.sections[index]
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title).font(Font(AppStyle.Font.sectionTitle))
                        if section.command == SleepRecoveryGuide.resetCommand {
                            Button(localized("Open guide separately"), action: openGuideSeparately)
                                .font(Font(AppStyle.Font.secondaryAction)).buttonStyle(.link)
                        }
                        Text(section.text).font(Font(AppStyle.Font.body)).fixedSize(horizontal: false, vertical: true)
                        if let command = section.command {
                            HStack(alignment: .top, spacing: 10) {
                                Text(command).font(Font(AppStyle.Font.monospacedBody))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button(localized("Copy")) {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(command, forType: .string)
                                }.accessibilityLabel(localizedFormat("Copy: %@", command))
                            }
                            .padding(10).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.textSelection(.enabled).padding(.horizontal, AppStyle.Layout.windowInset).padding(.vertical, AppStyle.Layout.windowTopInset)
        }.frame(minWidth: 460, minHeight: 340)
    }

    private func openGuideSeparately() {
        do {
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("Wakecup-RecoveryGuide-\(UUID().uuidString).txt")
            try SleepRecoveryGuide.plainText(language: localization.language)
                .write(to: copy, atomically: true, encoding: .utf8)
            if !NSWorkspace.shared.open(copy) {
                try? FileManager.default.removeItem(at: copy)
                showGuideError()
            }
        } catch { showGuideError() }
    }

    private func showGuideError() {
        let alert = NSAlert()
        alert.messageText = localized("Could not open the guide separately.")
        alert.informativeText = localized("Select and copy the guide text before quitting Wakecup.")
        alert.runModal()
    }
}
