import Foundation

public struct ScheduleSettings: Codable, Sendable, Equatable {
    public var coordinate: Coordinate
    public var dayKelvin: Double
    public var eveningKelvin: Double
    public var bedtimeEnabled: Bool
    public var bedtimeKelvin: Double
    /// Minutes after local midnight.
    public var bedtimeMinutes: Int
    /// Minutes after local midnight.
    public var wakeMinutes: Int
    /// Length of each sunrise/sunset/bedtime fade.
    public var transitionMinutes: Double

    public init(
        coordinate: Coordinate = ScheduleSettings.guessedCoordinate(),
        dayKelvin: Double = 6500,
        eveningKelvin: Double = 3400,
        bedtimeEnabled: Bool = true,
        bedtimeKelvin: Double = 2300,
        bedtimeMinutes: Int = 23 * 60,
        wakeMinutes: Int = 7 * 60,
        transitionMinutes: Double = 60
    ) {
        self.coordinate = coordinate
        self.dayKelvin = dayKelvin
        self.eveningKelvin = eveningKelvin
        self.bedtimeEnabled = bedtimeEnabled
        self.bedtimeKelvin = bedtimeKelvin
        self.bedtimeMinutes = bedtimeMinutes
        self.wakeMinutes = wakeMinutes
        self.transitionMinutes = transitionMinutes
    }

    // Tolerant decoding: a missing or newly added key falls back to its default
    // instead of throwing away every saved setting.
    public init(from decoder: Decoder) throws {
        let d = ScheduleSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coordinate = (try? c.decode(Coordinate.self, forKey: .coordinate)) ?? d.coordinate
        dayKelvin = (try? c.decode(Double.self, forKey: .dayKelvin)) ?? d.dayKelvin
        eveningKelvin = (try? c.decode(Double.self, forKey: .eveningKelvin)) ?? d.eveningKelvin
        bedtimeEnabled = (try? c.decode(Bool.self, forKey: .bedtimeEnabled)) ?? d.bedtimeEnabled
        bedtimeKelvin = (try? c.decode(Double.self, forKey: .bedtimeKelvin)) ?? d.bedtimeKelvin
        bedtimeMinutes = (try? c.decode(Int.self, forKey: .bedtimeMinutes)) ?? d.bedtimeMinutes
        wakeMinutes = (try? c.decode(Int.self, forKey: .wakeMinutes)) ?? d.wakeMinutes
        transitionMinutes = (try? c.decode(Double.self, forKey: .transitionMinutes)) ?? d.transitionMinutes
    }

    public func sanitized() -> ScheduleSettings {
        var s = self
        s.coordinate = coordinate.clamped()
        s.dayKelvin = ColorTemperature.clamp(dayKelvin)
        s.eveningKelvin = ColorTemperature.clamp(eveningKelvin)
        s.bedtimeKelvin = ColorTemperature.clamp(bedtimeKelvin)
        s.bedtimeMinutes = Self.wrapMinutes(bedtimeMinutes)
        s.wakeMinutes = Self.wrapMinutes(wakeMinutes)
        s.transitionMinutes = transitionMinutes.isFinite ? min(max(transitionMinutes, 0), 180) : 60
        return s
    }

    public static func wrapMinutes(_ m: Int) -> Int { ((m % 1440) + 1440) % 1440 }

    /// Rough first-run default: longitude from the UTC offset, a mid-northern latitude.
    /// The settings window asks the user to set a real location on first launch.
    public static func guessedCoordinate(timeZone: TimeZone = .current) -> Coordinate {
        let lon = Double(timeZone.secondsFromGMT() - Int(timeZone.daylightSavingTimeOffset())) / 240
        return Coordinate(latitude: 45, longitude: min(max(lon, -180), 180))
    }
}

public enum Phase: String, Sendable, Equatable {
    case day, sunrise, sunset, evening, bedtime
}

public struct ScheduleState: Sendable, Equatable {
    public var kelvin: Double
    public var phase: Phase
    /// 0 = sun down, 1 = full daylight.
    public var daylight: Double
    /// 0 = awake, 1 = full bedtime.
    public var bedtime: Double
}

public struct ScheduleEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case sunrise, sunset, bedtime, wake }
    public var kind: Kind
    public var date: Date
}

public struct Schedule: Sendable {
    public let settings: ScheduleSettings
    public let calendar: Calendar

    public init(settings: ScheduleSettings, calendar: Calendar = .current) {
        self.settings = settings.sanitized()
        self.calendar = calendar
    }

    private var transition: TimeInterval { settings.transitionMinutes * 60 }

    public func solarDay(for date: Date) -> SolarDay {
        SolarCalculator.solarDay(for: date, at: settings.coordinate, calendar: calendar)
    }

