import Foundation

enum AutomationAction: String, Codable {
    case status, start, stop, adjust, configure, restoreBrightness, cancelBlackout
    case setShortcut, clearShortcut, helperStatus, helperInstall, helperUpdate, helperRemove
    case helperUse, restoreSleep
}

struct AutomationRequest: Codable {
    let action: AutomationAction
    var seconds: Int?
    var until: Date?
    var indefinite: Bool?
    var allowBattery: Bool?
    var threshold: Int?
    var closedLid: Bool?
    var display: DisplayMode?
    var shortcut: DisplayShortcut?
    var useHelper: Bool?
}

struct AutomationEnvelope: Codable {
    let request: AutomationRequest
    let viaMCP: Bool
    var mcpSession: UUID? = nil
}

struct AutomationStatus: Codable {
    let phase: String
    let endTime: Date?
    let remainingSeconds: Int?
    let closedLid: Bool
    let allowBattery: Bool
    let threshold: Int
    let batteryPercent: Int?
    let onAC: Bool?
    let display: DisplayMode
    let shortcut: DisplayShortcut?
    let backlightOff: Bool
    let blackoutCountdown: Int?
    let helperState: String
    let helperSelected: Bool
    let helperWorking: Bool
    let helperChecking: Bool
    let helperDetail: String
    let helperInstallationError: String?
    let needsRecovery: Bool
    let mcpEnabled: Bool
    let settingsApplying: Bool
    let displayTransitioning: Bool
    let settingsPartiallyApplied: Bool
    let message: String?
}

struct AutomationReply: Codable {
    enum Outcome: String, Codable { case completed, pending, rejected, partiallyApplied }
    let outcome: Outcome
    var message: String? = nil
    var status: AutomationStatus? = nil
    var mcpSession: UUID? = nil
}

enum AutomationJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

extension DisplayShortcut {
    static func automationShortcut(function: Int, modifiers: [String]) throws -> DisplayShortcut {
        let flags: [String: UInt32] = [
            "shift": DisplayShortcut.shift, "control": DisplayShortcut.control,
            "option": DisplayShortcut.option, "command": DisplayShortcut.command
        ]
        var mask: UInt32 = 0
        for modifier in modifiers {
            guard let flag = flags[modifier], mask & flag == 0 else { throw WakecupError(message: "Invalid shortcut modifier.") }
            mask |= flag
        }
        guard let shortcut = DisplayShortcut(functionNumber: function, modifiers: mask), shortcut.isValid else {
            throw WakecupError(message: "Choose F1–F20 with at least one modifier.")
        }
        return shortcut
    }
}
