import Foundation

/// Persisted at ~/.config/monitor-speakers/config.json.
///
/// Channel layout of the aggregate device follows sub-device order:
/// BlackHole occupies channels 0-1 (kept silent to avoid a feedback loop),
/// each monitor occupies the next stereo pair. `leftPair` etc. hold the
/// first channel index of the pair assigned to that physical position.
struct RouterConfig: Codable {
    var aggregateName = "LG TriSpeakers"
    var aggregateUID = "com.monitor-speakers.aggregate"
    var blackholeName = "BlackHole 2ch"
    var monitorNameFilter = "LG"
    var masterGain: Float = 1.0
    var leftPair = 2
    var centerPair = 4
    var rightPair = 6
    /// true: center monitor keeps its own L/R stereo (recommended — you sit
    /// in front of it, side monitors widen the field); false: mono (L+R)/2.
    var centerStereo = true
    /// Auto-switch default output: all monitors present -> BlackHole,
    /// none present -> built-in speakers.
    var autoSwitch = true
    var requiredMonitors = 3

    enum CodingKeys: String, CodingKey {
        case aggregateName, aggregateUID, blackholeName, monitorNameFilter
        case masterGain, leftPair, centerPair, rightPair, centerStereo
        case autoSwitch, requiredMonitors
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RouterConfig()
        aggregateName = try c.decodeIfPresent(String.self, forKey: .aggregateName) ?? defaults.aggregateName
        aggregateUID = try c.decodeIfPresent(String.self, forKey: .aggregateUID) ?? defaults.aggregateUID
        blackholeName = try c.decodeIfPresent(String.self, forKey: .blackholeName) ?? defaults.blackholeName
        monitorNameFilter = try c.decodeIfPresent(String.self, forKey: .monitorNameFilter) ?? defaults.monitorNameFilter
        masterGain = try c.decodeIfPresent(Float.self, forKey: .masterGain) ?? defaults.masterGain
        leftPair = try c.decodeIfPresent(Int.self, forKey: .leftPair) ?? defaults.leftPair
        centerPair = try c.decodeIfPresent(Int.self, forKey: .centerPair) ?? defaults.centerPair
        rightPair = try c.decodeIfPresent(Int.self, forKey: .rightPair) ?? defaults.rightPair
        centerStereo = try c.decodeIfPresent(Bool.self, forKey: .centerStereo) ?? defaults.centerStereo
        autoSwitch = try c.decodeIfPresent(Bool.self, forKey: .autoSwitch) ?? defaults.autoSwitch
        requiredMonitors = try c.decodeIfPresent(Int.self, forKey: .requiredMonitors) ?? defaults.requiredMonitors
    }

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/monitor-speakers/config.json")
    }

    static func load() -> RouterConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(RouterConfig.self, from: data)
        else {
            return RouterConfig()
        }
        return config
    }

    func save() throws {
        let dir = Self.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.fileURL)
    }

    /// Mixing matrix: output channel index -> (gain from input L, gain from input R).
    /// Unmapped channels (including BlackHole's own output pair) stay silent.
    func mixingMatrix() -> [Int: (l: Float, r: Float)] {
        var matrix: [Int: (l: Float, r: Float)] = [:]
        for ch in [leftPair, leftPair + 1] { matrix[ch] = (l: 1.0, r: 0.0) }
        for ch in [rightPair, rightPair + 1] { matrix[ch] = (l: 0.0, r: 1.0) }
        if centerStereo {
            matrix[centerPair] = (l: 1.0, r: 0.0)
            matrix[centerPair + 1] = (l: 0.0, r: 1.0)
        } else {
            for ch in [centerPair, centerPair + 1] { matrix[ch] = (l: 0.5, r: 0.5) }
        }
        return matrix
    }
}
