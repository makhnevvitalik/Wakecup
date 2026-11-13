import AppKit
import Combine
import SwiftUI

@MainActor
final class MCPSetupWindowController {
    private var window: NSWindow?
    private var languageObserver: AnyCancellable?

    func show() {
        if window == nil {
            let size = NSSize(width: 740, height: 475)
            let setupWindow = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            setupWindow.isReleasedWhenClosed = false
            let executable = Self.stableExecutablePath()
            let hosting = NSHostingController(rootView: MCPSetupView(executable: executable))
            // AppKit owns the window size. SwiftUI scrolls instructions within that space.
            hosting.sizingOptions = []
            setupWindow.contentViewController = hosting
            setupWindow.contentMinSize = NSSize(width: 460, height: 260)
            setupWindow.setContentSize(size)
            setupWindow.center()
            window = setupWindow
            languageObserver = AppLocalization.shared.$language.sink { [weak setupWindow] _ in
                setupWindow?.title = localized("How to connect MCP")
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private static func stableExecutablePath() -> String? {
        let files = FileManager.default
        func executablePath(in bundle: Bundle) -> String? {
            guard let executable = bundle.executableURL?.resolvingSymlinksInPath(),
                  !executable.pathComponents.contains("AppTranslocation"),
                  !executable.path.hasPrefix("/Volumes/"),
                  files.isExecutableFile(atPath: executable.path) else { return nil }
            return executable.path
        }

        let running = Bundle.main
        if let path = executablePath(in: running) { return path }
        guard let identifier = running.bundleIdentifier else { return nil }
        for directory in files.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask]) {
            let url = directory.appendingPathComponent("Wakecup.app", isDirectory: true)
            if let installed = Bundle(url: url), installed.bundleIdentifier == identifier,
               let path = executablePath(in: installed) {
                return path
            }
        }
        return nil
    }
}

private struct MCPSetupView: View {
    private enum Client: String, CaseIterable {
        case codex = "Codex"
        case claudeDesktop = "Claude Desktop"
        case claudeCode = "Claude Code"
    }

    private static let arguments = ["--cli", "mcp"]
    let executable: String?
    @ObservedObject private var localization = AppLocalization.shared
    @State private var client: Client = .codex

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let executable {
                Picker(localized("MCP client"), selection: $client) {
                    ForEach(Client.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        clientInstructions(executable: executable)
                        Text(localized("To test the connection, ask “What’s the Wakecup status?”"))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
            } else {
                Text(localized("Move Wakecup to Applications and open it from there to set up MCP."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .font(Font(AppStyle.Font.body))
        .padding(.horizontal, AppStyle.Layout.windowInset)
        .padding(.vertical, AppStyle.Layout.windowTopInset)
    }

    @ViewBuilder private func clientInstructions(executable: String) -> some View {
        switch client {
        case .codex:
            Text(localized("In Codex, open Settings → MCP servers → Add server. Name it wakecup and choose STDIO."))
            Text(localized("Command")).font(Font(AppStyle.Font.sectionTitle))
            copyable(executable)
            Text(localizedFormat("Under Arguments, click “Add argument” and enter %@. Click “Add argument” again and enter %@ in the second field. Save the server and restart Codex.", Self.arguments[0], Self.arguments[1]))
        case .claudeDesktop:
            Text(localized("Open this Claude Desktop configuration file. Create it if it does not exist."))
            Text("~/Library/Application Support/Claude/claude_desktop_config.json")
                .font(Font(AppStyle.Font.monospacedBody))
            Text(localized("Paste the configuration below into an empty file. If mcpServers already exists, add the wakecup entry to it and keep the other entries."))
            if let configuration = claudeDesktopConfiguration(executable: executable) {
                copyable(configuration)
            }
            Text(localized("Quit Claude Desktop completely and reopen it."))
        case .claudeCode:
            Text(localized("Run this command in Terminal to add Wakecup for your macOS user account. Then open Claude Code and use /mcp to check the connection."))
            let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
            copyable("claude mcp add --transport stdio --scope user wakecup -- \(quoted) \(Self.arguments.joined(separator: " "))")
        }
    }

    private func claudeDesktopConfiguration(executable: String) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let command = try? encoder.encode(executable),
              let arguments = try? encoder.encode(Self.arguments) else { return nil }
        return """
        {
          "mcpServers": {
            "wakecup": {
              "command": \(String(decoding: command, as: UTF8.self)),
              "args": \(String(decoding: arguments, as: UTF8.self))
            }
          }
        }
        """
    }

    private func copyable(_ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(value).font(Font(AppStyle.Font.monospacedBody))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button(localized("Copy")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            }
            .accessibilityLabel(localizedFormat("Copy: %@", value))
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
    }
}
