import CoreAudio
import Foundation

let usage = """
monitor-speakers — route system audio across three monitor speakers as one wide stereo field

USAGE:
  monitor-speakers list                      List all audio devices
  monitor-speakers setup                     Create the aggregate device (BlackHole + monitors)
  monitor-speakers teardown                  Destroy the aggregate device
  monitor-speakers test [pairStart]          Play a tone per channel pair (or one pair) to identify monitors
  monitor-speakers map <left> <center> <right>   Assign channel pairs to positions, e.g. map 2 4 6
  monitor-speakers gain <0.0-2.0>            Set master gain
  monitor-speakers trim <left|center|right> <0.0-2.0>   Per-monitor gain trim
  monitor-speakers sub <on|off|freq 40-300|trim 0.0-2.0>   2.1 bass speaker (crossover)
  monitor-speakers center <stereo|mono>      Center monitor plays own L/R or mono (L+R)/2
  monitor-speakers autoswitch <on|off>       Auto-switch default output on monitor connect/disconnect
  monitor-speakers run [--verbose]           Start routing (foreground; Ctrl-C to stop)
  monitor-speakers default <name|UID fragment>   Set system default output device
  monitor-speakers status                    Show config and device availability
  monitor-speakers install                   Install launchd agent (auto-start at login)
  monitor-speakers uninstall                 Remove launchd agent
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(1)
}

func findAggregate(_ config: RouterConfig) -> AudioDeviceInfo? {
    AudioDevices.find(uid: config.aggregateUID)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width
        ? String(text.prefix(width - 1)) + " "
        : text.padding(toLength: width, withPad: " ", startingAt: 0)
}

func commandList() {
    print(pad("ID", 7) + pad("NAME", 29) + pad("TRANSPORT", 14) + pad("IN", 4) + pad("OUT", 5) + "UID")
    for device in AudioDevices.all() {
        print(
            pad(String(device.id), 7) + pad(device.name, 29) + pad(device.transport, 14)
            + pad(String(device.inputChannels), 4) + pad(String(device.outputChannels), 5)
            + device.uid
        )
    }
}

func commandSetup() {
    var config = RouterConfig.load()
    do {
        for line in try setupAggregate(config: &config) { print(line) }
    } catch {
        fail("\(error)")
    }
    print("\nnext: run `monitor-speakers test` to identify monitors,")
    print("then `monitor-speakers map <left> <center> <right>` if the default (2 4 6) is wrong.")
}

func commandTeardown() {
    let config = RouterConfig.load()
    guard let aggregate = findAggregate(config) else {
        fail("aggregate '\(config.aggregateName)' not found")
    }
    do {
        try AudioDevices.destroyAggregate(deviceID: aggregate.id)
        print("destroyed '\(aggregate.name)'")
    } catch {
        fail("\(error)")
    }
}

func commandTest(pairArg: String?) {
    let config = RouterConfig.load()
    guard let aggregate = findAggregate(config) else {
        fail("aggregate not found — run `monitor-speakers setup` first")
    }
    let pairs: [Int]
    if let pairArg {
        guard let pair = Int(pairArg) else { fail("invalid channel pair '\(pairArg)'") }
        pairs = [pair]
    } else {
        var defaults = [config.leftPair, config.centerPair, config.rightPair]
        if config.subActive(outputChannels: aggregate.outputChannels) {
            defaults.append(config.subPair)
        }
        pairs = defaults.sorted()
    }
    for pair in pairs {
        print("playing tone on channel pair \(pair)-\(pair + 1) ...")
        let tone = TonePlayer(
            deviceID: aggregate.id, pairStart: pair, channelCount: aggregate.outputChannels
        )
        do {
            try tone.start()
        } catch {
            fail("\(error)")
        }
        Thread.sleep(forTimeInterval: 2.5)
        tone.stop()
        Thread.sleep(forTimeInterval: 0.5)
    }
    print("done — note which monitor played for each pair, then use `map` to assign positions.")
}

func commandMap(_ args: [String]) {
    guard args.count == 3, let left = Int(args[0]), let center = Int(args[1]),
          let right = Int(args[2])
    else {
        fail("usage: monitor-speakers map <leftPair> <centerPair> <rightPair>")
    }
    var config = RouterConfig.load()
    config.leftPair = left
    config.centerPair = center
    config.rightPair = right
    do {
        try config.validateMapping(outputChannels: findAggregate(config)?.outputChannels ?? 0)
        try config.save()
        print("mapping saved: left=\(left) center=\(center) right=\(right)")
    } catch {
        fail("\(error)")
    }
}

func commandGain(_ arg: String?) {
    guard let arg, let gain = Float(arg), gain >= 0, gain <= 2 else {
        fail("usage: monitor-speakers gain <0.0-2.0>")
    }
    var config = RouterConfig.load()
    config.masterGain = gain
    do {
        try config.save()
        print("master gain set to \(gain) (restart `run` to apply)")
    } catch {
        fail("\(error)")
    }
}

func commandTrim(_ args: [String]) {
    guard args.count == 2, let value = Float(args[1]), value >= 0, value <= 2,
          ["left", "center", "right"].contains(args[0])
    else {
        fail("usage: monitor-speakers trim <left|center|right> <0.0-2.0>")
    }
    var config = RouterConfig.load()
    switch args[0] {
    case "left": config.leftTrim = value
    case "center": config.centerTrim = value
    default: config.rightTrim = value
    }
    do {
        try config.save()
        print("\(args[0]) trim set to \(value) (restart `run` to apply)")
    } catch {
        fail("\(error)")
    }
}

func commandSub(_ args: [String]) {
    var config = RouterConfig.load()
    let usageText = "usage: monitor-speakers sub <on|off|freq 40-300|trim 0.0-2.0>"
    switch args.first {
    case "on", "off":
        config.subEnabled = args[0] == "on"
        do {
            try config.save()
            print("sub \(args[0]) — run `setup` to rebuild the aggregate, then restart `run`")
        } catch { fail("\(error)") }
    case "freq":
        guard args.count == 2, let freq = Float(args[1]), freq >= 40, freq <= 300 else {
            fail(usageText)
        }
        config.subFreq = freq
        do {
            try config.save()
            print("crossover set to \(Int(freq)) Hz (restart `run` to apply)")
        } catch { fail("\(error)") }
    case "trim":
        guard args.count == 2, let value = Float(args[1]), value >= 0, value <= 2 else {
            fail(usageText)
        }
        config.subTrim = value
        do {
            try config.save()
            print("sub trim set to \(value) (restart `run` to apply)")
        } catch { fail("\(error)") }
    default:
        fail(usageText)
    }
}

func commandCenter(_ arg: String?) {
    guard let arg, arg == "stereo" || arg == "mono" else {
        fail("usage: monitor-speakers center <stereo|mono>")
    }
    var config = RouterConfig.load()
    config.centerStereo = arg == "stereo"
    do {
        try config.save()
        print("center monitor mode: \(arg) (restart `run` to apply)")
    } catch {
        fail("\(error)")
    }
}

func commandAutoSwitch(_ arg: String?) {
    guard let arg, arg == "on" || arg == "off" else {
        fail("usage: monitor-speakers autoswitch <on|off>")
    }
    var config = RouterConfig.load()
    config.autoSwitch = arg == "on"
    do {
        try config.save()
        print("auto-switch: \(arg) (restart `run` to apply)")
    } catch {
        fail("\(error)")
    }
}

// Held globally so they survive for the whole `run` lifetime and can be torn
// down cleanly on shutdown. Locals in commandRun are not enough: ARC may
// release them after their last use even though dispatchMain() never returns.
var autoSwitcher: AutoSwitcher?
var routerSupervisor: RouterSupervisor?
var verboseTimer: DispatchSourceTimer?
var signalSources: [DispatchSourceSignal] = []

func commandRun(verbose: Bool) {
    let config = RouterConfig.load()
    guard findAggregate(config) != nil else {
        fail("aggregate not found — run `monitor-speakers setup` first")
    }
    // The supervisor validates the mapping, starts the router, and rebuilds
    // the IOProc whenever the aggregate changes across dock events. A failed
    // first start (laptop undocked) waits instead of crash-looping.
    let supervisor = RouterSupervisor(config: config)
    supervisor.start()
    routerSupervisor = supervisor
    print("set system output to '\(config.blackholeName)' to hear audio; Ctrl-C to stop.")

    if config.autoSwitch {
        autoSwitcher = AutoSwitcher(config: config)
        autoSwitcher?.start()
        print("auto-switch enabled: \(config.requiredMonitors)+ monitors → \(config.blackholeName), 0 → built-in speakers")
    }

    if verbose {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler {
            print(String(format: "input peak: %.4f", supervisor.inputPeak))
        }
        timer.resume()
        verboseTimer = timer
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    let shutdown = {
        verboseTimer?.cancel()
        autoSwitcher?.stop()
        routerSupervisor?.stop()
        print("stopped")
        exit(0)
    }
    sigint.setEventHandler(handler: shutdown)
    sigterm.setEventHandler(handler: shutdown)
    sigint.resume()
    sigterm.resume()
    signalSources = [sigint, sigterm]
    dispatchMain()
}

func commandDefault(_ fragment: String?) {
    guard let fragment else { fail("usage: monitor-speakers default <device name or UID fragment>") }
    // Matching the UID too lets identically-named devices (three "LG SDQHD")
    // be addressed individually, e.g. for per-monitor diagnostics.
    let matches = AudioDevices.all().filter {
        $0.outputChannels > 0
            && ($0.name.localizedCaseInsensitiveContains(fragment)
                || $0.uid.localizedCaseInsensitiveContains(fragment))
    }
    guard let device = matches.first else { fail("no output device matching '\(fragment)'") }
    if matches.count > 1 {
        print("multiple matches, using '\(device.name)' (\(device.transport))")
    }
    do {
        try AudioDevices.setDefaultOutputDevice(device.id)
        print("default output → \(device.name)")
    } catch {
        fail("\(error)")
    }
}

func commandStatus() {
    let config = RouterConfig.load()
    print("config: \(RouterConfig.fileURL.path)")
    print("  aggregate: \(config.aggregateName) (\(config.aggregateUID))")
    print("  mapping: left=\(config.leftPair) center=\(config.centerPair) (\(config.centerStereo ? "stereo" : "mono")) right=\(config.rightPair) gain=\(config.masterGain)")
    print("  sub: \(config.subEnabled ? "on" : "off") '\(config.subName)' pair=\(config.subPair) crossover=\(Int(config.subFreq))Hz trim=\(config.subTrim)")
    let aggregate = findAggregate(config)
    print("aggregate device: \(aggregate.map { "present (id \($0.id), \($0.outputChannels) out ch)" } ?? "MISSING — run setup")")
    let blackhole = AudioDevices.find(nameContains: config.blackholeName)
    print("blackhole: \(blackhole.isEmpty ? "MISSING" : "present")")
    let monitors = AudioDevices.find(nameContains: config.monitorNameFilter)
        .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" }
    print("monitors matching '\(config.monitorNameFilter)': \(monitors.count)")
    if let defaultID = AudioDevices.defaultOutputDevice(),
       let current = AudioDevices.all().first(where: { $0.id == defaultID }) {
        print("system default output: \(current.name)")
    }
}

let agentLabel = "com.monitor-speakers.router"
var agentPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
}

func commandInstall() {
    // Copy the binary out of any synced folder (iCloud can evict files) so
    // the launch agent always has a local, stable executable.
    let sourceBinary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/monitor-speakers")
    let installedBinary = supportDir.appendingPathComponent("monitor-speakers")
    do {
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: installedBinary.path) {
            try FileManager.default.removeItem(at: installedBinary)
        }
        try FileManager.default.copyItem(at: sourceBinary, to: installedBinary)
    } catch {
        fail("cannot install binary to \(installedBinary.path): \(error)")
    }
    let binary = installedBinary.path
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>\(agentLabel)</string>
        <key>ProgramArguments</key>
        <array><string>\(binary)</string><string>run</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
        <key>StandardOutPath</key><string>/tmp/monitor-speakers.log</string>
        <key>StandardErrorPath</key><string>/tmp/monitor-speakers.log</string>
    </dict>
    </plist>
    """
    do {
        try plist.write(to: agentPlistURL, atomically: true, encoding: .utf8)
    } catch {
        fail("cannot write \(agentPlistURL.path): \(error)")
    }
    // Remove any previous registration before bootstrapping again.
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
    try? bootout.run()
    bootout.waitUntilExit()
    let bootstrap = Process()
    bootstrap.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootstrap.arguments = ["bootstrap", "gui/\(getuid())", agentPlistURL.path]
    try? bootstrap.run()
    bootstrap.waitUntilExit()
    print("installed launch agent \(agentLabel) → \(binary)")
    print("logs: /tmp/monitor-speakers.log")
}

