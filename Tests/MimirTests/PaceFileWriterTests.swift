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
        #expect(windows["seven_day"]?["remainingPercent"] == nil)
        try PaceFileWriter.write([:], to: directory, now: now.addingTimeInterval(60))
        let replaced = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        #expect((replaced["windows"] as? [String: Any])?.isEmpty == true)
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["mimir-pace.json"])
    }

    @Test func fableScopedWindowUsesItsOwnPercentResetAndPaceForExtraClaudeAccount() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let reset = now.addingTimeInterval(3.5 * 86_400)
        let service = ServiceStatus(name: "Claude Work", iconName: "claude",
            sessionResetAt: now.addingTimeInterval(3600), weeklyResetAt: reset,
            sessionRemainingPercent: 70, weeklyRemainingPercent: 80,
            models: [ModelStatus(name: "Fable", remainingPercent: 40, resetAt: reset)],
            isAvailable: true, statusNote: nil)
        let provider = try #require(WidgetBridge.makePayload([service], generatedAt: now).providers.first)
        let windows = PaceFileWriter.windows(service: service, provider: provider,
                                             keys: { _ in "seven_day" }, now: now)
        let fable = try #require(windows["seven_day_fable"])
        let pace = try #require(QuotaPace.compute(remaining: 40, resetAt: reset,
                                                  window: 7 * 86_400, now: now))
        #expect(fable.remainingPercent == 40)
        #expect(fable.resetAt == reset.timeIntervalSince1970)
        #expect(fable.tone == "red")
        #expect(fable.idealPercent == pace.idealPercent)
        #expect(fable.note == pace.note)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimir-fable-pace-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PaceFileWriter.write(windows, to: directory, now: now)
        let root = try #require(JSONSerialization.jsonObject(with:
            Data(contentsOf: directory.appendingPathComponent("mimir-pace.json"))) as? [String: Any])
        let stored = try #require((root["windows"] as? [String: [String: Any]])?["seven_day_fable"])
        #expect(stored["remainingPercent"] as? Int == 40)
        #expect(stored["resetAt"] as? Double == reset.timeIntervalSince1970)
        #expect(stored["writtenAt"] as? Double == now.timeIntervalSince1970)
    }
}
