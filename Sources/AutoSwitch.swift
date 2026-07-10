import CoreAudio
import Foundation

/// Watches the CoreAudio device list and flips the default output device:
/// all monitors connected -> BlackHole (the routed pipeline),
/// all monitors gone      -> built-in speakers.
///
/// Edge-triggered: it only acts when the monitor set transitions between
/// "all present" and "none present" (plus once at startup), so a manually
/// chosen output device is never overridden in steady state. Evaluation is
/// debounced because dock plug/unplug surfaces devices one at a time.
///
/// The transition is only committed once the switch actually succeeds. If the
/// target device is not yet enumerable (CoreAudio is mid-transition), it retries
/// instead of stranding the default output on a silent device — the bug that
/// left audio dumped into BlackHole with the monitors gone.
final class AutoSwitcher {
    private let config: RouterConfig
    private let queue = DispatchQueue(label: "monitor-speakers.autoswitch")
    private var pending: DispatchWorkItem?
    private var monitorsWerePresent: Bool?
    /// A device-list change surfaces devices one at a time, so the desired target
    /// (built-in speakers, BlackHole) may not exist yet at the moment we evaluate.
    /// Rather than commit the transition and strand the default output on a silent
    /// device, we retry a bounded number of times until the target appears.
    private let maxRetries = 5
    private var retriesLeft = 5
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Retained so it can be handed back to AudioObjectRemovePropertyListenerBlock.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    init(config: RouterConfig) {
        self.config = config
    }

    deinit {
        stop()
    }

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleEvaluation()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status != noErr {
            print("auto-switch: failed to add device listener (OSStatus \(status))")
            return
        }
        listenerBlock = block
        queue.async { [weak self] in self?.evaluate() }
    }

    /// Removes the device listener and cancels any debounced evaluation.
    func stop() {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            )
            listenerBlock = nil
        }
        pending?.cancel()
        pending = nil
    }

    private func scheduleEvaluation() {
        retriesLeft = maxRetries
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// Re-run evaluation shortly, up to `maxRetries` times, when the desired
    /// target device was not yet enumerable. The transition state is only
    /// committed once the switch actually succeeds, so this never gives up
    /// with the output stranded on a silent device.
    private func scheduleRetry() {
        guard retriesLeft > 0 else {
            print("auto-switch: no usable output device after retries; pick one manually")
            return
        }
        retriesLeft -= 1
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        queue.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func evaluate() {
        let monitorCount = AudioDevices.find(nameContains: config.monitorNameFilter)
            .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.transport != "Virtual" }
            .count

        if monitorCount >= config.requiredMonitors, monitorsWerePresent != true {
            let target = AudioDevices.find(nameContains: config.blackholeName)
                .first { $0.outputChannels >= 2 }
            if switchDefault(to: target, reason: "\(monitorCount) monitors connected") {
                monitorsWerePresent = true
            } else {
                scheduleRetry()
            }
        } else if monitorCount == 0, monitorsWerePresent != false {
            if switchDefault(to: fallbackOutputDevice(), reason: "monitors disconnected") {
                monitorsWerePresent = false
            } else {
                scheduleRetry()
            }
        }
    }

    /// The device to fall back to when the monitors are gone. Prefers the
    /// built-in speakers, but accepts any real physical output so the default
    /// is never left on BlackHole or an aggregate (which would be silent).
    private func fallbackOutputDevice() -> AudioDeviceInfo? {
        let devices = AudioDevices.all()
        if let builtin = devices.first(where: { $0.transport == "BuiltIn" && $0.outputChannels > 0 }) {
            return builtin
        }
        return devices.first {
            $0.outputChannels > 0
                && $0.transport != "Aggregate"
                && $0.transport != "Virtual"
                && !$0.name.contains(config.blackholeName)
        }
    }

    /// Returns true when the default output is (now) the desired device, false
    /// when the target was missing or the switch failed — in which case the
    /// caller retries instead of committing the transition.
    @discardableResult
    private func switchDefault(to device: AudioDeviceInfo?, reason: String) -> Bool {
        guard let device else {
            print("auto-switch: \(reason), but no target device found yet (will retry)")
            return false
        }
        if AudioDevices.defaultOutputDevice() == device.id {
            print("auto-switch: \(reason), '\(device.name)' already default")
            return true
        }
        do {
            try AudioDevices.setDefaultOutputDevice(device.id)
            print("auto-switch: \(reason) → default output '\(device.name)'")
            return true
        } catch {
            print("auto-switch: \(reason), switch failed: \(error)")
            return false
        }
    }
}
