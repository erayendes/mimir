import Foundation
import Testing
@testable import Mimir

struct PaceFileWriterTests {
    @Test func privateAtomicSnapshotAndMissingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-pace-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let window = PaceFileWriter.Window(tone: "red", idealPercent: 42.5,
                                           note: "~2 gün kotasız", resetAt: 2_000_200_000)
        try PaceFileWriter.write(["seven_day": window], to: directory, now: now)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PaceFileWriter.write(["seven_day": window], to: directory, now: now)
        let path = directory.appendingPathComponent("mimir-pace.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        let windows = try #require(root["windows"] as? [String: [String: Any]])
        #expect(windows["seven_day"]?["writtenAt"] as? Double == now.timeIntervalSince1970)
        #expect(windows["seven_day"]?["tone"] as? String == "red")
        #expect(windows["seven_day"]?["idealPercent"] as? Double == 42.5)
        #expect(windows["seven_day"]?["note"] as? String == "~2 gün kotasız")
        #expect(windows["seven_day"]?["resetAt"] as? Double == 2_000_200_000)
        try PaceFileWriter.write([:], to: directory, now: now.addingTimeInterval(60))
        let replaced = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect((replaced["windows"] as? [String: Any])?.isEmpty == true)
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["mimir-pace.json"])
    }
}
