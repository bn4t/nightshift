import Foundation
import NightshiftCore
import Observation

struct ExcludedApp: Codable, Hashable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }
}

@MainActor
@Observable
final class SettingsStore {
    var schedule: ScheduleSettings {
        didSet { save(); onChange?() }
    }

    var excludedApps: [ExcludedApp] {
        didSet { save(); onChange?() }
    }

    var hasLaunchedBefore: Bool {
        didSet { defaults.set(hasLaunchedBefore, forKey: Keys.launched) }
    }

    /// Human-readable place for the coordinate ("Paris, France"); nil when the
    /// coordinate was typed in or imported.
    var locationName: String? {
        didSet { defaults.set(locationName, forKey: Keys.locationName) }
    }

    /// Turn macOS Night Shift off (and keep it off) while Nightshift runs.
    var keepNightShiftOff: Bool {
        didSet { defaults.set(keepNightShiftOff, forKey: Keys.keepNightShiftOff); onChange?() }
    }

    /// Last settings tab the user looked at.
    var settingsTab: Int {
        didSet { defaults.set(settingsTab, forKey: Keys.settingsTab) }
    }

    func setLocation(_ coordinate: Coordinate, name: String?) {
        locationName = name
        schedule.coordinate = coordinate
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults

    private enum Keys {
        static let schedule = "schedule"
        static let excluded = "excludedApps"
        static let launched = "hasLaunchedBefore"
        static let locationName = "locationName"
        static let settingsTab = "settingsTab"
        static let keepNightShiftOff = "keepNightShiftOff"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        schedule = defaults.data(forKey: Keys.schedule)
            .flatMap { try? decoder.decode(ScheduleSettings.self, from: $0) } ?? ScheduleSettings()
        excludedApps = defaults.data(forKey: Keys.excluded)
            .flatMap { try? decoder.decode([ExcludedApp].self, from: $0) } ?? []
        hasLaunchedBefore = defaults.bool(forKey: Keys.launched)
        locationName = defaults.string(forKey: Keys.locationName)
        settingsTab = defaults.integer(forKey: Keys.settingsTab)
        keepNightShiftOff = defaults.object(forKey: Keys.keepNightShiftOff) as? Bool ?? true
    }

    func isExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains { $0.bundleID == bundleID }
    }

    func toggleExclusion(bundleID: String, name: String) {
        if isExcluded(bundleID) {
            excludedApps.removeAll { $0.bundleID == bundleID }
        } else {
            excludedApps.append(ExcludedApp(bundleID: bundleID, name: name))
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(schedule) { defaults.set(data, forKey: Keys.schedule) }
        if let data = try? encoder.encode(excludedApps) { defaults.set(data, forKey: Keys.excluded) }
    }
}

/// One-time import of an existing f.lux configuration (location, bedtime colour,
/// wake time) so switching over doesn't mean re-entering everything.
enum FluxImport {
    static let bundleID = "org.herf.Flux"

    private static func value(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, bundleID as CFString)
    }

    private static func number(_ key: String) -> Double? {
        switch value(key) {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    static var isAvailable: Bool { value("location") != nil || value("wakeTime") != nil }

    /// Returns `base` with whatever f.lux settings could be found applied, or nil.
    static func importedSettings(onto base: ScheduleSettings) -> ScheduleSettings? {
        var s = base
        var found = false
        if let text = value("location") as? String, let c = Coordinate(parsing: text) {
            s.coordinate = c
            found = true
        }
        if let k = number("dayColorTemp") { s.dayKelvin = k; found = true }
        if let k = number("nightColorTemp") { s.eveningKelvin = k; found = true }
        if let k = number("lateColorTemp") { s.bedtimeKelvin = k; s.bedtimeEnabled = true; found = true }
        if let wake = number("wakeTime") {
            s.wakeMinutes = ScheduleSettings.wrapMinutes(Int(wake))
            // f.lux derives bedtime from wake time; start 8½ h before, on a quarter hour.
            let bed = (Int(wake) - 510) / 15 * 15
            s.bedtimeMinutes = ScheduleSettings.wrapMinutes(bed)
            found = true
        }
        return found ? s.sanitized() : nil
    }
}
