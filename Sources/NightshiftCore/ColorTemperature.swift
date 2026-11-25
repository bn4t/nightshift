import Foundation

/// Per-channel multipliers for the display transfer table, in display-encoded space.
public struct RGBGain: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let identity = RGBGain(red: 1, green: 1, blue: 1)
}

/// Converts a colour temperature to RGB gains by integrating Planck's law against the
/// CIE 1931 observer (analytic fit by Wyman, Sloan & Shirley 2013), converting to
/// linear sRGB, normalising so 6500 K is exactly neutral, then sRGB-encoding the
/// result so it can multiply the (encoded) gamma ramp directly.
public enum ColorTemperature {
    public static let neutral: Double = 6500
    public static let supportedRange: ClosedRange<Double> = 1000...10000

    public static func mired(_ kelvin: Double) -> Double { 1_000_000 / kelvin }
    public static func kelvin(mired: Double) -> Double { 1_000_000 / mired }

    public static func clamp(_ kelvin: Double) -> Double {
        guard kelvin.isFinite else { return neutral }
        return min(max(kelvin, supportedRange.lowerBound), supportedRange.upperBound)
    }

    public static func gain(kelvin: Double) -> RGBGain {
        let t = clamp(kelvin)
        if abs(t - neutral) < 0.5 { return .identity }
        let c = linearRGB(t)
        var r = max(c.r / neutralRGB.r, 0)
        var g = max(c.g / neutralRGB.g, 0)
        var b = max(c.b / neutralRGB.b, 0)
        let peak = max(r, g, b)
        guard peak > 0 else { return .identity }
        r /= peak; g /= peak; b /= peak
        return RGBGain(red: srgbEncode(r), green: srgbEncode(g), blue: srgbEncode(b))
    }

    // MARK: - Internals

    struct Linear: Sendable { var r, g, b: Double }

    static let neutralRGB = linearRGB(neutral)

    static func linearRGB(_ kelvin: Double) -> Linear {
        var x = 0.0, y = 0.0, z = 0.0
        var nm = 380.0
        while nm <= 780 {
            let p = planck(nm: nm, kelvin: kelvin)
            x += p * xBar(nm)
            y += p * yBar(nm)
            z += p * zBar(nm)
            nm += 1
        }
        x /= y; z /= y; y = 1
        return Linear(
            r: 3.2406 * x - 1.5372 * y - 0.4986 * z,
            g: -0.9689 * x + 1.8758 * y + 0.0415 * z,
            b: 0.0557 * x - 0.2040 * y + 1.0570 * z
        )
    }

    /// Relative spectral radiance (constant factors dropped).
    static func planck(nm: Double, kelvin: Double) -> Double {
        let lambda = nm * 1e-9
        return 1 / (pow(lambda, 5) * expm1(0.014387769 / (lambda * kelvin)))
    }

    private static func lobe(_ x: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
        let t = (x - mu) / (x < mu ? s1 : s2)
        return exp(-0.5 * t * t)
    }

    static func xBar(_ x: Double) -> Double {
        1.056 * lobe(x, 599.8, 37.9, 31.0) + 0.362 * lobe(x, 442.0, 16.0, 26.7) - 0.065 * lobe(x, 501.1, 20.4, 26.2)
    }

    static func yBar(_ x: Double) -> Double {
        0.821 * lobe(x, 568.8, 46.9, 40.5) + 0.286 * lobe(x, 530.9, 16.3, 31.1)
    }

    static func zBar(_ x: Double) -> Double {
        1.217 * lobe(x, 437.0, 11.8, 36.0) + 0.681 * lobe(x, 459.0, 26.0, 13.8)
    }

    static func srgbEncode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        if c >= 1 { return 1 }
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

public enum GammaMath {
    /// Scales a transfer table channel, preserving whatever calibration curve it held.
    public static func scale(_ table: [Float], by gain: Double) -> [Float] {
        let g = Float(gain.isFinite ? min(max(gain, 0), 1) : 1)
        return table.map { min(max($0 * g, 0), 1) }
    }
}
