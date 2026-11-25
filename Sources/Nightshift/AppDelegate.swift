import AppKit
import NightshiftCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = SettingsStore()
    private lazy var controller = TintController(settings: settings)
    private lazy var settingsWindow = SettingsWindowController(settings: settings, controller: controller)
    private var menu: StatusMenuController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two instances would fight over the gamma tables.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }

        var firstRun = false
        if !settings.hasLaunchedBefore {
            firstRun = true
            if let imported = FluxImport.importedSettings(onto: settings.schedule) {
                settings.schedule = imported
            }
            settings.hasLaunchedBefore = true
        }

        NSApp.mainMenu = MainMenu.make { [weak self] in self?.settingsWindow.show() }
        controller.start()
        let menu = StatusMenuController(controller: controller) { [weak self] in self?.settingsWindow.show() }
        self.menu = menu
        controller.onStateChange = { [weak menu] in menu?.refresh() }
        settings.onChange = { [weak self] in
            self?.controller.enforceNightShiftSetting()
            self?.controller.update()
        }

        installSignalHandlers()

        #if DEBUG
        // Test hook: open Settings the way the menu does, without a LaunchServices reopen
        // (which would activate the app for us and hide focus bugs).
        DistributedNotificationCenter.default().addObserver(
            forName: .init("dev.nightshift.debug.showSettings"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsWindow.show() }
        }
        #endif
        if firstRun { settingsWindow.show() }
    }

    /// Opening the app again (Finder, Spotlight, `open`) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// `kill`, Ctrl-C and logout should leave the screen neutral, not tinted.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
