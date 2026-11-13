import Foundation
import Darwin

let arguments = CommandLine.arguments
do {
    guard geteuid() == 0 else { throw WakecupError(message: "The system helper requires administrator permission.") }
    if arguments.count == 2, arguments[1] == "--daemon" {
        try HelperService.run()
    } else if arguments.count == 4, ["--authorized-guard", "--managed-guard"].contains(arguments[1]) {
        if arguments[1] == "--authorized-guard" { try PrivilegedExecution.validateStagedExecutable() }
        let context = try ManagedGuardContext.decode(arguments[3])
        exit(runGuard(at: URL(fileURLWithPath: arguments[2]), context: context))
    } else if arguments.count == 4, ["--install", "--uninstall"].contains(arguments[1]), let uid = UInt32(arguments[2]) {
        try HelperInstaller.perform(ownerUID: uid, clientHash: arguments[3], remove: arguments[1] == "--uninstall")
        exit(0)
    } else { throw WakecupError(message: "Unknown Wakecup helper operation.") }
} catch {
    fputs(error.localizedDescription + "\n", stderr)
    exit(1)
}
