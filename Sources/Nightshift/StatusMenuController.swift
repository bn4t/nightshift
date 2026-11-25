import AppKit
import NightshiftCore

/// NSMenuItem with a closure instead of target/selector plumbing.
@MainActor
final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, key: String = "", state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        self.target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let controller: TintController
    private let openSettings: () -> Void
    private let menu = NSMenu()

    init(controller: TintController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refresh()
    }

    func refresh() {
        let (symbol, description) = switch controller.status() {
        case .disabled, .paused, .excluded: ("pause.circle", "Nightshift is off")
        case .preview: ("eye", "Previewing")
        case let .schedule(state): (state.phase.symbol, state.phase.title)
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Nightshift — \(description), \(Int(controller.displayedKelvin.rounded())) K"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let schedule = controller.schedule
        let now = Date.now
        let status = controller.status(at: now)

        menu.addItem(info(headline(for: status, schedule: schedule)))
        for event in schedule.upcomingEvents(after: now).prefix(2) {
            menu.addItem(info("\(event.kind.title) at \(event.date.formatted(date: .omitted, time: .shortened))"))
        }
        if case .polarNight = schedule.solarDay(for: now) { menu.addItem(info("Polar night — no sunrise today")) }
        if case .polarDay = schedule.solarDay(for: now) { menu.addItem(info("Midnight sun — no sunset today")) }

        addWarnings(to: menu)
        menu.addItem(.separator())

        let paused: Bool = switch status {
        case .paused, .disabled: true
        default: false
        }
        if paused {
            menu.addItem(ActionMenuItem("Resume") { [controller] in controller.resume() })
        } else {
            menu.addItem(ActionMenuItem("Disable for an Hour") { [controller] in controller.pause(for: 3600) })
            if case let .schedule(state) = status, state.phase != .day,
               schedule.nextFullDaylight(after: now) != nil {
                menu.addItem(ActionMenuItem("Disable Until Morning") { [controller] in controller.pauseUntilDaylight() })
            }
        }
        menu.addItem(ActionMenuItem("Disabled", state: controller.isDisabled ? .on : .off) { [controller] in
            controller.isDisabled.toggle()
        })

        // The menu bar doesn't steal focus, so the frontmost app is still the one the
        // user was working in.
        if let app = NSWorkspace.shared.frontmostApplication,
           let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            let name = app.localizedName ?? id
            let excluded = controller.settings.isExcluded(id)
            menu.addItem(ActionMenuItem("Disable for \(name)", state: excluded ? .on : .off) { [controller] in
                controller.settings.toggleExclusion(bundleID: id, name: name)
            })
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem("Settings…", key: ",") { [openSettings] in openSettings() })
        menu.addItem(ActionMenuItem("Quit Nightshift", key: "q") { NSApp.terminate(nil) })
    }

    private func addWarnings(to menu: NSMenu) {
        let flux = NSRunningApplication.runningApplications(withBundleIdentifier: FluxImport.bundleID)
        if !flux.isEmpty {
            menu.addItem(.separator())
            menu.addItem(info("⚠️ f.lux is running — both apps fight over the screen tint"))
            menu.addItem(ActionMenuItem("Quit f.lux") { flux.forEach { $0.terminate() } })
        }
        let unsupported = controller.unsupportedDisplayCount
        if unsupported > 0 {
            menu.addItem(info("⚠️ \(unsupported) display\(unsupported == 1 ? "" : "s") can't be tinted (no gamma support)"))
        }
    }

    private func headline(for status: TintController.Status, schedule: Schedule) -> String {
        switch status {
        case .schedule, .preview: "\(status.title) · \(Int(controller.displayedKelvin.rounded())) K"
        default: status.title
        }
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
