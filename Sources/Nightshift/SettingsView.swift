import AppKit
import Charts
import NightshiftCore
import ServiceManagement
import SwiftUI

// MARK: - Window

/// Standard macOS settings window: toolbar tabs, window height follows the tab.
/// While it's open the app shows in the Dock and ⌘-Tab so it can be switched back to;
/// once it closes Nightshift goes back to living only in the menu bar.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let settings: SettingsStore
    private let controller: TintController

    init(settings: SettingsStore, controller: TintController) {
        self.settings = settings
        self.controller = controller
    }

    func show() {
        if window == nil { window = makeWindow() }
        guard let window else { return }
        let becomingRegular = NSApp.activationPolicy() != .regular
        if becomingRegular { NSApp.setActivationPolicy(.regular) }

        // Don't drop the user into the first text field.
        window.makeFirstResponder(nil)
        bringToFront()

        // Switching from menu-bar-only to a regular app completes asynchronously and
        // re-sorts our windows behind the active app's, which is what left Settings in the
        // background. Re-assert once the switch has gone through.
        if becomingRegular {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.bringToFront() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated { self?.bringToFront() }
            }
        }
    }

    private func bringToFront() {
        guard let window else { return }
        // `activate()` (macOS 14+) is only a request that cooperative activation may
        // decline. The user explicitly asked for this window, so activate regardless.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // From an app that isn't active (yet), orderFront places the window *behind* the
        // active app's windows; this puts it on top unconditionally.
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let tabs = SettingsTabViewController(settings: settings)
        tabs.tabStyle = .toolbar

        func add(_ title: String, _ symbol: String, _ view: some View) {
            let hosting = NSHostingController(rootView: view.frame(width: 500).tint(.orange))
            hosting.sizingOptions = [.preferredContentSize]
            hosting.title = title // becomes the window title, like System Settings
            let item = NSTabViewItem(viewController: hosting)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("Schedule", "clock", SchedulePane(settings: settings, controller: controller))
        add("Colours", "paintpalette", ColoursPane(settings: settings, controller: controller))
        add("General", "gearshape", GeneralPane(settings: settings))
        tabs.selectedTabViewItemIndex = min(max(settings.settingsTab, 0), tabs.tabViewItems.count - 1)

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.initialFirstResponder = nil
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

private final class SettingsTabViewController: NSTabViewController {
    private let settings: SettingsStore

    init(settings: SettingsStore) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        settings.settingsTab = selectedTabViewItemIndex
    }
}

/// Grouped form that reports its full height so the window can size to it.
private struct Pane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Schedule

private struct SchedulePane: View {
    @Bindable var settings: SettingsStore
    let controller: TintController
    @State private var editingLocation = false

    var body: some View {
        let schedule = Schedule(settings: settings.schedule)
        Pane {
            Section {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    NowCard(schedule: schedule, status: controller.status(at: context.date), now: context.date)
                }
            }

            Section {
                LabeledContent {
                    Button("Change…") { editingLocation = true }
                        .popover(isPresented: $editingLocation, arrowEdge: .trailing) {
                            LocationPicker(settings: settings)
                        }
                } label: {
                    Label {
                        Text(settings.locationName ?? "Location")
                        Text(settings.schedule.coordinate.formatted)
                    } icon: {
                        Image(systemName: "location.fill").foregroundStyle(.secondary)
                    }
                }
            }

            Section("Sleep") {
                Toggle(isOn: $settings.schedule.bedtimeEnabled) {
                    Text("Bedtime mode")
                    Text("An extra-warm tint while you should be winding down")
                }
                DatePicker("Bedtime", selection: time(\.bedtimeMinutes), displayedComponents: .hourAndMinute)
                    .disabled(!settings.schedule.bedtimeEnabled)
                DatePicker("Wake up", selection: time(\.wakeMinutes), displayedComponents: .hourAndMinute)
            }

            Section {
                Picker(selection: $settings.schedule.transitionMinutes) {
                    Text("1 min").tag(1.0)
                    Text("20 min").tag(20.0)
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                } label: {
                    Text("Fade length")
                    Text("For sunrise, sunset and bedtime")
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    private func time(_ keyPath: WritableKeyPath<ScheduleSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let m = settings.schedule[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: .now) ?? .now
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.schedule[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            }
        )
    }
}

/// "Right now" summary with today's curve.
private struct NowCard: View {
    let schedule: Schedule
    let status: TintController.Status
    let now: Date

    private var kelvin: Double {
        switch status {
        case let .schedule(state): state.kelvin
        default: ColorTemperature.neutral
        }
    }

    private var detail: String {
        switch schedule.solarDay(for: now) {
        case .polarDay: return "Midnight sun — no sunset today"
        case .polarNight: return "Polar night — no sunrise today"
        case .normal:
            guard let next = schedule.upcomingEvents(after: now).first else { return "" }
            return "\(next.kind.title) at \(next.date.formatted(date: .omitted, time: .shortened))"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                TintSwatch(kelvin: kelvin, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.title).font(.title3.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(kelvin.rounded())) K")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            DayCurve(schedule: schedule, now: now)
                .frame(height: 120)
        }
        .padding(.vertical, 6)
    }
}

private struct DayCurve: View {
    let schedule: Schedule
    let now: Date

    private struct Point: Identifiable {
        let date: Date
        let kelvin: Double
        var id: Date { date }
    }

    private static let floor = 1000.0
    private static let ceiling = 7000.0

    /// Vertical gradient where height = temperature, so the curve shows its real tint.
    private var gradient: LinearGradient {
        let stops = stride(from: Self.floor, through: Self.ceiling, by: 500).map { k in
            Gradient.Stop(color: Color(kelvin: k), location: (k - Self.floor) / (Self.ceiling - Self.floor))
        }
        return LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top)
    }

    var body: some View {
        let start = schedule.calendar.startOfDay(for: now)
        let end = schedule.calendar.date(byAdding: .day, value: 1, to: start) ?? start + 86_400
        let points = schedule.samples(forDayContaining: now, stepMinutes: 10).map { Point(date: $0.date, kelvin: $0.kelvin) }
        let sun: [(Date, String)] = switch schedule.solarDay(for: now) {
        case let .normal(rise, set): [(rise, "sunrise.fill"), (set, "sunset.fill")]
        default: []
        }

        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Floor", Self.floor), yEnd: .value("Kelvin", p.kelvin))
                    .foregroundStyle(gradient)
                    .opacity(0.25)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", p.date), y: .value("Kelvin", p.kelvin))
                    .foregroundStyle(gradient)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(sun, id: \.0) { date, symbol in
                RuleMark(x: .value("Time", date))
                    .foregroundStyle(.secondary.opacity(0.4))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, spacing: 2) {
                        VStack(spacing: 0) {
                            Image(systemName: symbol).symbolRenderingMode(.multicolor)
                            Text(date.formatted(date: .omitted, time: .shortened))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
            }
            let nowKelvin = schedule.state(at: now).kelvin
            PointMark(x: .value("Time", now), y: .value("Kelvin", nowKelvin))
                .symbol {
                    Circle()
                        .fill(Color(kelvin: nowKelvin))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 2))
                        .frame(width: 11, height: 11)
                }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: Self.floor...Self.ceiling)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .padding(.top, 26) // room for the sunrise/sunset labels
    }
}

