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
final class AutoSwitcher {
    private let config: RouterConfig
    private let queue = DispatchQueue(label: "monitor-speakers.autoswitch")
    private var pending: DispatchWorkItem?
    private var monitorsWerePresent: Bool?
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
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluate() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func evaluate() {
        let monitorCount = AudioDevices.find(nameContains: config.monitorNameFilter)
            .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.transport != "Virtual" }
            .count

        if monitorCount >= config.requiredMonitors, monitorsWerePresent != true {
            monitorsWerePresent = true
            let target = AudioDevices.find(nameContains: config.blackholeName)
                .first { $0.outputChannels >= 2 }
            switchDefault(to: target, reason: "\(monitorCount) monitors connected")
        } else if monitorCount == 0, monitorsWerePresent != false {
            monitorsWerePresent = false
            let target = AudioDevices.all()
                .first { $0.transport == "BuiltIn" && $0.outputChannels > 0 }
            switchDefault(to: target, reason: "monitors disconnected")
        }
    }

    private func switchDefault(to device: AudioDeviceInfo?, reason: String) {
        guard let device else {
            print("auto-switch: \(reason), but no target device found")
            return
        }
        if AudioDevices.defaultOutputDevice() == device.id {
            print("auto-switch: \(reason), '\(device.name)' already default")
            return
        }
        do {
            try AudioDevices.setDefaultOutputDevice(device.id)
            print("auto-switch: \(reason) → default output '\(device.name)'")
        } catch {
            print("auto-switch: \(reason), switch failed: \(error)")
        }
    }
}
