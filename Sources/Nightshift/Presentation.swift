import NightshiftCore
import SwiftUI

// Shared wording/visuals for the menu and the settings window.

extension Phase {
    var title: String {
        switch self {
        case .day: "Daylight"
        case .sunrise: "Sunrise"
        case .sunset: "Sunset"
        case .evening: "Evening"
        case .bedtime: "Bedtime"
        }
    }

    var symbol: String {
        switch self {
        case .day: "sun.max"
        case .sunrise: "sunrise"
        case .sunset: "sunset"
        case .evening: "moon"
        case .bedtime: "moon.zzz"
        }
    }
}

extension ScheduleEvent.Kind {
    var title: String {
        switch self {
        case .sunrise: "Sunrise"
        case .sunset: "Sunset"
        case .bedtime: "Bedtime"
        case .wake: "Wake"
        }
    }
}

extension TintController.Status {
    var title: String {
        switch self {
        case .disabled: "Disabled"
        case let .paused(until): "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        case let .excluded(name): "Off while using \(name)"
        case .preview: "Preview"
        case let .schedule(state): state.phase.title
        }
    }
}

extension Coordinate {
    var formatted: String {
        let lat = String(format: "%.2f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.2f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
        return "\(lat), \(lon)"
    }
}

extension Color {
    /// The colour pure white becomes at this temperature.
    init(kelvin: Double) {
        let g = ColorTemperature.gain(kelvin: kelvin)
        self.init(.sRGB, red: g.red, green: g.green, blue: g.blue)
    }
}

struct TintSwatch: View {
    let kelvin: Double
    var size: CGFloat = 22

    var body: some View {
        Circle()
            .fill(Color(kelvin: kelvin))
            .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
            .frame(width: size, height: size)
            .shadow(color: Color(kelvin: kelvin).opacity(0.5), radius: size / 5)
    }
}
