import CoreAudio
import Foundation

// MARK: - Real-time-safe helpers
//
// Everything reached from an IOProc must avoid heap allocation, locks, ObjC/Swift
// runtime dispatch, and logging. We therefore use plain C function-pointer IOProcs
// (not capturing Swift closures), pass state through a heap context allocated once
// at start, and walk the AudioBufferList in place without building Swift arrays.

/// Locates one global channel inside an AudioBufferList and returns its base
/// pointer, interleave stride, and frame count. No allocation; safe on the audio
/// thread. Buffers are interleaved within each stream; channels are numbered
/// globally across buffers.
private func locateChannel(
    _ abl: UnsafePointer<AudioBufferList>, global target: Int
) -> (base: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)? {
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
    var channel = 0
    for buffer in buffers {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
        let stride = Int(buffer.mNumberChannels)
        if target < channel + stride {
            let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size)
            let base = data.assumingMemoryBound(to: Float32.self) + (target - channel)
            return (base, stride, frames)
        }
        channel += stride
    }
    return nil
}

/// State handed to the router IOProc. Plain C data (pointers + scalars) so it can
/// be read on the audio thread without touching the Swift runtime.
private struct RenderContext {
    var gain: Float
    var channelCount: Int
    var leftGains: UnsafeMutablePointer<Float>   // per output channel
    var rightGains: UnsafeMutablePointer<Float>  // per output channel
    var peakBits: UnsafeMutablePointer<UInt32>   // inputPeak as Float bit pattern
}

/// Captures nothing → convertible to a C `AudioDeviceIOProc`. Copies the input
/// L/R channels into every mapped output channel through the precomputed gains.
private let routerIOProc: AudioDeviceIOProc = {
    _, _, inInputData, _, outOutputData, _, clientData in
    guard let clientData else { return noErr }
    let ctx = clientData.assumingMemoryBound(to: RenderContext.self).pointee

    guard let left = locateChannel(inInputData, global: 0) else { return noErr }
    let right = locateChannel(inInputData, global: 1) ?? left

    // Peak of the input L channel; single 32-bit aligned store is atomic on
    // Apple platforms, so the diagnostic reader never sees a torn value.
    var peak: Float = 0
    for frame in 0..<left.frames {
        let v = abs(left.base[frame * left.stride])
        if v > peak { peak = v }
    }
    ctx.peakBits.pointee = peak.bitPattern

    let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)
    var channel = 0
    for buffer in outputs {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
        let stride = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size)
        let base = data.assumingMemoryBound(to: Float32.self)
        for local in 0..<stride {
            let ch = channel + local
            let lg = ch < ctx.channelCount ? ctx.leftGains[ch] : 0
            let rg = ch < ctx.channelCount ? ctx.rightGains[ch] : 0
            if lg == 0 && rg == 0 {
                for frame in 0..<frames { base[frame * stride + local] = 0 }
                continue
            }
            let mixed = min(frames, left.frames)
            for frame in 0..<mixed {
                let l = left.base[frame * left.stride]
                let r = right.base[frame * right.stride]
                base[frame * stride + local] = (lg * l + rg * r) * ctx.gain
            }
            for frame in mixed..<frames { base[frame * stride + local] = 0 }
        }
        channel += stride
    }
    return noErr
}

/// Routes the aggregate device's input channels (BlackHole loopback) to its
/// output channels through a static mixing matrix. Runs entirely inside one
/// CoreAudio IOProc, so drift correction between sub-devices is handled by the
/// HAL, not by us.
final class Router {
    private let deviceID: AudioDeviceID
    private let channelCount: Int
    private let leftGains: UnsafeMutablePointer<Float>
    private let rightGains: UnsafeMutablePointer<Float>
    private let peakBits: UnsafeMutablePointer<UInt32>
    private let context: UnsafeMutablePointer<RenderContext>
    private var procID: AudioDeviceIOProcID?

    /// Peak of the most recent input block; diagnostic only.
    var inputPeak: Float { Float(bitPattern: peakBits.pointee) }

