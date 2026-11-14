import AppKit
import SwiftUI

// Offscreen only: no desktop windows, daemon calls or sleep operations.
@main struct BatteryOptionsLayoutTests {
    @MainActor static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    @MainActor private static func run() throws {
        let language = CommandLine.arguments[1]
        UserDefaults.standard.setVolatileDomain([AppLocalization.languageKey: language], forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "WakecupBatteryLayoutTest-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let helper = PrivilegedHelperController(defaults: defaults,
            inspectInstallation: { .init(state: .missing) }, requestInformation: { _ in })
        var currentPower: PowerState? = .init(onAC: true, percent: 42)
        let operations = SessionOperations(now: { 1000 }, readPower: { currentPower },
            readSleepDisabled: { false }, startAssertions: { _ in }, stopAssertions: {},
            createFiles: { _ in throw WakecupError(message: "Unexpected session start") },
            guardianResponding: { _, _ in false },
            authorization: { _, _ in .init(run: { _ in }, cancel: {}) }, usesInstalledHelper: { false },
            startHelper: { _, _, _ in },
            loginItem: .init(readStatus: { .notRegistered }, register: {}, unregister: {}, openSettings: {}),
            scheduleTicks: { _ in {} })
        let model = SessionModel(defaults: defaults, operations: operations, helper: helper)
        let host = NSHostingController(rootView: WakecupView(model: model, showAbout: {}, configureDisplayShortcut: { _ in false }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: MenuLayout.width, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.orderOut(nil) }
        var baseline: NSSize?
        for enabled in [true, false, true, false, true] {
            model.editAllowBattery(enabled)
            for _ in 0..<3 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.view.layoutSubtreeIfNeeded()
            }
            let size = host.view.fittingSize
            print("battery=\(enabled) size=\(size)")
            if let baseline, size != baseline {
                throw WakecupError(message: "Battery toggle changed full menu height: \(baseline.height) -> \(size.height)")
            }
            baseline = size
            host.view.setFrameSize(size); window.setContentSize(size)
            host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
            guard let scale = descendants(host.view).first(where: { $0.identifier?.rawValue == "WakecupBatteryScale" }),
                  let slider = descendants(scale).compactMap({ $0 as? NSSlider }).first else {
                throw WakecupError(message: "One shared battery scale must combine charge and the stop threshold")
            }
            if slider.isEnabled != enabled || slider.isHidden == enabled {
                throw WakecupError(message: "The threshold must be visible and interactive only when battery operation is enabled")
            }
            if slider.minValue != 10 || slider.maxValue != 90 || slider.frame.width <= scale.bounds.width * 0.75 || slider.frame.width >= scale.bounds.width {
                throw WakecupError(message: "The threshold must occupy only the 10–90 region of the 1–100 scale")
            }
            if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-battery-layout-\(language)-\(enabled).png"))
                }
            }
        }
        let cases: [(String, Bool, PowerState?, Double, PowerRestriction?)] = [
            ("charger-required", false, .init(onAC: false, percent: 62), 50, .chargerRequired),
            ("battery-allowed", true, .init(onAC: false, percent: 62), 50, nil),
            ("low-charge", true, .init(onAC: false, percent: 49), 50, .lowCharge(50)),
            ("at-threshold", true, .init(onAC: false, percent: 50), 50, .lowCharge(50)),
            ("threshold-lowered", true, .init(onAC: false, percent: 50), 20, nil),
            ("connected-low-charge", true, .init(onAC: true, percent: 10), 50, nil),
            ("power-unknown", true, nil, 20, .powerUnavailable),
            ("charge-unknown", true, .init(onAC: false, percent: nil), 20, .chargeUnavailable),
            ("reconnected", false, .init(onAC: true, percent: 62), 50, nil)
        ]
        for (name, allowed, power, threshold, restriction) in cases {
            currentPower = power
            model.editAllowBattery(allowed)
            model.editThreshold(threshold)
            model.tick()
            if model.startPowerRestriction != restriction { throw WakecupError(message: "Wrong Start availability: \(name)") }
            if restriction != nil { model.start() }
            for _ in 0..<3 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                host.view.layoutSubtreeIfNeeded()
            }
            let size = host.view.fittingSize
            if model.phase != .idle || model.message != nil || size != baseline {
                throw WakecupError(message: "Power validation changed UI: \(name), phase=\(model.phase), message=\(model.message?.key ?? "nil"), size=\(size), baseline=\(String(describing: baseline))")
            }
            host.view.setFrameSize(size); window.setContentSize(size)
            host.view.layoutSubtreeIfNeeded(); host.view.displayIfNeeded()
            if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
                host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "/private/tmp/wakecup-power-button-\(language)-\(name).png"))
                }
            }
        }
        print("PASS: power, charge and option changes update Start availability without error cards or menu resizing (\(language))")
        print("PASS: battery toggles preserve full menu geometry (\(language))")
    }
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
