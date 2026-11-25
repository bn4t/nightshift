import CoreGraphics
import NightshiftCore

/// Owns the display transfer tables.
///
/// The table is multiplied on top of each display's *original* curve (its ColorSync
/// profile / calibration) instead of being replaced by a synthetic ramp, so calibrated
/// displays keep their calibration. Displays that refuse gamma tables (some DisplayLink,
/// AirPlay or Sidecar targets) are tracked instead of failing silently.
@MainActor
final class GammaController {
    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    private var originals: [CGDirectDisplayID: Table] = [:]
    private(set) var unsupportedDisplays: Set<CGDirectDisplayID> = []
    private(set) var lastGain: RGBGain?

    /// Restores every display to its ColorSync curve and re-reads the originals.
    /// Used at launch (clears a tint left by a crashed instance or another app) and when
    /// the ColorSync profile changes.
    func resetAndCapture() {
        CGDisplayRestoreColorSyncSettings()
        originals.removeAll()
        unsupportedDisplays.removeAll()
        syncDisplays()
    }

    /// Picks up newly attached displays and forgets removed ones, without a flash.
    func syncDisplays() {
        let online = Set(Self.onlineDisplays())
        originals = originals.filter { online.contains($0.key) }
        unsupportedDisplays.formIntersection(online)
        for id in online where originals[id] == nil && !unsupportedDisplays.contains(id) {
            if let table = Self.read(id) {
                originals[id] = table
            } else {
                unsupportedDisplays.insert(id)
            }
        }
    }

    func apply(_ gain: RGBGain) {
        syncDisplays()
        for (id, table) in originals {
            let r = GammaMath.scale(table.red, by: gain.red)
            let g = GammaMath.scale(table.green, by: gain.green)
            let b = GammaMath.scale(table.blue, by: gain.blue)
            if CGSetDisplayTransferByTable(id, UInt32(r.count), r, g, b) != .success {
                originals[id] = nil
                unsupportedDisplays.insert(id)
            }
        }
        lastGain = gain
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
        lastGain = nil
    }

    // MARK: - CoreGraphics plumbing

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    private static func read(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 1 else { return nil }
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &r, &g, &b, &count) == .success, count > 1 else {
            return nil
        }
        let n = Int(count)
        return Table(red: Array(r.prefix(n)), green: Array(g.prefix(n)), blue: Array(b.prefix(n)))
    }
}
