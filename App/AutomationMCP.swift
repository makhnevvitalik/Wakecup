import Foundation
import CoreFoundation

enum AutomationMCP {
    private static let supported = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let maximumLine = 64 * 1024

    private struct Tool {
        let action: AutomationAction
        let name: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]

        init(_ action: AutomationAction, _ description: String, _ properties: [String: [String: Any]] = [:], required: [String] = []) {
            self.action = action
            self.name = action.rawValue.replacingOccurrences(of: "([A-Z])", with: "_$1", options: .regularExpression).lowercased()
            self.description = description
            self.properties = properties
            self.required = required
        }

        var definition: [String: Any] {
            let readOnly = action == .status || action == .helperStatus
            return ["name": "wakecup_" + name, "description": description,
                    "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                    "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": false]]
        }
    }

    private static let settings: [String: [String: Any]] = [
        "seconds": ["type": "integer", "minimum": EndTimeSelection.minimumDurationSeconds, "description": "Duration in seconds from now"],
        "until": ["type": "string", "description": "ISO-8601 end time with time zone"],
        "indefinite": ["type": "boolean"],
        "allowBattery": ["type": "boolean"],
        "threshold": ["type": "integer", "minimum": 10, "maximum": 90],
        "closedLid": ["type": "boolean"],
        "display": ["type": "string", "enum": ["mayTurnOff", "keepOn", "backlightOff"]]
    ]

    private static let tools = [
        Tool(.status, "Read Wakecup's current timer, power, lid, display and helper state."),
        Tool(.start, "Start Wakecup. Supply exactly one of seconds, until, or indefinite=true. Optional settings override the saved choices.", settings),
        Tool(.stop, "Stop the current Wakecup timer and restore sleep and brightness."),
        Tool(.adjust, "Add or subtract at least \(EndTimeSelection.minimumDurationSeconds) seconds from an active timer with a deadline.", [
            "seconds": ["type": "integer", "anyOf": [
                ["minimum": EndTimeSelection.minimumDurationSeconds],
                ["maximum": -EndTimeSelection.minimumDurationSeconds]
            ]]
        ], required: ["seconds"]),
        Tool(.configure, "Apply timer, battery, lid or display changes. The response may be pending while Wakecup waits for macOS.", settings),
        Tool(.restoreBrightness, "Return to the previous display mode and brightness."),
        Tool(.cancelBlackout, "Cancel the countdown before the backlight turns off."),
        Tool(.setShortcut, "Set the shortcut for restoring brightness.", [
            "function": ["type": "integer", "minimum": 1, "maximum": 20],
            "modifiers": ["type": "array", "minItems": 1, "uniqueItems": true,
                          "items": ["type": "string", "enum": ["shift", "control", "option", "command"]]]
        ], required: ["function", "modifiers"]),
        Tool(.clearShortcut, "Clear the brightness restore shortcut."),
        Tool(.helperStatus, "Read closed-lid helper state and selection."),
        Tool(.helperInstall, "Install the closed-lid helper. Requires macOS administrator authorization."),
        Tool(.helperUpdate, "Update the closed-lid helper. Requires macOS administrator authorization."),
        Tool(.helperRemove, "Remove the closed-lid helper. Requires macOS administrator authorization."),
        Tool(.helperUse, "Choose whether Wakecup uses the installed helper.", ["useHelper": ["type": "boolean"]], required: ["useHelper"]),
        Tool(.restoreSleep, "Ask Wakecup to recover normal sleep after an interrupted session.")
    ]

    private static func currentSession() throws -> UUID? {
        let probe = AutomationEnvelope(request: .init(action: .status), viaMCP: true)
        return try AutomationSocket.send(probe).mcpSession
    }

