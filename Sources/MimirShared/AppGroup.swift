import Foundation

/// The App Group shared between the Mimir app and its widget extension. Both targets read the
/// group identifier from their own Info.plist (`MimirAppGroup`), set per build (dev vs release),
/// so the entitlement and the runtime lookup always agree. The container lives at
/// `~/Library/Group Containers/<TeamID>.<group>/`; the widget (sandboxed) can only reach the
/// app's data through it.
public enum MimirAppGroup {
    public static var identifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "MimirAppGroup") as? String) ?? "group.com.erayendes.mimir"
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

/// P0 spike: the smallest possible app→widget handoff over the App Group container. The app writes
/// an Int, the widget reads it. Proves the entitlement + container + signing chain end to end
/// before any real payload or UI is built. Replaced by `WidgetPayload` in P1.
public enum WidgetSpike {
    private static var url: URL? { MimirAppGroup.containerURL?.appendingPathComponent("spike.json") }

    public static func write(_ n: Int) {
        guard let url else { return }
        try? Data("\(n)".utf8).write(to: url, options: .atomic)
    }

    public static func read() -> Int? {
        guard let url, let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
