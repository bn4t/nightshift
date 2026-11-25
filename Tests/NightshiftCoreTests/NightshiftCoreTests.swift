import Foundation
import Testing
@testable import NightshiftCore

private let berlin = Coordinate(latitude: 52.52, longitude: 13.40)

private func calendar(_ tz: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}

private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ cal: Calendar) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func minutes(_ a: Date, _ b: Date) -> Double { abs(a.timeIntervalSince(b)) / 60 }

@Suite struct SolarTests {
    @Test func berlinWinterSolstice() throws {
        let cal = calendar("Europe/Berlin")
        guard case let .normal(rise, set) = SolarCalculator.solarDay(for: at(2026, 12, 21, 9, 0, cal), at: berlin, calendar: cal) else {
            Issue.record("expected sunrise/sunset"); return
        }
        let noon = rise + set.timeIntervalSince(rise) / 2
        #expect(minutes(noon, at(2026, 12, 21, 12, 5, cal)) < 5)
        let length = set.timeIntervalSince(rise) / 3600
        #expect(length > 7.4 && length < 7.9)
        #expect(cal.isDate(rise, inSameDayAs: at(2026, 12, 21, 12, 0, cal)))
    }

    @Test func berlinSummerSolstice() {
        let cal = calendar("Europe/Berlin")
        guard case let .normal(rise, set) = SolarCalculator.solarDay(for: at(2026, 6, 21, 23, 0, cal), at: berlin, calendar: cal) else {
            Issue.record("expected sunrise/sunset"); return
        }
        let noon = rise + set.timeIntervalSince(rise) / 2
        #expect(minutes(noon, at(2026, 6, 21, 13, 8, cal)) < 5)
        let length = set.timeIntervalSince(rise) / 3600
        #expect(length > 16.6 && length < 17.1)
    }

    @Test func polarDayAndNight() {
        let cal = calendar("Europe/Oslo")
        let tromso = Coordinate(latitude: 69.65, longitude: 18.96)
        #expect(SolarCalculator.solarDay(for: at(2026, 12, 21, 12, 0, cal), at: tromso, calendar: cal) == .polarNight)
        #expect(SolarCalculator.solarDay(for: at(2026, 6, 21, 12, 0, cal), at: tromso, calendar: cal) == .polarDay)
    }

    @Test func southernHemisphere() {
        let cal = calendar("Australia/Sydney")
        let sydney = Coordinate(latitude: -33.87, longitude: 151.21)
        guard case let .normal(rise, set) = SolarCalculator.solarDay(for: at(2026, 12, 21, 12, 0, cal), at: sydney, calendar: cal) else {
            Issue.record("expected sunrise/sunset"); return
        }
        let length = set.timeIntervalSince(rise) / 3600
        #expect(length > 14.1 && length < 14.7)
    }

    @Test func farFromTimezoneMeridianStaysOnSameLocalDay() {
        let cal = calendar("Pacific/Auckland")
        let auckland = Coordinate(latitude: -36.85, longitude: 174.76)
        let day = at(2026, 1, 10, 12, 0, cal)
        guard case let .normal(rise, set) = SolarCalculator.solarDay(for: day, at: auckland, calendar: cal) else {
            Issue.record("expected sunrise/sunset"); return
        }
        #expect(cal.isDate(rise, inSameDayAs: day))
        #expect(cal.isDate(set, inSameDayAs: day))
        #expect(rise < set)
    }

    @Test func parsesCoordinates() {
        #expect(Coordinate(parsing: "52.520000,13.400000") == Coordinate(latitude: 52.52, longitude: 13.4))
        #expect(Coordinate(parsing: " -33.9 ,  151.2 ") == Coordinate(latitude: -33.9, longitude: 151.2))
        #expect(Coordinate(parsing: "91,0") == nil)
        #expect(Coordinate(parsing: "abc") == nil)
    }
}

@Suite struct ColorTests {
    @Test func neutralIsIdentity() {
        #expect(ColorTemperature.gain(kelvin: 6500) == .identity)
    }

    @Test func warmTemperaturesReduceBlueMost() {
        for k in stride(from: 1000.0, to: 6500, by: 250) {
            let g = ColorTemperature.gain(kelvin: k)
            #expect(g.red == 1)
            #expect(g.green <= 1 && g.blue <= g.green && g.blue >= 0, "at \(k) K: \(g)")
        }
    }

    @Test func blueIsMonotonic() {
        var previous = 0.0
        for k in stride(from: 1000.0, through: 6500, by: 100) {
            let b = ColorTemperature.gain(kelvin: k).blue
            #expect(b >= previous - 1e-9)
            previous = b
        }
    }

    @Test func coolTemperaturesReduceRed() {
        let g = ColorTemperature.gain(kelvin: 9000)
        #expect(g.blue == 1 && g.red < 1)
    }

    @Test func invalidInputIsSafe() {
        #expect(ColorTemperature.gain(kelvin: .nan) == .identity)
        let g = ColorTemperature.gain(kelvin: -5)
        #expect(g.red.isFinite && g.green.isFinite && g.blue.isFinite)
    }

    @Test func gammaScalingClamps() {
        #expect(GammaMath.scale([0, 0.5, 1], by: 0.5) == [0, 0.25, 0.5])
        #expect(GammaMath.scale([0.2, 1], by: 3) == [0.2, 1])
        #expect(GammaMath.scale([0.2, 1], by: .nan) == [0.2, 1])
    }
}

