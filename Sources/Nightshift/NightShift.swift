import Foundation

/// Controls macOS Night Shift through CoreBrightness (private framework, the same one
/// behind the switch in System Settings). Night Shift tints on top of our gamma tables,
/// so with both on the screen ends up far warmer than intended.
///
/// Everything is looked up at runtime; if Apple changes the API this degrades to "not
/// available" instead of crashing.
@MainActor
enum NightShift {
    struct Status: Equatable {
        var enabled: Bool
        /// 0 = no schedule, 1 = sunset to sunrise, 2 = custom schedule.
        var mode: Int32
    }

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type
        else { return nil }
        return type.init()
    }()

    static var isAvailable: Bool { status != nil }

    static var status: Status? {
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let client, client.responds(to: selector) else { return nil }
        typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let call = unsafeBitCast(client.method(for: selector), to: GetStatus.self)
        // struct { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; … }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        guard call(client, selector, buffer) else { return nil }
        return Status(enabled: buffer.load(fromByteOffset: 1, as: Bool.self),
                      mode: buffer.load(fromByteOffset: 4, as: Int32.self))
    }

    /// Turns Night Shift off now and removes its schedule so it doesn't come back at
    /// sunset. No-op when it's already fully off.
    @discardableResult
    static func turnOffIfNeeded() -> Bool {
        guard let client, let current = status else { return false }
        guard current.enabled || current.mode != 0 else { return false }

        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Bool
        typealias SetInt = @convention(c) (AnyObject, Selector, Int32) -> Bool
        let setEnabled = NSSelectorFromString("setEnabled:")
        let setMode = NSSelectorFromString("setMode:")
        if client.responds(to: setMode) {
            _ = unsafeBitCast(client.method(for: setMode), to: SetInt.self)(client, setMode, 0)
        }
        if client.responds(to: setEnabled) {
            _ = unsafeBitCast(client.method(for: setEnabled), to: SetBool.self)(client, setEnabled, false)
        }
        return true
    }
}
