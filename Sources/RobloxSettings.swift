import Foundation

/// Low-performance settings applied to windows this app launches.
struct PerfSettings {
    var enabled: Bool
    var volume: Int     // Roblox slider, 0...10
    var graphics: Int   // Roblox graphics quality, 1...10
    var cap60: Bool

    static let defaults: [String: Any] = ["perfEnabled": true, "perfVolume": 0, "perfGraphics": 1, "perfCap60": false]

    static var current: PerfSettings {
        let d = UserDefaults.standard
        d.register(defaults: defaults)
        return PerfSettings(enabled: d.bool(forKey: "perfEnabled"),
                            volume: min(10, max(0, d.integer(forKey: "perfVolume"))),
                            graphics: min(10, max(1, d.integer(forKey: "perfGraphics"))),
                            cap60: d.bool(forKey: "perfCap60"))
    }

    /// Values to write into GlobalBasicSettings, keyed by setting name.
    var values: [String: String] {
        var v = [
            "MasterVolume": String(format: "%.1f", Double(volume) / 10),
            "SavedQualityLevel": String(graphics),
        ]
        // GraphicsQualityLevel uses Roblox's internal 1-21 scale; only pin it for the lowest level.
        if graphics == 1 { v["GraphicsQualityLevel"] = "1" }
        if cap60 { v["FramerateCap"] = "60" }
        return v
    }
}

/// Reads and patches Roblox's GlobalBasicSettings_<n>.xml. Every Roblox window on this Mac
/// shares this file and reads it once at startup.
enum RobloxSettingsFile {
    /// (XML tag, setting name) for everything this app may change.
    static let managed: [(tag: String, name: String)] = [
        ("float", "MasterVolume"),
        ("token", "SavedQualityLevel"),
        ("int", "GraphicsQualityLevel"),
        ("int", "FramerateCap"),
    ]
    private static let snapshotKey = "robloxSettingsSnapshot"

    static var url: URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Roblox")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // Pick the highest-numbered player file (not the Studio one).
        let best = files
            .filter { $0.hasPrefix("GlobalBasicSettings_") && $0.hasSuffix(".xml") && !$0.contains("Studio") }
            .max { version($0) < version($1) }
        return best.map { dir.appendingPathComponent($0) }
    }

    private static func version(_ name: String) -> Int {
        Int(name.dropFirst("GlobalBasicSettings_".count).dropLast(".xml".count)) ?? 0
    }

    private static func pattern(_ tag: String, _ name: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: "(<\(tag) name=\"\(name)\">)([^<]*)(</\(tag)>)")
    }

    static func read() -> [String: String] {
        guard let url, let xml = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for (tag, name) in managed {
            let re = pattern(tag, name)
            if let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
               let r = Range(m.range(at: 2), in: xml) {
                out[name] = String(xml[r])
            }
        }
        return out
    }

    @discardableResult
    static func write(_ values: [String: String]) -> Bool {
        guard let url, var xml = try? String(contentsOf: url, encoding: .utf8) else { return false }
        for (tag, name) in managed {
            guard let value = values[name] else { continue }
            let re = pattern(tag, name)
            xml = re.stringByReplacingMatches(in: xml, range: NSRange(xml.startIndex..., in: xml),
                                              withTemplate: "$1\(NSRegularExpression.escapedTemplate(for: value))$3")
        }
        return (try? xml.write(to: url, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: Snapshot of the user's own values

    static var hasSnapshot: Bool { UserDefaults.standard.dictionary(forKey: snapshotKey) != nil }

    /// Saves the user's values once, before the first low-performance launch.
    static func snapshotIfNeeded() {
        guard !hasSnapshot else { return }
        let current = read()
        if !current.isEmpty { UserDefaults.standard.set(current, forKey: snapshotKey) }
    }

    /// Writes the user's values back. Keeps the snapshot unless `clear` is true.
    @discardableResult
    static func restore(clear: Bool) -> Bool {
        guard let snap = UserDefaults.standard.dictionary(forKey: snapshotKey) as? [String: String] else { return false }
        let ok = write(snap)
        if clear { UserDefaults.standard.removeObject(forKey: snapshotKey) }
        return ok
    }
}