private struct LocationPicker: View {
    @Bindable var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = LocationSearch()
    @State private var locator = LocationProvider()
    @State private var locating = false
    @State private var message: String?
    @State private var showCoordinates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search for a city", text: $search.query)
                .textFieldStyle(.roundedBorder)

            if !search.suggestions.isEmpty {
                VStack(spacing: 2) {
                    ForEach(search.suggestions) { s in
                        SuggestionRow(suggestion: s) {
                            search.resolve(s) { coordinate, name in
                                settings.setLocation(coordinate, name: name)
                                dismiss()
                            }
                        }
                    }
                }
            }

            Button(action: useCurrentLocation) {
                Label(locating ? "Locating…" : "Use Current Location", systemImage: "location")
            }
            .buttonStyle(.link)
            .disabled(locating)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            DisclosureGroup("Coordinates", isExpanded: $showCoordinates) {
                Grid(alignment: .leading) {
                    GridRow {
                        Text("Latitude").foregroundStyle(.secondary)
                        TextField("", value: coordinate(\.latitude), format: .number.precision(.fractionLength(0...4)))
                    }
                    GridRow {
                        Text("Longitude").foregroundStyle(.secondary)
                        TextField("", value: coordinate(\.longitude), format: .number.precision(.fractionLength(0...4)))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// Typing coordinates by hand drops the (now wrong) place name.
    private func coordinate(_ keyPath: WritableKeyPath<Coordinate, Double>) -> Binding<Double> {
        Binding(
            get: { settings.schedule.coordinate[keyPath: keyPath] },
            set: { value in
                var c = settings.schedule.coordinate
                c[keyPath: keyPath] = value
                settings.setLocation(c.clamped(), name: nil)
            }
        )
    }

    private func useCurrentLocation() {
        locating = true
        message = nil
        locator.request { result in
            switch result {
            case let .success(c):
                // ~1 km precision is plenty for sun times.
                let rounded = Coordinate(latitude: (c.latitude * 100).rounded() / 100,
                                         longitude: (c.longitude * 100).rounded() / 100)
                LocationSearch.placeName(for: rounded) { name in
                    MainActor.assumeIsolated {
                        settings.setLocation(rounded, name: name)
                        locating = false
                        dismiss()
                    }
                }
            case let .failure(error):
                locating = false
                message = error.localizedDescription
            }
        }
    }
}

private struct SuggestionRow: View {
    let suggestion: LocationSearch.Suggestion
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title)
                if !suggestion.subtitle.isEmpty {
                    Text(suggestion.subtitle).font(.caption).foregroundStyle(hovering ? .white.opacity(0.85) : .secondary)
                }
            }
            .foregroundStyle(hovering ? .white : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Colours

private struct ColoursPane: View {
    @Bindable var settings: SettingsStore
    let controller: TintController

    var body: some View {
        Pane {
            Section {
                ColourRow(title: "Daytime", subtitle: "While the sun is up",
                          value: $settings.schedule.dayKelvin, range: 4000...6500, controller: controller)
                ColourRow(title: "Sunset", subtitle: "After the sun goes down",
                          value: $settings.schedule.eveningKelvin, range: 1200...6500, controller: controller)
                ColourRow(title: "Bedtime",
                          subtitle: settings.schedule.bedtimeEnabled ? "From bedtime until you wake up" : "Bedtime mode is off",
                          value: $settings.schedule.bedtimeKelvin, range: 1200...6500, controller: controller)
                    .disabled(!settings.schedule.bedtimeEnabled)
            } footer: {
                HStack {
                    Text("Drag a slider to preview the colour on screen.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") {
                        let d = ScheduleSettings()
                        settings.schedule.dayKelvin = d.dayKelvin
                        settings.schedule.eveningKelvin = d.eveningKelvin
                        settings.schedule.bedtimeKelvin = d.bedtimeKelvin
                    }
                }
            }
        }
    }
}

private struct ColourRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let controller: TintController
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TintSwatch(kelvin: isEnabled ? value : ColorTemperature.neutral, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(value)) K")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            // Continuous slider (a stepped one draws dozens of tick marks), rounded to 50 K.
            Slider(value: Binding(get: { value }, set: { value = ($0 / 50).rounded() * 50 }), in: range) {
                Text(title)
            } minimumValueLabel: {
                Text("Warmer").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Cooler").font(.caption).foregroundStyle(.secondary)
            } onEditingChanged: { editing in
                // Show the real tint while dragging, then fade back to the schedule.
                controller.previewKelvin = editing ? value : nil
            }
            .labelsHidden()
            .onChange(of: value) { _, new in
                if controller.previewKelvin != nil { controller.previewKelvin = new }
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var importMessage: String?

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)) {
                    Text("Launch at login")
                    if let loginError { Text(loginError).foregroundStyle(.red) }
                }
            }

