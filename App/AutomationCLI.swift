import Foundation

enum AutomationCLI {
    static let usage = """
        Usage: wakecup <command>
          status | stop | restore-sleep
          start <duration|ISO-8601|indefinite> [options]
          extend <duration> | shorten <duration>
          configure [--end <duration|ISO-8601|indefinite>] [options]
          restore-brightness | cancel-blackout | clear-shortcut
          set-shortcut <F1–F20> <shift|control|option|command>[+...]
          helper <status|install|update|remove|use|password>
          mcp

        Options: --lid on|off, --battery on|off, --threshold 10–90,
                 --display system|on|off
        Durations: 10s, 30m, 3h, 1d (minimum \(EndTimeSelection.minimumDurationSeconds)s). Commands return JSON.
        """

    static func run(_ arguments: [String]) -> Int32 {
        if arguments.isEmpty || arguments == ["--help"] {
            print(usage)
            return 0
        }
        let reply: AutomationReply
        do { reply = send(try parse(arguments)) }
        catch { reply = AutomationReply(outcome: .rejected, message: error.localizedDescription) }
        if let data = try? AutomationJSON.encode(reply) { print(String(decoding: data, as: UTF8.self)) }
        return reply.outcome == .rejected ? 1 : 0
    }

    static func send(_ request: AutomationRequest) -> AutomationReply {
        let envelope = AutomationEnvelope(request: request, viaMCP: false)
        do { return try AutomationSocket.send(envelope) }
        catch is AutomationSocket.Unavailable where request.action == .start {
            do {
                // Start the installed bundle with Launch Services, then wait for its listener.
                let binary = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                let bundle = binary.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                guard bundle.pathExtension == "app" else { throw invalid("Open the Wakecup application first.") }
                let launch = Process()
                launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                launch.arguments = ["-g", bundle.path, "--args", "--automation-launch"]
                launch.standardOutput = FileHandle.nullDevice
                launch.standardError = FileHandle.nullDevice
                try launch.run()
                launch.waitUntilExit()
                guard launch.terminationStatus == 0 else { throw invalid("Could not launch Wakecup.") }
                for _ in 0..<50 {
                    do { return try AutomationSocket.send(envelope) }
                    catch is AutomationSocket.Unavailable { Thread.sleep(forTimeInterval: 0.1) }
                }
                throw AutomationSocket.Unavailable()
            } catch { return AutomationReply(outcome: .rejected, message: error.localizedDescription) }
        } catch {
            return AutomationReply(outcome: .rejected, message: error.localizedDescription)
        }
    }

    static func parse(_ arguments: [String]) throws -> AutomationRequest {
        guard let command = arguments.first else { throw invalid() }
        var values = ArraySlice(arguments.dropFirst())
        func next() throws -> String {
            guard let value = values.popFirst() else { throw invalid() }
            return value
        }
        var request: AutomationRequest
        switch command {
        case "status": request = .init(action: .status)
        case "stop": request = .init(action: .stop)
        case "restore-sleep": request = .init(action: .restoreSleep)
        case "restore-brightness": request = .init(action: .restoreBrightness)
        case "cancel-blackout": request = .init(action: .cancelBlackout)
        case "clear-shortcut": request = .init(action: .clearShortcut)
        case "set-shortcut":
            let key = try next().uppercased()
            guard key.first == "F", let number = Int(key.dropFirst()) else { throw invalid() }
            let modifiers = try next().lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
            request = .init(action: .setShortcut, shortcut: try DisplayShortcut.automationShortcut(function: number, modifiers: modifiers))
        case "extend", "shorten":
            guard let seconds = duration(try next()) else { throw invalid("Use a duration such as 30m or 1h.") }
            try EndTimeSelection.validateDuration(seconds)
            request = .init(action: .adjust, seconds: command == "extend" ? seconds : -seconds)
        case "helper":
            switch try next() {
            case "status": request = .init(action: .helperStatus)
            case "install": request = .init(action: .helperInstall)
            case "update": request = .init(action: .helperUpdate)
            case "remove": request = .init(action: .helperRemove)
            case "use": request = .init(action: .helperUse, useHelper: true)
            case "password": request = .init(action: .helperUse, useHelper: false)
            default: throw invalid()
            }
        case "start", "configure":
            request = .init(action: command == "start" ? .start : .configure)
            if command == "start" { try setEnd(try next(), on: &request) }
            var seen = Set<String>()
            while let flag = values.popFirst() {
                guard seen.insert(flag).inserted else { throw invalid("Repeated option: " + flag) }
                let value = try next()
                switch flag {
                case "--end" where command == "configure": try setEnd(value, on: &request)
                case "--battery": request.allowBattery = try boolean(value)
                case "--lid": request.closedLid = try boolean(value)
                case "--threshold":
                    guard let threshold = Int(value), BatteryThreshold.range.contains(threshold) else {
                        throw invalid("Battery threshold must be 10–90%.")
                    }
                    request.threshold = threshold
                case "--display":
                    switch value {
                    case "system": request.display = .mayTurnOff
                    case "on": request.display = .keepOn
                    case "off": request.display = .backlightOff
                    default: throw invalid()
                    }
                default: throw invalid("Unknown option: " + flag)
                }
            }
            if command == "configure" && seen.isEmpty { throw invalid("Specify a setting to change.") }
        default: throw invalid()
        }
        guard values.isEmpty else { throw invalid("Unexpected arguments.") }
        return request
    }

    private static func setEnd(_ value: String, on request: inout AutomationRequest) throws {
        if value == "indefinite" { request.indefinite = true }
        else if let seconds = duration(value) {
            try EndTimeSelection.validateDuration(seconds)
            request.seconds = seconds
        }
        else if let date = ISO8601DateFormatter().date(from: value) { request.until = date }
        else { throw invalid("Choose a duration, an ISO-8601 end time with time zone, or indefinite.") }
    }

    private static func duration(_ value: String) -> Int? {
        let units: [Character: Int] = ["s": 1, "m": 60, "h": 3600, "d": 86400]
        guard let unit = value.last, let scale = units[unit],
              let count = Int(value.dropLast()), count > 0 else { return nil }
        let (seconds, overflow) = count.multipliedReportingOverflow(by: scale)
        return overflow ? nil : seconds
    }

    private static func boolean(_ value: String) throws -> Bool {
        switch value {
        case "on": return true
        case "off": return false
        default: throw invalid("Choose on or off.")
        }
    }

    private static func invalid(_ message: String = "Invalid command. See wakecup --help.") -> WakecupError {
        WakecupError(message: message)
    }
}
