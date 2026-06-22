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