            Section {
                if settings.excludedApps.isEmpty {
                    Text("No apps yet. While using an app, choose “Disable for …” from the menu bar icon to keep the screen untinted whenever it’s in front.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(settings.excludedApps) { app in
                        HStack(spacing: 10) {
                            AppIcon(bundleID: app.bundleID)
                            Text(app.name)
                            Spacer()
                            Button {
                                settings.excludedApps.removeAll { $0 == app }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Tint again while \(app.name) is in front")
                        }
                    }
                }
            } header: {
                Text("Never tint while using")
            }

            if FluxImport.isAvailable {
                Section {
                    LabeledContent {
                        Button("Import") {
                            if let imported = FluxImport.importedSettings(onto: settings.schedule) {
                                settings.locationName = nil
                                settings.schedule = imported
                                importMessage = "Imported."
                            } else {
                                importMessage = "No usable f.lux settings found."
                            }
                        }
                    } label: {
                        Text("Import from f.lux")
                        Text(importMessage ?? "Location, bedtime colour and wake time")
                    }
                }
            }

            Section {
                if NightShift.isAvailable {
                    Toggle(isOn: $settings.keepNightShiftOff) {
                        Text("Keep macOS Night Shift off")
                        Text("Night Shift tints on top of Nightshift, so with both on the screen gets far too warm.")
                    }
                } else {
                    Label {
                        Text("Turn off macOS Night Shift")
                        Text("If it’s on as well, both tints add up. System Settings → Displays → Night Shift.")
                    } icon: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

private struct AppIcon: View {
    let bundleID: String

    var body: some View {
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil)
            ?? NSImage()
        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
    }
}
