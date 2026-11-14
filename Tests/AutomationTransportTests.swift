import Foundation
import CoreFoundation

@main
struct AutomationTransportTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--mcp-child" {
            exit(AutomationMCP.run(path: CommandLine.arguments[2]))
        }
        try mcpLifecycle()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wc-" + String(UUID().uuidString.prefix(8)))
        let path = directory.appendingPathComponent("control").path
        defer { try? FileManager.default.removeItem(at: directory) }
        var requests = [AutomationEnvelope]()
        let server = try AutomationSocket(path: path) { envelope in
            requests.append(envelope)
            return AutomationReply(outcome: .completed)
        }
        withExtendedLifetime(server) {
            DispatchQueue.global().async {
                let request = AutomationEnvelope(request: .init(action: .configure, threshold: 30, display: .keepOn), viaMCP: true)
                let reply = try? AutomationSocket.send(request, path: path)
                DispatchQueue.main.async {
                    precondition(reply?.outcome == .completed)
                    precondition(requests.count == 1 && requests[0].viaMCP && requests[0].request.threshold == 30)
                    precondition(requests[0].request.display == .keepOn)
                    print("PASS: Unix socket delivers commands and replies to the same application")
                    CFRunLoopStop(CFRunLoopGetMain())
                }
            }
            CFRunLoopRun()
        }

        var initialized = false
        var commands: [AutomationAction] = []
        func call(_ value: String) -> [String: Any]? {
            AutomationMCP.handle(Data(value.utf8), initialized: &initialized) { request in
                commands.append(request.action)
                if request.action == .setShortcut { precondition(request.shortcut?.displayName == "⇧⌘F2") }
                return AutomationReply(outcome: .pending, message: "Test")
            }
        }
        precondition(call(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["error"] != nil)
        let initialize = call(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        precondition((initialize?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
        let list = call(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#)
        let tools = (list?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        precondition(tools?.count == 15)
        let valid = call(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wakecup_set_shortcut","arguments":{"function":2,"modifiers":["shift","command"]}}}"#)
        precondition((valid?["result"] as? [String: Any])?["isError"] as? Bool == false)
        let invalid = call(#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"wakecup_set_shortcut","arguments":{"function":true,"modifiers":["shift"]}}}"#)
        precondition((invalid?["result"] as? [String: Any])?["isError"] as? Bool == true)
        precondition(invalid?["error"] == nil)
        let unknown = call(#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"unknown"}}"#)
        precondition(unknown?["error"] != nil && unknown?["result"] == nil)
        let malformed = call(#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wakecup_start","arguments":[]}}"#)
        precondition(malformed?["error"] != nil && malformed?["result"] == nil)
        let startTool = tools?.first { $0["name"] as? String == "wakecup_start" }
        let schema = startTool?["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: [String: Any]]
        precondition(properties?["seconds"]?["minimum"] as? Int == 10)
        let choices = schema?["oneOf"] as? [[String: [String]]]
        precondition(choices?.compactMap { $0["required"] } == [["seconds"], ["until"], ["indefinite"]])
        precondition(properties?["indefinite"]?["const"] as? Bool == true)

        for arguments in ["{}", #"{"indefinite":false}"#, #"{"seconds":60,"indefinite":true}"#,
                          #"{"seconds":60,"indefinite":false}"#, #"{"until":"tomorrow"}"#] {
            let response = call(#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"wakecup_start","arguments":\#(arguments)}}"#)
            precondition((response?["result"] as? [String: Any])?["isError"] as? Bool == true)
        }
        precondition(commands == [.setShortcut])
        for arguments in [#"{"seconds":60,"closedLid":false}"#, #"{"until":"2030-01-01T08:00:00Z"}"#, #"{"indefinite":true}"#] {
            let response = call(#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"wakecup_start","arguments":\#(arguments)}}"#)
            precondition((response?["result"] as? [String: Any])?["isError"] as? Bool == false)
        }
        precondition(commands == [.setShortcut, .start, .start, .start])
        precondition((try? AutomationCLI.parse(["start", "9s"])) == nil)
        let minimum = try AutomationCLI.parse(["start", "10s"])
        precondition(minimum.seconds == 10)
        precondition((try? AutomationCLI.parse(["extend", "9s"])) == nil)
        precondition((try? AutomationCLI.parse(["shorten", "9s"])) == nil)
        let adjustment = try AutomationCLI.parse(["shorten", "10s"])
        precondition(adjustment.seconds == -10)
        print("PASS: MCP handshake, tool discovery, validation and CLI duration parsing")
    }

    private static func mcpLifecycle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wc-" + String(UUID().uuidString.prefix(8)))
        let path = directory.appendingPathComponent("control").path
        defer { try? FileManager.default.removeItem(at: directory) }
        var session: UUID?
        var adjustments = 0
        func listen() throws -> AutomationSocket {
            try AutomationSocket(path: path) { envelope in
                guard let session else { return AutomationReply(outcome: .rejected) }
                if envelope.mcpSession == nil { return AutomationReply(outcome: .completed, mcpSession: session) }
                guard envelope.mcpSession == session else { return AutomationReply(outcome: .rejected) }
                if envelope.request.action == .adjust { adjustments += 1 }
                return AutomationReply(outcome: .completed)
            }
        }
        var server: AutomationSocket? = try listen()
        func launch() throws -> (Process, Pipe, Pipe) {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            child.arguments = ["--mcp-child", path]
            let input = Pipe()
            let output = Pipe()
            child.standardInput = input
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            try child.run()
            return (child, input, output)
        }
        func awaitExit(_ child: Process) {
            let deadline = Date().addingTimeInterval(5)
            while child.isRunning && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if child.isRunning { child.terminate(); preconditionFailure("MCP server stayed alive") }
        }
        let (disabled, _, noOutput) = try launch()
        awaitExit(disabled)
        precondition(disabled.terminationStatus != 0 && noOutput.fileHandleForReading.readDataToEndOfFile().isEmpty)
        session = UUID()
        let (enabled, input, output) = try launch()
        defer { if enabled.isRunning { enabled.terminate() } }
        var response = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let bytes = handle.availableData
            if bytes.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { response.append(bytes) }
        }
        defer { output.fileHandleForReading.readabilityHandler = nil }
        func waitFor(_ predicate: () -> Bool, _ failure: String) {
            let deadline = Date().addingTimeInterval(5)
            while !predicate() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            precondition(predicate(), failure)
        }
        func send(_ message: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data((message + "\n").utf8))
        }
        func result(_ id: Int) -> [String: Any]? {
            String(decoding: response, as: UTF8.self).split(separator: "\n").compactMap { line in
                (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            }.first { $0["id"] as? Int == id }?["result"] as? [String: Any]
        }
        try send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#)
        try send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        try send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        waitFor({ result(2)?["tools"] != nil }, "MCP discovery failed")
        precondition(server != nil)
        server = nil
        waitFor({ !FileManager.default.fileExists(atPath: path) }, "The old socket did not close")
        try send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"wakecup_adjust","arguments":{"seconds":60}}}"#)
        waitFor({ result(3)?["isError"] as? Bool == true }, "Commands during a restart must return an error")
        RunLoop.main.run(until: Date().addingTimeInterval(6))
        precondition(enabled.isRunning, "MCP disconnected before Wakecup restarted")
        server = try listen()
        try send(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"wakecup_status"}}"#)
        waitFor({ result(4)?["isError"] as? Bool == false }, "The original client failed to reconnect to Wakecup")
        precondition(adjustments == 0, "A failed command must not replay after reconnection")
        // A new grant revokes the previous one even if the client missed the disabled state.
        session = UUID()
        awaitExit(enabled)
        let (reenabled, inputAfterReenable, _) = try launch()
        defer { if reenabled.isRunning { reenabled.terminate() } }
        try inputAfterReenable.fileHandleForWriting.write(contentsOf: Data(
            (#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"# + "\n").utf8))
        // The new grant must also be revoked while an idle client is connected.
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(reenabled.isRunning, "A client with the new grant failed to start")
        session = nil
        withExtendedLifetime(server) { awaitExit(reenabled) }
        precondition(reenabled.terminationStatus == 0, "Explicitly disabling MCP must disconnect an idle client")
        print("PASS: MCP survives an app restart without replaying commands and disconnects a revoked client")
    }

}
