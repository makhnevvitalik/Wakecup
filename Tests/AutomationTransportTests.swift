import Foundation
import CoreFoundation

@main
struct AutomationTransportTests {
    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--mcp-child" {
            let path = CommandLine.arguments[2]
            exit(AutomationMCP.run(access: {
                let envelope = AutomationEnvelope(request: .init(action: .status), viaMCP: true)
                let reply = try AutomationSocket.send(envelope, path: path)
                if reply.outcome == .pending { throw WakecupError(message: "Temporary transport failure") }
                return reply.mcpSession
            }))
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
        func call(_ value: String) -> [String: Any]? {
            AutomationMCP.handle(Data(value.utf8), initialized: &initialized) { request in
                precondition(request.action == .setShortcut && request.shortcut?.displayName == "⇧⌘F2")
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
        precondition(invalid?["error"] != nil)
        let startTool = tools?.first { $0["name"] as? String == "wakecup_start" }
        let schema = startTool?["inputSchema"] as? [String: Any]
        let properties = schema?["properties"] as? [String: [String: Any]]
        precondition(properties?["seconds"]?["minimum"] as? Int == 10)
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
        var injectFailure = false
        var sawFailure = false
        let server = try AutomationSocket(path: path) { _ in
            if injectFailure {
                injectFailure = false
                sawFailure = true
                return AutomationReply(outcome: .pending)
            }
            return AutomationReply(outcome: session == nil ? .rejected : .completed, mcpSession: session)
        }
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
        try withExtendedLifetime(server) {
            let (disabled, _, noOutput) = try launch()
            awaitExit(disabled)
            precondition(disabled.terminationStatus != 0 && noOutput.fileHandleForReading.readDataToEndOfFile().isEmpty)
            session = UUID()
            let (enabled, input, output) = try launch()
            defer { if enabled.isRunning { enabled.terminate() } }
            let messages = #"""
                {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}
                {"jsonrpc":"2.0","id":2,"method":"tools/list"}
                """# + "\n"
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
            var response = Data()
            let deadline = Date().addingTimeInterval(5)
            output.fileHandleForReading.readabilityHandler = { handle in
                let bytes = handle.availableData
                if bytes.isEmpty { handle.readabilityHandler = nil }
                DispatchQueue.main.async { response.append(bytes) }
            }
            while !String(decoding: response, as: UTF8.self).contains("wakecup_status") && Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            precondition(String(decoding: response, as: UTF8.self).contains("wakecup_status"))
            injectFailure = true
            let failureDeadline = Date().addingTimeInterval(4)
            while !sawFailure && Date() < failureDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            precondition(sawFailure && enabled.isRunning)
            try input.fileHandleForWriting.write(contentsOf: Data(messages.utf8))
            let retryDeadline = Date().addingTimeInterval(4)
            while String(decoding: response, as: UTF8.self).components(separatedBy: "wakecup_status").count < 3
                    && Date() < retryDeadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            precondition(String(decoding: response, as: UTF8.self).components(separatedBy: "wakecup_status").count >= 3)
            session = nil
            awaitExit(enabled)
            output.fileHandleForReading.readabilityHandler = nil
        }
        print("PASS: MCP stays down when disabled and disconnects an idle client when switched off")
    }

}
