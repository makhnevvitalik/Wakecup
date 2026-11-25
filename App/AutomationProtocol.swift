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
    var shortcut: LegacyDisplayShortcut?
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
    let shortcut: LegacyDisplayShortcut?
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
    enum Outcome: String, Codable { case completed, pending, rejected, partiallyApplied, unknown }
    let outcome: Outcome
    var message: String? = nil
    var status: AutomationStatus? = nil
    var mcpSession: UUID? = nil
}

enum AutomationJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            // Preserve requested precision without changing the date format of status replies.
            if encoder.codingPath.last?.stringValue == "until",
               date.timeIntervalSinceReferenceDate.rounded() != date.timeIntervalSinceReferenceDate {
                formatter.formatOptions.insert(.withFractionalSeconds)
            }
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = AutomationDate.parse(value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO-8601 date.")
            }
            return date
        }
        return try decoder.decode(type, from: data)
    }
}

enum AutomationDate {
    static func parse(_ value: String) -> Date? {
        // Foundation normalizes some impossible days. Check the date before converting its time zone.
        let pattern = #/([0-9]{4})-([0-9]{2})-([0-9]{2})T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:[.][0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):?[0-5][0-9])/#
        guard let match = value.wholeMatch(of: pattern),
              let year = Int(match.1), year > 0, let month = Int(match.2), let day = Int(match.3),
              (1...12).contains(month), day > 0 else { return nil }
        let leapYear = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard day <= daysInMonth[month - 1] else { return nil }
        let formatter = ISO8601DateFormatter()
        if value.contains(".") { formatter.formatOptions.insert(.withFractionalSeconds) }
        return formatter.date(from: value)
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
