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
    var subGains: UnsafeMutablePointer<Float>    // per output channel, fed from the LP mono bus
    var peakBits: UnsafeMutablePointer<UInt32>   // inputPeak as Float bit pattern
    /// 2.1 crossover. When false the satellites get the raw input and the LP
    /// bus is never computed (sub absent -> monitors stay full-range).
    var crossoverEnabled: Bool
    var highPass: BiquadCoefficients
    var lowPass: BiquadCoefficients
    var scratchHL: UnsafeMutablePointer<Float>   // high-passed L, per frame
    var scratchHR: UnsafeMutablePointer<Float>   // high-passed R, per frame
    var scratchLP: UnsafeMutablePointer<Float>   // low-passed (L+R)/2, per frame
    var scratchCapacity: Int
    var filterState: UnsafeMutablePointer<Float> // 3 LR4 filters x 8 floats (HL, HR, LP)
    /// Inaudible keep-alive pilot mixed into the sub channels: USB speakers
    /// (Jieli boards and friends) power themselves off after a stretch of
    /// digital silence, which is exactly what the LP bus carries whenever the
    /// music has no low end. ~-60 dBFS at 20 Hz defeats the silence detector
    /// without being audible.
    var pilotStep: Double
    var pilotAmp: Float
    var pilotPhase: UnsafeMutablePointer<Double>
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

    // Run the crossover once per callback into the scratch buffers: satellites
    // read the high-passed L/R, the sub channels read the low-passed mono bus.
    let inputFrames = min(left.frames, ctx.scratchCapacity)
    if ctx.crossoverEnabled {
        let stateHL = ctx.filterState
        let stateHR = ctx.filterState + 8
        let stateLP = ctx.filterState + 16
        var phase = ctx.pilotPhase.pointee
        for frame in 0..<inputFrames {
            // Sanitize: VoIP stacks occasionally emit NaN/Inf samples, and one
            // of those permanently poisons IIR filter state — audio then dies
            // until the next IO restart. Zero them at the door.
            var l = left.base[frame * left.stride]
            var r = right.base[frame * right.stride]
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            ctx.scratchHL[frame] = processLR4(l, coefficients: ctx.highPass, state: stateHL)
            ctx.scratchHR[frame] = processLR4(r, coefficients: ctx.highPass, state: stateHR)
            let lp = processLR4((l + r) * 0.5, coefficients: ctx.lowPass, state: stateLP)
            ctx.scratchLP[frame] = lp + ctx.pilotAmp * Float(sin(phase))
            phase += ctx.pilotStep
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        ctx.pilotPhase.pointee = phase
        // Self-heal: if state was already poisoned (e.g. before this guard
        // existed, or by any residual non-finite arithmetic), flush it so the
        // next callback recovers instead of staying silent forever.
        for i in 0..<24 where !ctx.filterState[i].isFinite {
            for j in 0..<24 { ctx.filterState[j] = 0 }
            break
        }
    }

    let sourceL: UnsafeMutablePointer<Float32>
    let sourceR: UnsafeMutablePointer<Float32>
    let sourceStrideL: Int
    let sourceStrideR: Int
    if ctx.crossoverEnabled {
        sourceL = ctx.scratchHL; sourceStrideL = 1
        sourceR = ctx.scratchHR; sourceStrideR = 1
    } else {
        sourceL = left.base; sourceStrideL = left.stride
        sourceR = right.base; sourceStrideR = right.stride
    }

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
            let sg = ctx.crossoverEnabled && ch < ctx.channelCount ? ctx.subGains[ch] : 0
            if lg == 0 && rg == 0 && sg == 0 {
                for frame in 0..<frames { base[frame * stride + local] = 0 }
                continue
            }
            let mixed = min(frames, inputFrames)
            for frame in 0..<mixed {
                let l = sourceL[frame * sourceStrideL]
                let r = sourceR[frame * sourceStrideR]
                var v = lg * l + rg * r
                if sg != 0 { v += sg * ctx.scratchLP[frame] }
                base[frame * stride + local] = v * ctx.gain
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
    /// Upper bound on frames per IO cycle we can filter; the HAL is asked for
    /// 256 but other clients may push the device to larger buffers.
    private static let scratchFrames = 16384

    private let deviceID: AudioDeviceID
    private let channelCount: Int
    private let leftGains: UnsafeMutablePointer<Float>
    private let rightGains: UnsafeMutablePointer<Float>
    private let subGains: UnsafeMutablePointer<Float>
    private let peakBits: UnsafeMutablePointer<UInt32>
    private let scratch: UnsafeMutablePointer<Float>      // 3 x scratchFrames
    private let filterState: UnsafeMutablePointer<Float>  // 3 filters x 8 floats
    private let pilotPhase: UnsafeMutablePointer<Double>
    private let context: UnsafeMutablePointer<RenderContext>
    private var procID: AudioDeviceIOProcID?

    /// Peak of the most recent input block; diagnostic only.
    var inputPeak: Float { Float(bitPattern: peakBits.pointee) }

    init(deviceID: AudioDeviceID, config: RouterConfig, channelCount: Int) {
        self.deviceID = deviceID
        self.channelCount = channelCount
        let capacity = max(1, channelCount)
        leftGains = .allocate(capacity: capacity)
        rightGains = .allocate(capacity: capacity)
        subGains = .allocate(capacity: capacity)
        leftGains.initialize(repeating: 0, count: capacity)
        rightGains.initialize(repeating: 0, count: capacity)
        subGains.initialize(repeating: 0, count: capacity)
        for (ch, coefficient) in config.mixingMatrix() where ch >= 0 && ch < channelCount {
            leftGains[ch] = coefficient.l
            rightGains[ch] = coefficient.r
        }
        let crossover = config.subActive(outputChannels: channelCount)
        if crossover {
            subGains[config.subPair] = config.subTrim
            subGains[config.subPair + 1] = config.subTrim
        }
        peakBits = .allocate(capacity: 1)
        peakBits.initialize(to: Float(0).bitPattern)
        scratch = .allocate(capacity: Self.scratchFrames * 3)
        scratch.initialize(repeating: 0, count: Self.scratchFrames * 3)
        filterState = .allocate(capacity: 24)
        filterState.initialize(repeating: 0, count: 24)
        pilotPhase = .allocate(capacity: 1)
        pilotPhase.initialize(to: 0)
        // The whole pipeline runs at 48 kHz (BlackHole + display audio); a
        // different rate would only shift the crossover corner slightly.
        let sampleRate: Float = 48000
        context = .allocate(capacity: 1)
        context.initialize(to: RenderContext(
            gain: config.masterGain, channelCount: channelCount,
            leftGains: leftGains, rightGains: rightGains, subGains: subGains,
            peakBits: peakBits,
            crossoverEnabled: crossover,
            highPass: .butterworthHighPass(frequency: config.subFreq, sampleRate: sampleRate),
            lowPass: .butterworthLowPass(frequency: config.subFreq, sampleRate: sampleRate),
            scratchHL: scratch,
            scratchHR: scratch + Self.scratchFrames,
            scratchLP: scratch + Self.scratchFrames * 2,
            scratchCapacity: Self.scratchFrames,
            filterState: filterState,
            pilotStep: 2.0 * .pi * 20.0 / Double(sampleRate),
            pilotAmp: 0.001,  // ≈ -60 dBFS before sub trim
            pilotPhase: pilotPhase
        ))
    }

    deinit {
        stop()
        context.deinitialize(count: 1)
        context.deallocate()
        leftGains.deallocate()
        rightGains.deallocate()
        subGains.deallocate()
        peakBits.deallocate()
        scratch.deallocate()
        filterState.deallocate()
        pilotPhase.deallocate()
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
    /// Mutable: an automatic aggregate rebuild (bass speaker reappearing)
    /// updates `subPair` in place.
    private var config: RouterConfig
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
    /// uid -> "name [transport]" of monitors seen at the last device-list
    /// event; diffed on every event to log exactly which monitor flapped.
    private var knownMonitors: [String: String] = [:]
    /// Last start failure; keeps the periodic retry loop quiet in the log
    /// unless the error actually changes.
    private var lastErrorText: String?

    var inputPeak: Float { router?.inputPeak ?? 0 }

    /// Cross-thread read for UI display only; a slightly stale value is fine.
    var statusText: String {
        router != nil
            ? "Routing · \(lastOutputChannels) ch"
            : "Waiting for devices"
    }

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
            log("supervisor: IO not started yet (\(error)); retrying periodically")
            scheduleRetry()
        }
        knownMonitors = Self.currentMonitors(config)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.logMonitorChanges()
            self?.scheduleReload()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block
        )
        if status != noErr {
            log("supervisor: failed to add device listener (OSStatus \(status)); IO will not self-heal")
            return
        }
        listenerBlock = block
    }

    /// Snapshot of physical monitors matching the config filter.
    private static func currentMonitors(_ config: RouterConfig) -> [String: String] {
        let monitors = AudioDevices.find(nameContains: config.monitorNameFilter)
            .filter { $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.transport != "Virtual" }
            .map { ($0.uid, "\($0.name) [\($0.transport)]") }
        return Dictionary(monitors, uniquingKeysWith: { first, _ in first })
    }

    /// Runs undebounced on every device-list event so even brief flaps leave a
    /// timestamped trace of exactly which monitor dropped and returned.
    private func logMonitorChanges() {
        let current = Self.currentMonitors(config)
        for (uid, desc) in current where knownMonitors[uid] == nil {
            log("monitor appeared: \(desc) uid \(uid)")
        }
        for (uid, desc) in knownMonitors where current[uid] == nil {
            log("monitor LOST: \(desc) uid \(uid)")
        }
        knownMonitors = current
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
            config: config,
            channelCount: aggregate.outputChannels
        )
        try started.start()
        router = started
        lastOutputChannels = aggregate.outputChannels
        lastDeviceID = aggregate.id
        let centerMode = config.centerStereo ? "stereo" : "mono"
        let subMode = config.subActive(outputChannels: aggregate.outputChannels)
            ? " sub→ch\(config.subPair)(<\(Int(config.subFreq))Hz, trim \(config.subTrim))"
            : ""
        log("routing on '\(aggregate.name)': L→ch\(config.leftPair) C→ch\(config.centerPair)(\(centerMode)) R→ch\(config.rightPair)\(subMode), gain \(config.masterGain)")
        lastErrorText = nil
        // A rebuilt aggregate can come up before all sub-devices have
        // attached, and channels appearing inside it fire no system
        // device-list event — re-check once after things settle.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.reloadIfNeeded() }
    }

    private func scheduleReload() {
        pending?.cancel()
        // Debounce past AutoSwitcher's 2 s window: dock devices surface one at
        // a time and we want the final topology, not an intermediate one.
        let work = DispatchWorkItem { [weak self] in self?.reloadIfNeeded() }
        pending = work
        queue.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    /// Device-list changes are not the only way a failed start can become
    /// startable again (e.g. a TCC microphone grant fires no event), so keep
    /// retrying quietly in the background.
    private func scheduleRetry() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadIfNeeded() }
        pending = work
        queue.asyncAfter(deadline: .now() + 10, execute: work)
    }

    private func reloadIfNeeded() {
        // The bass speaker powers itself off when idle; if a rebuild happened
        // while it was gone, the aggregate no longer references it and it will
        // not rejoin on its own. Rebuild automatically the moment it is back.
        if config.subEnabled, config.subPair < 0,
           AudioDevices.find(nameContains: config.subName).contains(where: {
               $0.outputChannels >= 2 && $0.transport != "Aggregate" && $0.transport != "Virtual"
           }) {
            log("supervisor: bass speaker '\(config.subName)' is back — rebuilding aggregate")
            do {
                for line in try setupAggregate(config: &config) { log("supervisor: \(line)") }
            } catch {
                log("supervisor: automatic rebuild failed: \(error)")
            }
        }
        guard let aggregate = AudioDevices.find(uid: config.aggregateUID) else { return }
        guard aggregate.outputChannels != lastOutputChannels || aggregate.id != lastDeviceID
        else { return }
        // Quiet during retry loops: only narrate transitions, not every attempt.
        if lastErrorText == nil {
            log("supervisor: aggregate changed (\(lastOutputChannels)ch id \(lastDeviceID) → \(aggregate.outputChannels)ch id \(aggregate.id)), restarting IO")
        }
        router?.stop()
        router = nil
        do {
            try startRouter()
        } catch {
            // Reset so the next attempt retries unconditionally.
            lastOutputChannels = -1
            lastDeviceID = 0
            let text = "\(error)"
            if text != lastErrorText {
                log("supervisor: restart failed: \(text) — retrying periodically")
                lastErrorText = text
            }
            scheduleRetry()
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