    /// Daylight factor with fades centred on sunrise and sunset. Looks at the previous
    /// and next calendar days too, so fades that cross midnight (high latitudes) work.
    public func daylightFactor(at t: Date) -> Double {
        let half = transition / 2
        var best = 0.0
        for offset in -1...1 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: t) else { continue }
            let f: Double
            switch solarDay(for: day) {
            case .polarDay:
                let start = calendar.startOfDay(for: day)
                let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start + 86_400
                f = (start..<end).contains(t) ? 1 : 0
            case .polarNight:
                f = 0
            case let .normal(sunrise, sunset):
                f = ramp(t, sunrise - half, sunrise + half) * (1 - ramp(t, sunset - half, sunset + half))
            }
            best = max(best, f)
        }
        return best
    }

    /// Bedtime factor: fades in over the transition ending at bedtime, fades out over
    /// the transition ending at wake time, so the screen is normal when you get up.
    public func bedtimeFactor(at t: Date) -> Double {
        guard settings.bedtimeEnabled else { return 0 }
        let fade = max(transition, 60)
        var best = 0.0
        for (bed, wake) in sleepWindows(around: t) {
            best = max(best, ramp(t, bed - fade, bed) * (1 - ramp(t, wake - fade, wake)))
        }
        return best
    }

    public func state(at t: Date) -> ScheduleState {
        let d = daylightFactor(at: t)
        let n = bedtimeFactor(at: t)
        let dayM = ColorTemperature.mired(settings.dayKelvin)
        let eveningM = ColorTemperature.mired(settings.eveningKelvin)
        let nightM = ColorTemperature.mired(settings.bedtimeKelvin)

        // Interpolate in mireds: perceptually even steps.
        let solarM = eveningM + (dayM - eveningM) * d
        // Bedtime can only make the screen warmer, never cooler.
        let m = solarM + (max(solarM, nightM) - solarM) * n

        let phase: Phase
        if n >= 0.5 && nightM > solarM + 0.5 {
            phase = .bedtime
        } else if d >= 0.999 {
            phase = .day
        } else if d <= 0.001 {
            phase = .evening
        } else {
            phase = daylightFactor(at: t + 60) >= d ? .sunrise : .sunset
        }
        return ScheduleState(kelvin: ColorTemperature.kelvin(mired: m), phase: phase, daylight: d, bedtime: n)
    }

    public func upcomingEvents(after t: Date, within horizon: TimeInterval = 86_400) -> [ScheduleEvent] {
        var events: [ScheduleEvent] = []
        for offset in 0...2 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: t) else { continue }
            if case let .normal(sunrise, sunset) = solarDay(for: day) {
                events.append(.init(kind: .sunrise, date: sunrise))
                events.append(.init(kind: .sunset, date: sunset))
            }
        }
        if settings.bedtimeEnabled {
            for (bed, wake) in sleepWindows(around: t, days: 0...2) {
                events.append(.init(kind: .bedtime, date: bed))
                events.append(.init(kind: .wake, date: wake))
            }
        }
        var seen = Set<String>()
        return events
            .filter { $0.date > t && $0.date <= t + horizon }
            .sorted { $0.date < $1.date }
            .filter { seen.insert("\($0.kind)\(Int($0.date.timeIntervalSince1970 / 60))").inserted }
    }

    /// First moment after `t` with full daylight, or nil (polar night, > 48 h away).
    public func nextFullDaylight(after t: Date) -> Date? {
        var probe = t
        let end = t + 48 * 3600
        while probe < end {
            probe += 5 * 60
            if daylightFactor(at: probe) >= 0.999 && bedtimeFactor(at: probe) <= 0.001 { return probe }
        }
        return nil
    }

    public func samples(forDayContaining t: Date, stepMinutes: Int = 10) -> [(date: Date, kelvin: Double)] {
        let start = calendar.startOfDay(for: t)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        var out: [(Date, Double)] = []
        var probe = start
        while probe <= end {
            out.append((probe, state(at: probe).kelvin))
            probe += TimeInterval(stepMinutes * 60)
        }
        return out
    }

    // MARK: - Helpers

    private func sleepWindows(around t: Date, days: ClosedRange<Int> = -1...1) -> [(Date, Date)] {
        let today = calendar.startOfDay(for: t)
        var windows: [(Date, Date)] = []
        for offset in days {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let bed = time(settings.bedtimeMinutes, on: day) else { continue }
            let wakeDay = settings.wakeMinutes > settings.bedtimeMinutes
                ? day : (calendar.date(byAdding: .day, value: 1, to: day) ?? day)
            guard let wake = time(settings.wakeMinutes, on: wakeDay) else { continue }
            windows.append((bed, wake))
        }
        return windows
    }

    /// DST-safe "HH:MM on this day" (a skipped local time resolves to the next valid one).
    private func time(_ minutes: Int, on day: Date) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    private func ramp(_ t: Date, _ a: Date, _ b: Date) -> Double {
        let span = b.timeIntervalSince(a)
        guard span > 0 else { return t >= b ? 1 : 0 }
        let x = min(max(t.timeIntervalSince(a) / span, 0), 1)
        return x * x * (3 - 2 * x)
    }
}
