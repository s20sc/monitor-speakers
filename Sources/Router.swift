import CoreAudio
import Foundation

/// Per-channel view into an AudioBufferList: base pointer + interleave stride.
private struct ChannelRef {
    let base: UnsafeMutablePointer<Float32>
    let stride: Int
    let frames: Int
}

/// Walks an AudioBufferList and returns one ChannelRef per channel,
/// in global channel order (buffers are interleaved within each stream).
private func channelRefs(_ abl: UnsafeMutableAudioBufferListPointer) -> [ChannelRef] {
    var refs: [ChannelRef] = []
    for buffer in abl {
        guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
        let stride = Int(buffer.mNumberChannels)
        let frames = Int(buffer.mDataByteSize) / (stride * MemoryLayout<Float32>.size)
        let base = data.assumingMemoryBound(to: Float32.self)
        for ch in 0..<stride {
            refs.append(ChannelRef(base: base + ch, stride: stride, frames: frames))
        }
    }
    return refs
}

/// Routes the aggregate device's input channels (BlackHole loopback) to its
/// output channels through a static mixing matrix. Runs entirely inside one
/// CoreAudio IOProc, so drift correction between sub-devices is handled by
/// the HAL, not by us.
final class Router {
    private let deviceID: AudioDeviceID
    private let matrix: [Int: (l: Float, r: Float)]
    private let gain: Float
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "monitor-speakers.io")

    /// Peak of the most recent input block; single-writer diagnostic value,
    /// torn reads are acceptable.
    private(set) var inputPeak: Float = 0

    init(deviceID: AudioDeviceID, matrix: [Int: (l: Float, r: Float)], gain: Float) {
        self.deviceID = deviceID
        self.matrix = matrix
        self.gain = gain
    }

    func start() throws {
        AudioDevices.setBufferFrameSize(deviceID, frames: 256)
        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, queue) {
            [weak self] _, inputData, _, outputData, _ in
            self?.render(inputData: inputData, outputData: outputData)
        }
        guard status == noErr, let pid else {
            throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
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

    private func render(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) {
        let inputs = channelRefs(
            UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        )
        let outputs = channelRefs(UnsafeMutableAudioBufferListPointer(outputData))

        let left = inputs.count > 0 ? inputs[0] : nil
        let right = inputs.count > 1 ? inputs[1] : left

        var peak: Float = 0
        if let left {
            for frame in 0..<left.frames {
                let v = abs(left.base[frame * left.stride])
                if v > peak { peak = v }
            }
        }
        inputPeak = peak

        for (index, out) in outputs.enumerated() {
            let coefficient = matrix[index]
            guard let left, let right, let coefficient, coefficient.l != 0 || coefficient.r != 0
            else {
                for frame in 0..<out.frames { out.base[frame * out.stride] = 0 }
                continue
            }
            let frames = min(out.frames, left.frames)
            for frame in 0..<frames {
                let l = left.base[frame * left.stride]
                let r = right.base[frame * right.stride]
                out.base[frame * out.stride] = (coefficient.l * l + coefficient.r * r) * gain
            }
            for frame in frames..<out.frames { out.base[frame * out.stride] = 0 }
        }
    }
}

/// Plays a sine test tone on one stereo pair of the aggregate device,
/// used to identify which physical monitor sits on which channel pair.
final class TonePlayer {
    private let deviceID: AudioDeviceID
    private let channels: Set<Int>
    private let frequency: Double
    private var phase: Double = 0
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "monitor-speakers.tone")

    init(deviceID: AudioDeviceID, pairStart: Int, frequency: Double = 440) {
        self.deviceID = deviceID
        self.channels = [pairStart, pairStart + 1]
        self.frequency = frequency
    }

    func start() throws {
        var pid: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&pid, deviceID, queue) {
            [weak self] _, _, _, outputData, _ in
            self?.render(outputData: outputData)
        }
        guard status == noErr, let pid else {
            throw AudioDeviceError.osStatus("AudioDeviceCreateIOProcIDWithBlock", status)
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

    private func render(outputData: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = channelRefs(UnsafeMutableAudioBufferListPointer(outputData))
        let sampleRate = 48000.0
        let step = 2.0 * .pi * frequency / sampleRate
        let frames = outputs.first?.frames ?? 0

        for frame in 0..<frames {
            let sample = Float32(sin(phase)) * 0.3
            phase += step
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
            for (index, out) in outputs.enumerated() where frame < out.frames {
                out.base[frame * out.stride] = channels.contains(index) ? sample : 0
            }
        }
    }
}
