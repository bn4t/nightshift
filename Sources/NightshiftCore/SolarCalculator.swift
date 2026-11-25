import Foundation

public struct Coordinate: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }

    public func clamped() -> Coordinate {
        func fix(_ v: Double, _ limit: Double) -> Double { v.isFinite ? min(max(v, -limit), limit) : 0 }
        return Coordinate(latitude: fix(latitude, 90), longitude: fix(longitude, 180))
    }

    /// Parses "52.52,13.4" / "52.52, 13.4" / "52.52 13.4".
    public init?(parsing text: String) {
        let parts = text
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
            .compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let c = Coordinate(latitude: parts[0], longitude: parts[1])
        guard c.isValid else { return nil }
        self = c
    }
}

public enum SolarDay: Sendable, Equatable {
    case normal(sunrise: Date, sunset: Date)
    /// The sun never sets on this calendar day.
    case polarDay
    /// The sun never rises on this calendar day.
    case polarNight
}

/// Sunrise/sunset from the standard "sunrise equation" (NOAA-derived), accurate to
/// roughly a minute at non-polar latitudes. Runs fully offline.
public enum SolarCalculator {
    private static let j2000 = 2_451_545.0
    private static let unixEpochJulian = 2_440_587.5
    /// Standard refraction + solar disc radius.
    private static let horizonAltitude = -0.833

    public static func solarDay(for date: Date, at coordinate: Coordinate, calendar: Calendar) -> SolarDay {
        let c = coordinate.clamped()
        var comps = calendar.dateComponents([.year, .month, .day], from: date)
        comps.hour = 12
        let localNoon = calendar.date(from: comps) ?? date
        let julianNoon = localNoon.timeIntervalSince1970 / 86_400 + unixEpochJulian

        // Pick the solar transit that falls on this local calendar day, also for
        // locations far from their timezone meridian (e.g. lon 175°E at UTC+13).
        let n = (julianNoon - j2000 + c.longitude / 360).rounded()
        let meanSolarTime = n - c.longitude / 360

        let meanAnomaly = normalize(357.5291 + 0.98560028 * meanSolarTime)
        let m = radians(meanAnomaly)
        let center = 1.9148 * sin(m) + 0.0200 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitude = radians(normalize(meanAnomaly + center + 180 + 102.9372))
        let transit = j2000 + meanSolarTime + 0.0053 * sin(m) - 0.0069 * sin(2 * eclipticLongitude)

        let sinDeclination = sin(eclipticLongitude) * sin(radians(23.4397))
        let cosDeclination = cos(asin(sinDeclination))
        let phi = radians(c.latitude)
        let cosHourAngle = (sin(radians(horizonAltitude)) - sin(phi) * sinDeclination)
            / (cos(phi) * cosDeclination)

        if cosHourAngle.isNaN { return .polarNight }
        if cosHourAngle <= -1 { return .polarDay }
        if cosHourAngle >= 1 { return .polarNight }

        let hourAngle = acos(cosHourAngle) * 180 / .pi
        return .normal(
            sunrise: dateFromJulian(transit - hourAngle / 360),
            sunset: dateFromJulian(transit + hourAngle / 360)
        )
    }

    private static func dateFromJulian(_ jd: Double) -> Date {
        Date(timeIntervalSince1970: (jd - unixEpochJulian) * 86_400)
    }

    private static func normalize(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
}
