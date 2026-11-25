import AppKit
import NightshiftCore

/// Decides what colour temperature the screen should have right now and drives the
/// gamma tables there smoothly. Also re-asserts the tint whenever macOS is likely to
/// have reset it (wake, display changes, user switching, profile changes).
@MainActor
final class TintController {
    enum Status {
        case schedule(ScheduleState)
        case disabled
        case paused(until: Date)
        case excluded(appName: String)
        case preview
    }

    let settings: SettingsStore
    private let gamma = GammaController()

    private(set) var displayedKelvin = ColorTemperature.neutral
    private(set) var pausedUntil: Date?

    var isDisabled = false {
        didSet { update() }
    }

    /// Live preview while dragging a slider in settings.
    var previewKelvin: Double? {
        didSet { update(animated: previewKelvin == nil) }
    }

    var onStateChange: (() -> Void)?

    private struct Animation {
        var fromMired: Double
        var toMired: Double
        var start: Date
        var duration: TimeInterval
    }

    private var animation: Animation?
    private var animationTimer: Timer?
    private var tickTimer: Timer?
    private var displaySyncWork: DispatchWorkItem?
    private var lastRecapture = Date.distantPast
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    init(settings: SettingsStore) {
        self.settings = settings
    }

    var schedule: Schedule {
        Schedule(settings: settings.schedule, calendar: .autoupdatingCurrent)
    }

    var unsupportedDisplayCount: Int { gamma.unsupportedDisplays.count }

    // MARK: - Lifecycle

    func start() {
        gamma.resetAndCapture()
        lastRecapture = .now
        displayedKelvin = ColorTemperature.neutral
        installObservers()

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 3
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        enforceNightShiftSetting()
        update() // fades in from neutral
    }

    func stop() {
        tickTimer?.invalidate()
        animationTimer?.invalidate()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        gamma.restore()
    }

    // MARK: - Commands

    func pause(for interval: TimeInterval) {
        pausedUntil = Date.now + interval
        update()
    }

    func pauseUntilDaylight() {
        guard let until = schedule.nextFullDaylight(after: .now) else { return }
        pausedUntil = until
        update()
    }

    func resume() {
        pausedUntil = nil
        if isDisabled { isDisabled = false } else { update() }
    }

    // MARK: - State

    func status(at now: Date = .now) -> Status {
        if previewKelvin != nil { return .preview }
        if isDisabled { return .disabled }
        if let until = pausedUntil, until > now { return .paused(until: until) }
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, settings.isExcluded(id) {
            return .excluded(appName: app.localizedName ?? id)
        }
        return .schedule(schedule.state(at: now))
    }

    private func targetKelvin(for status: Status) -> Double {
        switch status {
        case .preview: previewKelvin ?? ColorTemperature.neutral
        case let .schedule(state): state.kelvin
        case .disabled, .paused, .excluded: ColorTemperature.neutral
        }
    }

    /// Recomputes the target and moves towards it. Small steps (the normal minute-by-
    /// minute schedule drift) are applied directly; big jumps are faded.
    func update(animated: Bool = true) {
        if let until = pausedUntil, until <= .now { pausedUntil = nil }
        let target = targetKelvin(for: status())
        let currentMired = ColorTemperature.mired(displayedKelvin)
        let targetMired = ColorTemperature.mired(target)

        if animated, abs(targetMired - currentMired) > 1.5 {
            animation = Animation(fromMired: currentMired, toMired: targetMired, start: .now, duration: 1.2)
            startAnimationTimer()
        } else {
            stopAnimation()
            show(kelvin: target)
        }
        onStateChange?()
    }

    private func show(kelvin: Double) {
        displayedKelvin = kelvin
        gamma.apply(ColorTemperature.gain(kelvin: kelvin))
    }

    private func tick() {
        // Re-applying every tick also repairs tables that macOS or another app reset.
        if animation == nil { update() }
        enforceNightShiftSetting()
    }

    /// Night Shift would stack on top of our tint; keep it off if the user asked us to.
    func enforceNightShiftSetting() {
        if settings.keepNightShiftOff { NightShift.turnOffIfNeeded() }
    }

    // MARK: - Animation

    private func startAnimationTimer() {
        guard animationTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimation() {
        animation = nil
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func stepAnimation() {
        guard let a = animation else { stopAnimation(); return }
        let p = min(Date.now.timeIntervalSince(a.start) / a.duration, 1)
        let eased = p * p * (3 - 2 * p)
        show(kelvin: ColorTemperature.kelvin(mired: a.fromMired + (a.toMired - a.fromMired) * eased))
        if p >= 1 { stopAnimation() }
    }

    // MARK: - System events

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let distributed = DistributedNotificationCenter.default()

        func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            observers.append((center, token))
        }

        // macOS resets gamma tables on wake and when switching users.
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            observe(workspace, name) { [weak self] in self?.scheduleDisplaySync(recapture: false) }
        }
        observe(workspace, NSWorkspace.didActivateApplicationNotification) { [weak self] in self?.update() }
        observe(local, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.scheduleDisplaySync(recapture: false)
        }
        // Timezone / clock changes (travel, DST, NTP corrections).
        observe(local, .NSSystemTimeZoneDidChange) { [weak self] in self?.update() }
        observe(local, .NSSystemClockDidChange) { [weak self] in self?.update() }
        // New ColorSync profile → the curve we multiply onto has changed.
        // Value of kColorSyncDisplayDeviceProfilesNotification (that global isn't
        // concurrency-safe to read from Swift 6).
        let profileChanged = Notification.Name("com.apple.ColorSync.DisplayProfileNotification")
        observe(distributed, profileChanged) { [weak self] in self?.scheduleDisplaySync(recapture: true) }
    }

    /// Debounced: display reconfiguration fires a burst of notifications.
    private func scheduleDisplaySync(recapture: Bool) {
        displaySyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Our own restore can echo back as a profile notification; ignore it.
                if recapture, Date.now.timeIntervalSince(self.lastRecapture) > 3 {
                    self.gamma.resetAndCapture()
                    self.lastRecapture = .now
                } else {
                    self.gamma.syncDisplays()
                }
                self.show(kelvin: self.displayedKelvin)
                self.update()
            }
        }
        displaySyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }
}
