import Foundation

enum PowerMode: String, Codable {
    case ac
    case battery
}

enum BatteryThreshold {
    static let range = 10...90
}

struct PowerState {
    let onAC: Bool
    let percent: Int?
}

// The same policy drives startup availability and the running guardian.
// Serialized reason text stays stable for existing recovery records.
enum PowerRestriction: Equatable {
    case invalidThreshold, powerUnavailable, chargerRequired, chargeUnavailable
    case lowCharge(Int)

    var reason: String {
        switch self {
        case .invalidThreshold: "порог заряда должен быть от 10% до 90%"
        case .powerUnavailable: "не удалось прочитать состояние питания"
        case .chargerRequired: "зарядка отключена"
        case .chargeUnavailable: "не удалось определить заряд аккумулятора"
        case .lowCharge(let threshold): "заряд достиг порога \(threshold)%"
        }
    }
}

func powerRestriction(_ state: PowerState?, mode: PowerMode, threshold: Int) -> PowerRestriction? {
    guard BatteryThreshold.range.contains(threshold) else { return .invalidThreshold }
    guard let state else { return .powerUnavailable }
    switch mode {
    case .ac:
        guard state.onAC else { return .chargerRequired }
    case .battery:
        if state.onAC { return nil }
        guard let percent = state.percent, (0...100).contains(percent) else { return .chargeUnavailable }
        guard percent > threshold else { return .lowCharge(threshold) }
    }
    return nil
}

func powerStopReason(_ state: PowerState?, mode: PowerMode, threshold: Int) -> String? {
    powerRestriction(state, mode: mode, threshold: threshold)?.reason
}
