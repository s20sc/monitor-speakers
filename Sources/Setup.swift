import Foundation

/// Rebuilds the aggregate device from the currently-present hardware and
/// updates `config.subPair`. Shared by the CLI `setup` command and the menu
/// bar app's "Rebuild Aggregate" action. Returns human-readable summary lines;
/// throws with a descriptive error when required devices are missing.
func setupAggregate(config: inout RouterConfig) throws -> [String] {
    var lines: [String] = []

    guard let blackhole = AudioDevices.find(nameContains: config.blackholeName)
        .first(where: { $0.inputChannels >= 2 })
    else {
        throw AudioDeviceError.notFound(
            "BlackHole device '\(config.blackholeName)' — install from https://existential.audio/blackhole/"
        )
    }

    let monitors = AudioDevices.find(nameContains: config.monitorNameFilter)
        .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.uid != blackhole.uid }
    guard !monitors.isEmpty else {
        throw AudioDeviceError.notFound(
            "output devices matching '\(config.monitorNameFilter)' — are the monitors connected?"
        )
    }
    if monitors.count != 3 {
        lines.append("warning: expected 3 monitors, found \(monitors.count); proceeding with all of them")
    }

    // Optional bass speaker rides at the end of the aggregate. Prefer wired
    // transports: Bluetooth adds 100-300 ms which audibly smears the bass
    // behind the (near-zero-latency) satellites.
    var subSpeaker: AudioDeviceInfo?
    if config.subEnabled {
        subSpeaker = AudioDevices.find(nameContains: config.subName)
            .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.transport != "Virtual" }
            .sorted { ($0.transport == "Bluetooth" ? 1 : 0) < ($1.transport == "Bluetooth" ? 1 : 0) }
            .first
        if subSpeaker == nil {
            lines.append("note: bass speaker '\(config.subName)' not found; continuing without it")
        } else if subSpeaker?.transport == "Bluetooth" {
            lines.append("warning: '\(subSpeaker!.name)' is on Bluetooth — bass will lag by 100-300 ms;")
            lines.append("         connect it via USB and rebuild for tight sync")
        }
    }
    config.subPair = subSpeaker != nil ? 2 + monitors.count * 2 : -1

    if let existing = AudioDevices.find(uid: config.aggregateUID) {
        try? AudioDevices.destroyAggregate(deviceID: existing.id)
        lines.append("removed existing aggregate '\(existing.name)'")
    }

    // BlackHole first so its loopback occupies channels 0-1 and feeds input.
    // BlackHole is the clock master: its host-clock timing is the most stable,
    // and every monitor gets drift compensation against it.
    let subDeviceUIDs = [blackhole.uid] + monitors.map { $0.uid }
        + (subSpeaker.map { [$0.uid] } ?? [])
    let aggregateID = try AudioDevices.createAggregate(
        name: config.aggregateName,
        uid: config.aggregateUID,
        subDeviceUIDs: subDeviceUIDs,
        masterUID: blackhole.uid
    )
    // Roll back the just-created aggregate if saving fails, so setup never
    // leaves an orphan device behind after reporting failure.
    do {
        try config.save()
    } catch {
        try? AudioDevices.destroyAggregate(deviceID: aggregateID)
        throw AudioDeviceError.unsupported(
            "failed to save config after creating aggregate (rolled back): \(error)"
        )
    }
    lines.append("created aggregate '\(config.aggregateName)' (id \(aggregateID))")
    lines.append("channel layout:")
    lines.append("  ch 0-1  \(blackhole.name) [loopback input, output muted]")
    var channel = 2
    for monitor in monitors {
        lines.append("  ch \(channel)-\(channel + 1)  \(monitor.name) [\(monitor.transport)]")
        channel += 2
    }
    if let subSpeaker {
        lines.append("  ch \(channel)-\(channel + 1)  \(subSpeaker.name) [\(subSpeaker.transport)] (bass < \(Int(config.subFreq)) Hz)")
    }
    return lines
}
