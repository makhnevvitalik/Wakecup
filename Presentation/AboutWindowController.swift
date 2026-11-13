import AppKit
import Combine
import SwiftUI

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var licenseWindow: NSWindow?
    private let updates = UpdateChecker()
    private var languageObserver: AnyCancellable?
    private var updateObserver: AnyCancellable?
    private var versionLabel: NSTextField?
    private var taglineLabel: NSTextField?
    private var licensesButton: NSButton?
    private var updateButton: NSButton?
    private var updateProgressIndicator: NSProgressIndicator?
    private var updateStatusLabel: NSTextField?

    override init() {
        super.init()
        languageObserver = AppLocalization.shared.$language.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPresentation() }
        }
        updateObserver = updates.$state.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPresentation() }
        }
    }

    func show() {
        if window == nil { window = makeAboutWindow() }
        refreshPresentation()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let closed = notification.object as? NSWindow, closed === window { updates.cancel() }
    }

    private func refreshPresentation() {
        window?.title = localized("About Wakecup")
        licenseWindow?.title = localized("Wakecup License")
        versionLabel?.stringValue = versionText
        taglineLabel?.stringValue = localized("AI works. Your Mac stays wide awake.")
        licensesButton?.title = localized("License…")
        updateButton?.title = updateButtonTitle
        updateButton?.isEnabled = updates.state != .checking
        updateStatusLabel?.stringValue = statusText
        updateStatusLabel?.toolTip = statusText.isEmpty ? nil : statusText
        updateStatusLabel?.textColor = statusColor
        updateProgressIndicator?.isHidden = updates.state != .checking
        if updates.state == .checking { updateProgressIndicator?.startAnimation(nil) }
        else { updateProgressIndicator?.stopAnimation(nil) }
    }

    @objc private func openGitHub() {
        window?.close()
        NSWorkspace.shared.open(UpdateChecker.repositoryURL)
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
        let windowWidth = AppStyle.AboutLayout.width
        let windowHeight = AppStyle.AboutLayout.height
        let windowContent = NSView()

        let iconView = NSImageView()
        iconView.image = WakecupBrand.appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: AppStyle.AboutLayout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: AppStyle.AboutLayout.iconSize)
        ])

        let nameLabel = NSTextField(labelWithString: "Wakecup")
        nameLabel.font = AppStyle.Font.appName

        let versionLabel = NSTextField(labelWithString: versionText)
        self.versionLabel = versionLabel
        versionLabel.font = AppStyle.Font.supportingText
        versionLabel.textColor = .secondaryLabelColor

        let copyrightLabel = NSTextField(labelWithString: copyrightText)
        copyrightLabel.font = AppStyle.Font.metadata
        copyrightLabel.textColor = .secondaryLabelColor

        let taglineLabel = NSTextField(
            wrappingLabelWithString: localized("AI works. Your Mac stays wide awake.")
        )
        self.taglineLabel = taglineLabel
        taglineLabel.isSelectable = false
        taglineLabel.font = AppStyle.Font.body
        taglineLabel.textColor = .secondaryLabelColor
        taglineLabel.maximumNumberOfLines = 3

        let updateButton = NSButton(
            title: localized("Check for Updates"),
            target: self,
            action: #selector(updateButtonPressed)
        )
        updateButton.bezelStyle = .rounded
        updateButton.font = AppStyle.Font.body
        updateButton.keyEquivalent = "\r"
        updateButton.widthAnchor.constraint(equalToConstant: AppStyle.AboutLayout.updateButtonWidth).isActive = true
        self.updateButton = updateButton

        let gitHubButton = NSButton(title: "GitHub ↗", target: self, action: #selector(openGitHub))
        gitHubButton.isBordered = false
        gitHubButton.contentTintColor = .linkColor
        gitHubButton.font = AppStyle.Font.secondaryAction
        gitHubButton.focusRingType = .none

        let licensesButton = NSButton(
            title: localized("License…"),
            target: self,
            action: #selector(showLicenses)
        )
        self.licensesButton = licensesButton
        licensesButton.isBordered = false
        licensesButton.contentTintColor = .linkColor
        licensesButton.font = AppStyle.Font.secondaryAction
        licensesButton.focusRingType = .none

        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true
        self.updateProgressIndicator = progressIndicator

        let actionStack = NSStackView(views: [updateButton, progressIndicator, gitHubButton])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = AppStyle.AboutLayout.actionSpacing
        actionStack.detachesHiddenViews = true

        let statusLabel = NSTextField(wrappingLabelWithString: "")
        statusLabel.isSelectable = false
        statusLabel.identifier = NSUserInterfaceItemIdentifier("WakecupUpdateStatus")
        statusLabel.font = AppStyle.Font.statusText
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.heightAnchor.constraint(equalToConstant: AppStyle.AboutLayout.statusHeight).isActive = true
        statusLabel.widthAnchor.constraint(equalToConstant: windowWidth - AppStyle.Layout.windowInset * 2).isActive = true
        self.updateStatusLabel = statusLabel

        let identity = NSStackView(views: [nameLabel, versionLabel])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2
        let header = NSStackView(views: [iconView, identity])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = AppStyle.AboutLayout.headerSpacing

        // Borderless buttons have a small inset around the title; align its ink.
        let licenseLink = NSView()
        licensesButton.translatesAutoresizingMaskIntoConstraints = false
        licenseLink.addSubview(licensesButton)
        NSLayoutConstraint.activate([
            licensesButton.leadingAnchor.constraint(equalTo: licenseLink.leadingAnchor, constant: -2),
            licensesButton.trailingAnchor.constraint(equalTo: licenseLink.trailingAnchor),
            licensesButton.topAnchor.constraint(equalTo: licenseLink.topAnchor),
            licensesButton.bottomAnchor.constraint(equalTo: licenseLink.bottomAnchor)
        ])
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [licenseLink, footerSpacer, copyrightLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8

        let contentStack = NSStackView(views: [header, taglineLabel, actionStack, statusLabel, footer])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = AppStyle.AboutLayout.contentSpacing
        contentStack.setCustomSpacing(12, after: taglineLabel)
        contentStack.setCustomSpacing(4, after: actionStack)
        contentStack.setCustomSpacing(AppStyle.AboutLayout.statusFooterSpacing, after: statusLabel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor, constant: AppStyle.Layout.windowInset),
            contentStack.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor, constant: -AppStyle.Layout.windowInset),
            contentStack.topAnchor.constraint(equalTo: windowContent.topAnchor, constant: AppStyle.Layout.windowTopInset),
            taglineLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: windowContent.bottomAnchor, constant: -AppStyle.AboutLayout.bottomInset)
        ])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = localized("About Wakecup")
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = windowContent
        window.center()

        return window
    }

    private var copyrightText: String {
        (Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String ?? "© 2026 Vitalik Makhnev")
            .replacingOccurrences(of: "Copyright ", with: "")
    }

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? localized("Unknown version")
        return localizedFormat("Version %@", version)
    }

    private var updateButtonTitle: String {
        switch updates.state {
        case .checking: return localized("Checking…")
        case .finished(.updateAvailable): return localized("View Release")
        case .finished(.failure): return localized("Try Again")
        default: return localized("Check for Updates")
        }
    }

    @objc private func updateButtonPressed() {
        if case let .finished(.updateAvailable(_, url)) = updates.state {
            NSWorkspace.shared.open(url)
        } else {
            updates.check()
        }
    }

    private var statusText: String {
        switch updates.state {
        case .idle: return ""
        case .checking: return localized("Checking GitHub for updates…")
        case .finished(.upToDate): return localized("You’re up to date.")
        case let .finished(.updateAvailable(tag, _)): return localizedFormat("%@ is available.", tag)
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
