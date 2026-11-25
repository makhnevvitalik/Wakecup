import AppKit
import Combine
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var returnToSource: (() -> Void)?
    private var licenseWindow: NSWindow?
    private let updates: UpdateChecker
    private let openURL: (URL) -> Void
    private var languageObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private var taglineLabel: NSTextField?
    private var licensesButton: NSButton?
    private var updateButton: NSButton?
    private var releaseButton: NSButton?
    private var updateProgressIndicator: NSProgressIndicator?
    private var updateStatusLabel: NSTextField?
    private weak var contentStack: NSStackView?

    init(updates: UpdateChecker, openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.updates = updates
        self.openURL = openURL
        super.init()
        languageObserver = AppLocalization.shared.$language.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPresentation() }
        }
        updateObserver = self.updates.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPresentation() }
        }
    }

    func show(returningTo source: (() -> Void)? = nil) {
        if window == nil { window = makeAboutWindow() }
        if let source { returnToSource = source }
        refreshPresentation()
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            AppStyle.showWithoutInitialControlFocus(window)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let returnToSource else { return }
        self.returnToSource = nil
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible == false else { return }
            returnToSource()
        }
    }

    private func refreshPresentation() {
        window?.title = localized("About Wakecup")
        licenseWindow?.title = localized("Wakecup License")
        taglineLabel?.stringValue = localized("AI works. Your Mac stays wide awake.")
        licensesButton?.title = localized("License…")
        updateButton?.title = updateButtonTitle
        updateButton?.isEnabled = updates.state != .checking
        let release = updates.availableRelease
        let releaseTitle = release.map { localizedFormat("%@ is available", $0.tag) }
        releaseButton?.title = releaseTitle.map { $0 + " ↗" } ?? ""
        releaseButton?.toolTip = releaseTitle
        releaseButton?.setAccessibilityLabel(releaseTitle)
        releaseButton?.setAccessibilityHelp(localized("View Release"))
        releaseButton?.isHidden = release == nil
        // When a release is known, the button and spinner already show the progress.
        let status = updates.state == .checking && release != nil ? "" : statusText
        updateStatusLabel?.stringValue = status
        updateStatusLabel?.toolTip = status.isEmpty ? nil : status
        updateStatusLabel?.textColor = statusColor
        updateStatusLabel?.isHidden = release != nil && status.isEmpty
        updateProgressIndicator?.isHidden = updates.state != .checking
        if updates.state == .checking { updateProgressIndicator?.startAnimation(nil) }
        else { updateProgressIndicator?.stopAnimation(nil) }
        if let window, let contentStack {
            AppStyle.sizeAboutWindow(window, to: contentStack)
        }
    }

    @objc private func openGitHub() {
        returnToSource = nil
        window?.close()
        openURL(UpdateChecker.repositoryURL)
    }

    @objc private func openRelease() {
        guard let release = updates.availableRelease else { return }
        openURL(release.url)
    }

    @objc private func showLicenses() {
        if licenseWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 540),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = localized("Wakecup License")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 380)
            window.contentViewController = NSHostingController(rootView: LicensesView())
            window.center()
            licenseWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        licenseWindow?.makeKeyAndOrderFront(nil)
    }

    private func makeAboutWindow() -> NSWindow {
        let updateButton = NSButton(title: localized("Check for Updates"), target: self,
                                    action: #selector(updateButtonPressed))
        let licensesButton = NSButton(title: localized("License…"), target: self, action: #selector(showLicenses))
        let releaseButton = NSButton(title: "", target: self, action: #selector(openRelease))
        let content = AboutContent(name: "Wakecup", icon: WakecupBrand.appIcon,
            tagline: localized("AI works. Your Mac stays wide awake."),
            copyright: copyrightText, updateButton: updateButton, releaseButton: releaseButton,
            gitHubButton: NSButton(title: "GitHub ↗", target: self, action: #selector(openGitHub)),
            licensesButton: licensesButton, statusIdentifier: "WakecupUpdateStatus")
        self.releaseButton = releaseButton
        self.updateButton = updateButton
        updateProgressIndicator = content.progressIndicator
        updateStatusLabel = content.statusLabel
        contentStack = content.contentStack
        taglineLabel = content.taglineLabel
        self.licensesButton = licensesButton

        let window = AppStyle.InformationWindow(
            contentRect: NSRect(x: 0, y: 0, width: AppStyle.AboutLayout.width, height: 1),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("About Wakecup")
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = content.view
        window.delegate = self
        AppStyle.sizeAboutWindow(window, to: content.contentStack)
        window.center()

        return window
    }

    private var copyrightText: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Vitalik Makhnev")
            .replacingOccurrences(of: "Copyright ", with: "")
    }

    private var updateButtonTitle: String {
        localized(updates.state == .checking ? "Checking…" : "Check for Updates")
    }

    @objc private func updateButtonPressed() {
        updates.check()
    }

    private var statusText: String {
        switch updates.state {
        case .idle: return ""
        case .checking: return localized("Checking GitHub for updates…")
        case .finished(.upToDate): return localized("You’re up to date.")
        case .finished(.updateAvailable): return ""
        case .finished(.notPublished): return localized("The repository or a public release has not been published yet.")
        case let .finished(.failure(failure)):
            switch failure {
            case .network: return localized("Could not contact GitHub. Please try again.")
            case .invalidResponse: return localized("GitHub returned an invalid response.")
            case .invalidRelease: return localized("GitHub returned invalid update information.")
            case .currentVersion: return localized("Could not determine the installed app version.")
            case .rateLimited: return localized("GitHub’s request limit was reached. Please try again later.")
            case let .http(code): return localizedFormat("GitHub returned HTTP %d.", code)
            }
        }
    }

    private var statusColor: NSColor {
        switch updates.state {
        case .finished(.failure): return .systemRed
        case .finished(.upToDate): return AppStyle.Color.success
        default: return .secondaryLabelColor
        }
    }
}

private struct LicensesView: View {
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized("Wakecup License")).font(Font(AppStyle.Font.windowTitle))
            Text(localized("Wakecup is licensed under the MIT License with the Commons Clause condition."))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LicenseDocumentView(text: documentText)
        }.font(Font(AppStyle.Font.body))
            .padding(.horizontal, AppStyle.Layout.windowInset).padding(.vertical, AppStyle.Layout.windowTopInset)
            .frame(minWidth: 470, minHeight: 330)
    }

    private var documentText: String {
        guard let url = Bundle.main.url(forResource: "LICENSE", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return localized("The license document is unavailable.")
        }
        return text
    }
}