    init(deviceID: AudioDeviceID, matrix: [Int: (l: Float, r: Float)], gain: Float, channelCount: Int) {
        self.deviceID = deviceID
        self.channelCount = channelCount
        let capacity = max(1, channelCount)
        leftGains = .allocate(capacity: capacity)
        rightGains = .allocate(capacity: capacity)
        leftGains.initialize(repeating: 0, count: capacity)
        rightGains.initialize(repeating: 0, count: capacity)
        for (ch, coefficient) in matrix where ch >= 0 && ch < channelCount {
            leftGains[ch] = coefficient.l
            rightGains[ch] = coefficient.r
        }
        peakBits = .allocate(capacity: 1)
        peakBits.initialize(to: Float(0).bitPattern)
        context = .allocate(capacity: 1)
        context.initialize(to: RenderContext(
            gain: gain, channelCount: channelCount,
            leftGains: leftGains, rightGains: rightGains, peakBits: peakBits
        ))
    }

    deinit {
        stop()
        context.deinitialize(count: 1)
        context.deallocate()
        leftGains.deallocate()
        rightGains.deallocate()
        peakBits.deallocate()
    }

    func start() throws {
        // Fail loudly rather than misinterpret buffers if the aggregate is not
        // 32-bit float interleaved PCM, which the render code assumes.
        try AudioDevices.requireFloat32(deviceID, scope: kAudioObjectPropertyScopeInput)
        try AudioDevices.requireFloat32(deviceID, scope: kAudioObjectPropertyScopeOutput)
        try AudioDevices.setBufferFrameSize(deviceID, frames: 256)
        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            deviceID, routerIOProc, UnsafeMutableRawPointer(context), &pid
        )
        guard status == noErr, let pid else {
            throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcID", status)
        }
        procID = pid
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
            throw AudioDeviceError.osStatus("AudioDeviceStart", startStatus)
        }
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
    }
}

// MARK: - Supervision

/// Owns the Router and keeps it alive across dock events. When the monitors
/// unplug, the aggregate collapses and the HAL tears down its IO; nothing
/// restarts it on reconnect, which would leave a silent pipeline. The
/// supervisor watches the device list and rebuilds the IOProc whenever the
/// aggregate's output channel count or AudioDeviceID changes (the latter also
/// covers coreaudiod restarts, which renumber every device).
final class RouterSupervisor {
    private let config: RouterConfig
    private let queue = DispatchQueue(label: "monitor-speakers.supervisor")
    private var router: Router?
    private var pending: DispatchWorkItem?
    private var lastOutputChannels = -1
    private var lastDeviceID = AudioDeviceID(0)
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Retained so it can be handed back to AudioObjectRemovePropertyListenerBlock.
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    var inputPeak: Float { router?.inputPeak ?? 0 }

    init(config: RouterConfig) {
        self.config = config
    }

    deinit {
        stop()
    }

    /// Attempts the first start and begins watching. A failed first start is
    /// not fatal: with the laptop undocked the aggregate has no monitor
    /// channels yet, so we wait for a device-list change instead of letting
    /// launchd respawn the daemon in a crash loop.
    func start() {
        do {
            try startRouter()
        } catch {
            lastOutputChannels = -1
            lastDeviceID = 0
            print("supervisor: IO not started yet (\(error)); waiting for device changes")
        }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleReload()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status != noErr {
            print("supervisor: failed to add device listener (OSStatus \(status)); IO will not self-heal")
            return
        }
        listenerBlock = block
    }

