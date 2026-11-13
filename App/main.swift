import AppKit
import SwiftUI
import Foundation

let arguments = CommandLine.arguments
if arguments.dropFirst().first == "--cli" {
    let command = Array(arguments.dropFirst(2))
    exit(command == ["mcp"] ? AutomationMCP.run() : AutomationCLI.run(command))
} else if arguments.contains("--restore-backlight") {
    exit(BacklightRestoreCommand.main(arguments: arguments))
} else if arguments.contains("--recovery-guide") {
    let languageIndex = arguments.firstIndex(of: "--language")
    let language = languageIndex.flatMap { $0 + 1 < arguments.count ? AppLanguage(rawValue: arguments[$0 + 1]) : nil } ?? .english
    print(SleepRecoveryGuide.plainText(language: language), terminator: "")
} else if arguments.contains("--self-test") {
    do { try selfTest(); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else if arguments.contains("--helper-self-test") {
    do {
        let own = try HelperTrust.signingHash()
        guard HelperPolicy.validHash(own),
              let helper = Bundle.main.url(forResource: HelperConstants.label, withExtension: nil, subdirectory: "Helper"),
              try PrivilegedExecution.sourceDigest(at: helper) == HelperBuildIdentity.sha256,
              try HelperTrust.signingHash(of: helper) == HelperBuildIdentity.cdHash else {
            throw WakecupError(message: "The bundled helper identity differs from its compiled-in pin.")
        }
        print("PASS: running app and bundled helper Hardened Runtime, signatures and compiled-in identity")
    } catch { print(error.localizedDescription); exit(1) }
} else if arguments.contains("--helper-ping") {
    var done = false, succeeded = false
    HelperClient(hash: HelperBuildIdentity.cdHash).information { result in
        switch result {
        case .success(let value):
            succeeded = value.ownerUID == getuid() && value.clientHash == (try? HelperTrust.signingHash())
                && value.helperHash == HelperBuildIdentity.cdHash && value.protocolVersion == HelperConstants.protocolVersion
            print(succeeded ? "HELPER_READY" : "HELPER_IDENTITY_MISMATCH")
        case .failure(let error): print(error.localizedDescription)
        }
        done = true
    }
    let limit = Date().addingTimeInterval(12)
    while !done && Date() < limit { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    exit(succeeded ? 0 : 1)
} else if arguments.contains("--probe") {
    let power = readPowerState()
    print("AC=\(String(describing: power?.onAC)) BATTERY=\(String(describing: power?.percent)) LID=\(String(describing: lidClosed())) DISABLED=\(String(describing: try? readDisabled()))")
} else if arguments.contains("--login-status") {
    let loginItem = LoginItemController.system
    print("Login item: \(String(describing: loginItem.readStatus())); checked: \(loginItem.checked)")
} else if arguments.contains("--smoke-test") {
    do { try nativeSmokeTest(); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else if arguments.contains("--verify-guard-timer") {
    do { try guardSmokeTest(); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
