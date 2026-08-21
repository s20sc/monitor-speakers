import AppKit
import ServiceManagement

/// Menu bar front-end: hosts the router engine in-process (replacing the
/// launchd agent) and exposes the config knobs as a status-item menu.
/// Every change is saved to the config file and applied by restarting the
/// engine, so the CLI and the app always agree on state.
final class MenuBarAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var supervisor: RouterSupervisor?
    private var switcher: AutoSwitcher?
    /// Engine start can block for minutes while a TCC microphone prompt is
    /// pending; keep that off the main thread so the status item always draws.
    private let engineQueue = DispatchQueue(label: "monitor-speakers.engine")

    private static let crossoverChoices: [Float] = [70, 80, 90, 100, 120, 150]
    private static let bassLevelChoices: [Float] = [0.5, 0.8, 1.0, 1.3, 1.6, 2.0]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "hifispeaker.2.fill", accessibilityDescription: "Monitor Speakers"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        startEngine()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engineQueue.sync { self.stopEngineLocked() }
    }

    // MARK: - Engine lifecycle (all mutations serialized on engineQueue)

    private func startEngine() {
        engineQueue.async { self.startEngineLocked() }
    }

    private func restartEngine() {
        engineQueue.async {
            self.stopEngineLocked()
            self.startEngineLocked()
        }
    }

    private func startEngineLocked() {
        let config = RouterConfig.load()
        let started = RouterSupervisor(config: config)
        started.start()
        supervisor = started
        if config.autoSwitch {
            let autoSwitcher = AutoSwitcher(config: config)
            autoSwitcher.start()
            switcher = autoSwitcher
        }
    }

    private func stopEngineLocked() {
        supervisor?.stop()
        supervisor = nil
        switcher?.stop()
        switcher = nil
    }

    private func mutateConfig(_ change: (inout RouterConfig) -> Void) {
        var config = RouterConfig.load()
        change(&config)
        do {
            try config.save()
        } catch {
            log("menubar: failed to save config: \(error)")
        }
        restartEngine()
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = RouterConfig.load()

        let status = NSMenuItem(
            title: supervisor?.statusText ?? "Stopped", action: nil, keyEquivalent: ""
        )
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        // Crossover frequency.
        let crossover = NSMenuItem(title: "Bass Crossover", action: nil, keyEquivalent: "")
        let crossoverMenu = NSMenu()
        for freq in Self.crossoverChoices {
            let item = NSMenuItem(
                title: "\(Int(freq)) Hz", action: #selector(selectCrossover(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(freq)
            item.state = abs(config.subFreq - freq) < 1 ? .on : .off
            crossoverMenu.addItem(item)
        }
        crossover.submenu = crossoverMenu
        menu.addItem(crossover)

        // Bass level.
        let bass = NSMenuItem(title: "Bass Level", action: nil, keyEquivalent: "")
        let bassMenu = NSMenu()
        for level in Self.bassLevelChoices {
            let item = NSMenuItem(
                title: String(format: "%.0f%%", level * 100),
                action: #selector(selectBassLevel(_:)), keyEquivalent: ""
            )
            item.target = self
            item.tag = Int(level * 100)
            item.state = abs(config.subTrim - level) < 0.01 ? .on : .off
            bassMenu.addItem(item)
        }
        bass.submenu = bassMenu
        menu.addItem(bass)

        let bassToggle = NSMenuItem(
            title: "Bass Speaker", action: #selector(toggleBass(_:)), keyEquivalent: ""
        )
        bassToggle.target = self
        bassToggle.state = config.subEnabled ? .on : .off
        menu.addItem(bassToggle)

        let centerToggle = NSMenuItem(
            title: "Center Monitor Stereo", action: #selector(toggleCenterStereo(_:)),
            keyEquivalent: ""
        )
        centerToggle.target = self
        centerToggle.state = config.centerStereo ? .on : .off
        menu.addItem(centerToggle)

        let autoSwitchToggle = NSMenuItem(
            title: "Auto-Switch Output", action: #selector(toggleAutoSwitch(_:)), keyEquivalent: ""
        )
        autoSwitchToggle.target = self
        autoSwitchToggle.state = config.autoSwitch ? .on : .off
        menu.addItem(autoSwitchToggle)

        menu.addItem(.separator())

        let rebuild = NSMenuItem(
            title: "Rebuild Aggregate (after re-cabling)", action: #selector(rebuildAggregate(_:)),
            keyEquivalent: ""
        )
        rebuild.target = self
        menu.addItem(rebuild)

        let openConfig = NSMenuItem(
            title: "Open Config File", action: #selector(openConfigFile(_:)), keyEquivalent: ""
        )
        openConfig.target = self
        menu.addItem(openConfig)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let quit = NSMenuItem(title: "Quit", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func selectCrossover(_ sender: NSMenuItem) {
        mutateConfig { $0.subFreq = Float(sender.tag) }
    }

    @objc private func selectBassLevel(_ sender: NSMenuItem) {
        mutateConfig { $0.subTrim = Float(sender.tag) / 100 }
    }

    @objc private func toggleBass(_ sender: NSMenuItem) {
        // Adding/removing the bass speaker changes the aggregate itself.
        var config = RouterConfig.load()
        config.subEnabled.toggle()
        try? config.save()
        rebuildAggregate(sender)
    }

    @objc private func toggleCenterStereo(_ sender: NSMenuItem) {
        mutateConfig { $0.centerStereo.toggle() }
    }

    @objc private func toggleAutoSwitch(_ sender: NSMenuItem) {
        mutateConfig { $0.autoSwitch.toggle() }
    }

    @objc private func rebuildAggregate(_ sender: NSMenuItem) {
        engineQueue.async {
            self.stopEngineLocked()
            var config = RouterConfig.load()
            do {
                for line in try setupAggregate(config: &config) { log("menubar: \(line)") }
            } catch {
                log("menubar: rebuild failed: \(error)")
                DispatchQueue.main.async {
                    self.showAlert(title: "Rebuild failed", text: "\(error)")
                }
            }
            self.startEngineLocked()
        }
    }

    @objc private func openConfigFile(_ sender: NSMenuItem) {
        NSWorkspace.shared.open(RouterConfig.fileURL)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            log("menubar: launch-at-login change failed: \(error)")
            showAlert(title: "Launch at Login failed", text: "\(error)")
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func showAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// Retained globally: NSApplication.delegate is a weak reference.
private var menuBarDelegate: MenuBarAppDelegate?

/// Entry point for the .app bundle (and the `menubar` CLI subcommand).
func runMenuBarApp() -> Never {
    // The bundle has no launchd stdout redirect; keep sharing the CLI log.
    freopen("/tmp/monitor-speakers.log", "a", stdout)
    freopen("/tmp/monitor-speakers.log", "a", stderr)
    setvbuf(stdout, nil, _IOLBF, 0)
    log("menubar: starting")
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = MenuBarAppDelegate()
    menuBarDelegate = delegate
    app.delegate = delegate
    app.run()
    exit(0)
}