    static func run(access: @escaping () throws -> UUID? = { try currentSession() }) -> Int32 {
        guard let session = try? access() else {
            FileHandle.standardError.write(Data("Open Wakecup and enable MCP in its settings menu.\n".utf8))
            return 1
        }

        // The MCP client owns this process. Close stdio even when the client
        // is idle, and invalidate old clients if the switch is turned back on.
        let watcher = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "local.wakecup.mcp"))
        watcher.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        var unreachableSince: TimeInterval?
        watcher.setEventHandler {
            do {
                guard try access() == session else { exit(0) }
                unreachableSince = nil
            } catch {
                let now = ProcessInfo.processInfo.systemUptime
                let firstFailure = unreachableSince ?? now
                unreachableSince = firstFailure
                if now - firstFailure >= 4 { exit(0) }
            }
        }
        watcher.resume()
        defer { watcher.cancel() }

        var initialized = false
        while let line = readLine() {
            do {
                guard try access() == session else { return 0 }
            } catch {
                // The command transport checks the connection again and never replays a tool call.
            }
            let response = handle(line, initialized: &initialized) { request in
                let envelope = AutomationEnvelope(request: request, viaMCP: true, mcpSession: session)
                do { return try AutomationSocket.send(envelope) }
                catch { return AutomationReply(outcome: .rejected, message: error.localizedDescription) }
            }
            if let response, let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data + Data([10]))
            }
        }
        return 0
    }

    private static func readLine() -> Data? {
        var data = Data()
        var oversized = false
        while true {
            let byte = getchar()
            if byte == EOF { return data.isEmpty ? nil : oversized ? Data() : data }
            if byte == 10 { return oversized ? Data() : data }
            if data.count < maximumLine { data.append(UInt8(byte)) }
            else { oversized = true }
        }
    }

    static func handle(_ data: Data, initialized: inout Bool, send: (AutomationRequest) -> AutomationReply) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return error(NSNull(), -32700, "Parse error")
        }
        guard let request = object as? [String: Any], request["jsonrpc"] as? String == "2.0",
              let method = request["method"] as? String else { return error(NSNull(), -32600, "Invalid request") }
        guard let id = request["id"] else { return nil }
        guard id is String || (id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true else {
            return error(NSNull(), -32600, "Invalid request ID")
        }
        guard request["params"] == nil || request["params"] is [String: Any] else {
            return error(id, -32602, "Invalid params")
        }
        let params = request["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String else { return error(id, -32602, "Missing protocol version") }
            initialized = true
            result = ["protocolVersion": supported.contains(requested) ? requested : supported[0],
                      "capabilities": ["tools": [:] as [String: String]],
                      "serverInfo": ["name": "wakecup", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"]]
        case "ping":
            result = [:]
        case "tools/list" where initialized:
            result = ["tools": tools.map(\.definition)]
        case "tools/call" where initialized:
            guard let name = params["name"] as? String, let tool = tools.first(where: { "wakecup_" + $0.name == name }),
                  params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return error(id, -32602, "Invalid tool or arguments")
            }
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]
                let command = try command(for: tool, arguments: arguments)
                let reply = send(command)
                let encoded = try AutomationJSON.encode(reply)
                let text = String(decoding: encoded, as: UTF8.self)
                result = ["content": [["type": "text", "text": text]], "isError": reply.outcome == .rejected]
            } catch {
                return self.error(id, -32602, error.localizedDescription)
            }
        default:
            return error(id, -32601, "Method unavailable")
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func command(for tool: Tool, arguments: [String: Any]) throws -> AutomationRequest {
        guard Set(arguments.keys).isSubset(of: Set(tool.properties.keys)),
              tool.required.allSatisfy({ arguments[$0] != nil && !(arguments[$0] is NSNull) }),
              arguments.values.allSatisfy({ !($0 is NSNull) }) else {
            throw WakecupError(message: "Unexpected or missing tool arguments.")
        }
        var fields = arguments
        if tool.action == .setShortcut {
            guard let number = fields["function"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let function = number as? Int, let modifiers = fields["modifiers"] as? [String] else {
                throw WakecupError(message: "Provide a function key number and modifiers.")
            }
            return AutomationRequest(action: .setShortcut, shortcut: try DisplayShortcut.automationShortcut(function: function, modifiers: modifiers))
        }
        fields["action"] = tool.action.rawValue
        return try AutomationJSON.decode(AutomationRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private static func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}