@Suite struct ScheduleTests {
    let cal = calendar("Europe/Berlin")
    var schedule: Schedule { Schedule(settings: ScheduleSettings(coordinate: berlin), calendar: cal) }

    @Test func middayIsDaylight() {
        let s = schedule.state(at: at(2026, 6, 21, 13, 0, cal))
        #expect(s.phase == .day)
        #expect(abs(s.kelvin - 6500) < 1)
    }

    @Test func eveningAfterSunset() {
        let s = schedule.state(at: at(2026, 12, 21, 20, 0, cal))
        #expect(s.phase == .evening)
        #expect(abs(s.kelvin - 3400) < 1)
    }

    @Test func bedtime() {
        let s = schedule.state(at: at(2026, 12, 22, 2, 0, cal))
        #expect(s.phase == .bedtime)
        #expect(abs(s.kelvin - 2300) < 1)
    }

    @Test func wakingBeforeSunriseStaysWarmButLeavesBedtime() {
        let s = schedule.state(at: at(2026, 12, 21, 7, 30, cal))
        #expect(s.phase == .evening)
        #expect(abs(s.kelvin - 3400) < 1)
    }

    @Test func bedtimeDisabled() {
        var settings = ScheduleSettings(coordinate: berlin)
        settings.bedtimeEnabled = false
        let s = Schedule(settings: settings, calendar: cal).state(at: at(2026, 12, 22, 2, 0, cal))
        #expect(abs(s.kelvin - 3400) < 1)
    }

    @Test func bedtimeAfterMidnight() {
        var settings = ScheduleSettings(coordinate: berlin)
        settings.bedtimeMinutes = 60
        settings.wakeMinutes = 9 * 60
        let sch = Schedule(settings: settings, calendar: cal)
        #expect(sch.state(at: at(2026, 12, 21, 23, 0, cal)).phase == .evening)
        #expect(sch.state(at: at(2026, 12, 22, 3, 0, cal)).phase == .bedtime)
    }

    @Test func bedtimeNeverMakesScreenCooler() {
        var settings = ScheduleSettings(coordinate: berlin)
        settings.bedtimeKelvin = 5000
        settings.eveningKelvin = 2000
        let s = Schedule(settings: settings, calendar: cal).state(at: at(2026, 12, 22, 2, 0, cal))
        #expect(abs(s.kelvin - 2000) < 1)
    }

    @Test(arguments: [
        (2026, 3, 29), // spring-forward
        (2026, 10, 25), // fall-back
        (2026, 6, 21),
        (2026, 12, 21),
    ])
    func continuousAcrossTheDay(y: Int, m: Int, d: Int) {
        var probe = at(y, m, d, 0, 0, cal) - 3600
        let end = probe + 26 * 3600
        var previous = ColorTemperature.mired(schedule.state(at: probe).kelvin)
        while probe < end {
            probe += 60
            let current = ColorTemperature.mired(schedule.state(at: probe).kelvin)
            // Steepest legitimate slope: smoothstep peak (1.5) × bedtime→day span
            // (435 − 154 mired) over a 60 min fade ≈ 7 mired/min. Anything above is a jump.
            #expect(abs(current - previous) < 8, "jump at \(probe)")
            previous = current
        }
    }

    @Test func polarNightNeverReachesDaylight() {
        let oslo = calendar("Europe/Oslo")
        let sch = Schedule(settings: ScheduleSettings(coordinate: Coordinate(latitude: 78.2, longitude: 15.6)), calendar: oslo)
        let noon = at(2026, 12, 21, 12, 0, oslo)
        #expect(sch.state(at: noon).phase == .evening)
        #expect(sch.nextFullDaylight(after: noon) == nil)
    }

    @Test func polarDayStillHonoursBedtime() {
        let oslo = calendar("Europe/Oslo")
        let sch = Schedule(settings: ScheduleSettings(coordinate: Coordinate(latitude: 78.2, longitude: 15.6)), calendar: oslo)
        #expect(sch.state(at: at(2026, 6, 21, 12, 0, oslo)).phase == .day)
        #expect(sch.state(at: at(2026, 6, 21, 2, 0, oslo)).phase == .bedtime)
    }

    @Test func upcomingEventsAreSorted() {
        let events = schedule.upcomingEvents(after: at(2026, 12, 21, 12, 0, cal))
        #expect(events.map(\.kind) == [.sunset, .bedtime, .wake, .sunrise])
        #expect(events.map(\.date) == events.map(\.date).sorted())
    }

    @Test func nextDaylightIsTomorrowMorning() throws {
        let next = try #require(schedule.nextFullDaylight(after: at(2026, 12, 21, 20, 0, cal)))
        #expect(cal.component(.day, from: next) == 22)
        let hour = cal.component(.hour, from: next)
        #expect(hour == 8 || hour == 9)
    }

    @Test func sanitizesGarbage() {
        var s = ScheduleSettings(coordinate: Coordinate(latitude: 200, longitude: .nan))
        s.wakeMinutes = -30
        s.transitionMinutes = .infinity
        s.dayKelvin = 50
        let clean = s.sanitized()
        #expect(clean.coordinate == Coordinate(latitude: 90, longitude: 0))
        #expect(clean.wakeMinutes == 1410)
        #expect(clean.transitionMinutes == 60)
        #expect(clean.dayKelvin == 1000)
    }

    @Test func decodesPartialSettings() throws {
        let json = #"{"dayKelvin": 6000}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(ScheduleSettings.self, from: json)
        #expect(s.dayKelvin == 6000)
        #expect(s.eveningKelvin == 3400)
    }
}
