import CoreAudio
import Foundation

/// Static description of a CoreAudio device.
struct AudioDeviceInfo {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
    let transport: String
}

enum AudioDeviceError: Error, CustomStringConvertible {
    case osStatus(String, OSStatus)
    case notFound(String)

    var description: String {
        switch self {
        case .osStatus(let what, let status):
            return "\(what) failed (OSStatus \(status))"
        case .notFound(let what):
            return "\(what) not found"
        }
    }
}

private func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
}

private func stringProperty(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector
) -> String? {
    var addr = propertyAddress(selector)
    guard AudioObjectHasProperty(objectID, &addr) else { return nil }
    var value: CFString?
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr, let cf = value else { return nil }
    return cf as String
}

private func channelCount(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
    var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else {
        return 0
    }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else {
        return 0
    }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

private func transportName(_ deviceID: AudioDeviceID) -> String {
    var addr = propertyAddress(kAudioDevicePropertyTransportType)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
        return "?"
    }
    switch value {
    case kAudioDeviceTransportTypeHDMI: return "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeBuiltIn: return "BuiltIn"
    case kAudioDeviceTransportTypeAggregate: return "Aggregate"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
    default: return "other"
    }
}

enum AudioDevices {
    static func all() -> [AudioDeviceInfo] {
        var addr = propertyAddress(kAudioHardwarePropertyDevices)
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemID, &addr, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(systemID, &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.map { id in
            AudioDeviceInfo(
                id: id,
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                name: stringProperty(id, kAudioObjectPropertyName) ?? "(unknown)",
                inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                transport: transportName(id)
            )
        }
    }

    static func find(uid: String) -> AudioDeviceInfo? {
        all().first { $0.uid == uid }
    }

    static func find(nameContains fragment: String) -> [AudioDeviceInfo] {
        all().filter { $0.name.localizedCaseInsensitiveContains(fragment) }
    }

    /// Creates a public (non-private) aggregate device. Sub-devices keep the
    /// order given; every sub-device except the clock master gets drift
    /// compensation so CoreAudio resamples them against the master clock.
    static func createAggregate(
        name: String,
        uid: String,
        subDeviceUIDs: [String],
        masterUID: String
    ) throws -> AudioDeviceID {
        // Raw dictionary keys documented in <CoreAudio/AudioHardwareBase.h>.
        let subDevices: [[String: Any]] = subDeviceUIDs.map { sub in
            ["uid": sub, "drift": sub == masterUID ? 0 : 1]
        }
        let description: [String: Any] = [
            "name": name,
            "uid": uid,
            "subdevices": subDevices,
            "master": masterUID,
            "private": 0,
        ]
        var aggregateID = AudioDeviceID(0)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr else {
            throw AudioDeviceError.osStatus("AudioHardwareCreateAggregateDevice", status)
        }
        return aggregateID
    }

    static func destroyAggregate(deviceID: AudioDeviceID) throws {
        let status = AudioHardwareDestroyAggregateDevice(deviceID)
        guard status == noErr else {
            throw AudioDeviceError.osStatus("AudioHardwareDestroyAggregateDevice", status)
        }
    }

    static func defaultOutputDevice() -> AudioDeviceID {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    static func setDefaultOutputDevice(_ deviceID: AudioDeviceID) throws {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var value = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &value
        )
        guard status == noErr else {
            throw AudioDeviceError.osStatus("setDefaultOutputDevice", status)
        }
    }

    /// Smaller IO buffers mean lower latency; 256 frames ≈ 5.3 ms at 48 kHz.
    static func setBufferFrameSize(_ deviceID: AudioDeviceID, frames: UInt32) {
        var addr = propertyAddress(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        _ = AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
        )
    }
}
