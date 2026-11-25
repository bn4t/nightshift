import AppKit
import NightshiftCore

let arguments = CommandLine.arguments

if arguments.contains("--reset") {
    // Escape hatch: put every display back to its ColorSync curve.
    CGDisplayRestoreColorSyncSettings()
    exit(0)
}

if arguments.contains("--night-shift-status") {
    if let s = NightShift.status {
        print("Night Shift: \(s.enabled ? "on" : "off"), schedule mode \(s.mode) (0 = none, 1 = sunset→sunrise, 2 = custom)")
    } else {
        print("Night Shift: not available")
    }
    exit(0)
}

if arguments.contains("--print-schedule") {
    // Headless check of the schedule with the saved settings; touches no displays.
    let settings = SettingsStore()
    var scheduleSettings = settings.schedule
    if !settings.hasLaunchedBefore, let imported = FluxImport.importedSettings(onto: scheduleSettings) {
        print("(not set up yet — showing what first launch would import from f.lux)")
        scheduleSettings = imported
    }
    let schedule = Schedule(settings: scheduleSettings)
    let s = schedule.settings
    print("Location \(s.coordinate.latitude), \(s.coordinate.longitude) · day \(Int(s.dayKelvin)) K · evening \(Int(s.eveningKelvin)) K · bedtime \(s.bedtimeEnabled ? "\(Int(s.bedtimeKelvin)) K" : "off")")
    print("Solar day: \(schedule.solarDay(for: .now))")
    for sample in schedule.samples(forDayContaining: .now, stepMinutes: 60) {
        let st = schedule.state(at: sample.date)
        print(sample.date.formatted(date: .omitted, time: .shortened), Int(st.kelvin.rounded()), "K", st.phase.rawValue)
    }
    for e in schedule.upcomingEvents(after: .now) {
        print("next:", e.kind.rawValue, e.date.formatted(date: .abbreviated, time: .shortened))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