    /// Removes the device listener, cancels pending reloads, and stops IO.
    func stop() {
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, block
            )
            listenerBlock = nil
        }
        pending?.cancel()
        pending = nil
        router?.stop()
        router = nil
    }

    private func startRouter() throws {
        guard let aggregate = AudioDevices.find(uid: config.aggregateUID) else {
            throw AudioDeviceError.notFound("aggregate device \(config.aggregateUID)")
        }
        try config.validateMapping(outputChannels: aggregate.outputChannels)
        let started = Router(
            deviceID: aggregate.id,
            matrix: config.mixingMatrix(),
            gain: config.masterGain,
            channelCount: aggregate.outputChannels
        )
        try started.start()
        router = started
        lastOutputChannels = aggregate.outputChannels
        lastDeviceID = aggregate.id
        let centerMode = config.centerStereo ? "stereo" : "mono"
        print("routing on '\(aggregate.name)': L→ch\(config.leftPair) C→ch\(config.centerPair)(\(centerMode)) R→ch\(config.rightPair), gain \(config.masterGain)")
    }

    private func scheduleReload() {
        pending?.cancel()
        // Debounce past AutoSwitcher's 2 s window: dock devices surface one at
        // a time and we want the final topology, not an intermediate one.
        let work = DispatchWorkItem { [weak self] in self?.reloadIfNeeded() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func reloadIfNeeded() {
        guard let aggregate = AudioDevices.find(uid: config.aggregateUID) else { return }
        guard aggregate.outputChannels != lastOutputChannels || aggregate.id != lastDeviceID
        else { return }
        print("supervisor: aggregate changed (\(lastOutputChannels)ch id \(lastDeviceID) → \(aggregate.outputChannels)ch id \(aggregate.id)), restarting IO")
        router?.stop()
        router = nil
        do {
            try startRouter()
        } catch {
            // Reset so the next device-list event retries unconditionally.
            lastOutputChannels = -1
            lastDeviceID = 0
            print("supervisor: restart failed: \(error) — will retry on next device change")
        }
    }
}

// MARK: - Diagnostic tone

/// State for the tone IOProc. `phase` is touched only by the audio thread.
private struct ToneContext {
    var phase: UnsafeMutablePointer<Double>
    var step: Double
    var amplitude: Float
    var channelCount: Int
    var enabled: UnsafeMutablePointer<Bool>  // per output channel
}

private let toneIOProc: AudioDeviceIOProc = {
    _, _, _, _, outOutputData, _, clientData in
    guard let clientData else { return noErr }
    let ctx = clientData.assumingMemoryBound(to: ToneContext.self).pointee
    let outputs = UnsafeMutableAudioBufferListPointer(outOutputData)

    var frameCount = 0
    if let first = outputs.first, first.mNumberChannels > 0 {
        frameCount = Int(first.mDataByteSize)
            / (Int(first.mNumberChannels) * MemoryLayout<Float32>.size)
    }

    var phase = ctx.phase.pointee
    for frame in 0..<frameCount {
        // Diagnostic path (a few seconds, once): per-frame sin is acceptable here.
        let sample = Float32(sin(phase)) * ctx.amplitude
        phase += ctx.step
        if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        var channel = 0
        for buffer in outputs {
            guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size)
            if frame < frames {
                let base = data.assumingMemoryBound(to: Float32.self)
                for local in 0..<stride {
                    let ch = channel + local
                    let on = ch < ctx.channelCount ? ctx.enabled[ch] : false
                    base[frame * stride + local] = on ? sample : 0
                }
            }
            channel += stride
        }
    }
    ctx.phase.pointee = phase
    return noErr
}

/// Plays a sine test tone on one stereo pair of the aggregate device, used to
/// identify which physical monitor sits on which channel pair. Diagnostic only.
final class TonePlayer {
    private let deviceID: AudioDeviceID
    private let channelCount: Int
    private let phase: UnsafeMutablePointer<Double>
    private let enabled: UnsafeMutablePointer<Bool>
    private let context: UnsafeMutablePointer<ToneContext>
    private var procID: AudioDeviceIOProcID?

    init(deviceID: AudioDeviceID, pairStart: Int, channelCount: Int, frequency: Double = 440) {
        self.deviceID = deviceID
        self.channelCount = channelCount
        let capacity = max(1, channelCount)
        enabled = .allocate(capacity: capacity)
        enabled.initialize(repeating: false, count: capacity)
        for ch in [pairStart, pairStart + 1] where ch >= 0 && ch < channelCount {
            enabled[ch] = true
        }
        phase = .allocate(capacity: 1)
        phase.initialize(to: 0)
        let sampleRate = AudioDevices.nominalSampleRate(deviceID) ?? 48000.0
        context = .allocate(capacity: 1)
        context.initialize(to: ToneContext(
            phase: phase,
            step: 2.0 * .pi * frequency / sampleRate,
            amplitude: 0.3,
            channelCount: channelCount,
            enabled: enabled
        ))
    }

    deinit {
        stop()
        context.deinitialize(count: 1)
        context.deallocate()
        phase.deallocate()
        enabled.deallocate()
    }

    func start() throws {
        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcID(
            deviceID, toneIOProc, UnsafeMutableRawPointer(context), &pid
        )
        guard status == noErr, let pid else {
            throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcID", status)
        }
        procID = pid
        let startStatus = AudioDeviceStart(deviceID, pid)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, pid)
            procID = nil
            throw AudioDeviceError.osStatus("AudioDeviceStart", startStatus)
        }
    }

    func stop() {
        guard let pid = procID else { return }
        AudioDeviceStop(deviceID, pid)
        AudioDeviceDestroyIOProcID(deviceID, pid)
        procID = nil
    }
}