func commandUninstall() {
    let bootout = Process()
    bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    bootout.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
    try? bootout.run()
    bootout.waitUntilExit()
    try? FileManager.default.removeItem(at: agentPlistURL)
    print("uninstalled \(agentLabel)")
}

// MARK: - Entry point

setvbuf(stdout, nil, _IOLBF, 0)  // line-buffer stdout so logs reach files/launchd promptly

let arguments = Array(CommandLine.arguments.dropFirst())

// Launched from the .app bundle (Launch Services passes no arguments):
// become the menu bar app instead of printing CLI usage.
if arguments.isEmpty, Bundle.main.bundleIdentifier == "com.monitor-speakers.app" {
    runMenuBarApp()
}

switch arguments.first {
case "list": commandList()
case "setup": commandSetup()
case "teardown": commandTeardown()
case "test": commandTest(pairArg: arguments.count > 1 ? arguments[1] : nil)
case "map": commandMap(Array(arguments.dropFirst()))
case "gain": commandGain(arguments.count > 1 ? arguments[1] : nil)
case "trim": commandTrim(Array(arguments.dropFirst()))
case "sub": commandSub(Array(arguments.dropFirst()))
case "menubar": runMenuBarApp()
case "center": commandCenter(arguments.count > 1 ? arguments[1] : nil)
case "autoswitch": commandAutoSwitch(arguments.count > 1 ? arguments[1] : nil)
case "run": commandRun(verbose: arguments.contains("--verbose"))
case "default": commandDefault(arguments.count > 1 ? arguments.dropFirst().joined(separator: " ") : nil)
case "status": commandStatus()
case "install": commandInstall()
case "uninstall": commandUninstall()
default:
    print(usage)
    exit(arguments.isEmpty ? 0 : 1)
}
