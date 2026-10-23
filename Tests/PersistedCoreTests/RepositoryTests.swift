import Foundation
import Testing
@testable import PersistedCore

struct RepositoryTests {
    private func fixture() -> Library { var value = Library(); value.layouts = [CoreFixtures.layout()]; return value }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Persisted-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    @Test func atomicRoundTripAndPreviousVersion() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let repo = LayoutRepository(directory: url)
        _ = try await repo.load()
        let first = fixture(); try await repo.save(first)
        var second = first; second.layouts[0].name = "Focus"; try await repo.save(second)
        let fresh = LayoutRepository(directory: url)
        #expect(try await fresh.load().layouts[0].name == "Focus")
        let previous = try LayoutRepository.decode(Data(contentsOf: url.appendingPathComponent("Library.previous.json")))
        #expect(previous.layouts[0].name == first.layouts[0].name)
    }
    @Test func encodedSizeBoundaryIsIdenticalForWritingAndReading() throws {
        let value = fixture()
        let encoded = try LayoutRepository.encode(value)
        let exactLimit = encoded.count
        #expect(try LayoutRepository.encode(value, byteLimit: exactLimit) == encoded)
        #expect(try LayoutRepository.decode(encoded, byteLimit: exactLimit).layouts[0].id == value.layouts[0].id)
        #expect(throws: RepositoryError.self) {
            try LayoutRepository.encode(value, byteLimit: exactLimit - 1)
        }
        #expect(throws: RepositoryError.self) {
            try LayoutRepository.decode(encoded, byteLimit: exactLimit - 1)
        }
    }
    @Test func repeatedOversizedSavesPreservePrimaryBackupAndLaterValidSaves() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        var first = fixture(); first.layouts[0].name = "First"
        var second = first; second.layouts[0].name = "Second"
        var third = first; third.layouts[0].name = "Third"
        let firstData = try LayoutRepository.encode(first)
        let secondData = try LayoutRepository.encode(second)
        let byteLimit = max(firstData.count, secondData.count) + 8
        let repo = LayoutRepository(directory: url, byteLimit: byteLimit)
        _ = try await repo.load()
        try await repo.save(first)
        try await repo.save(second)

        var oversized = second
        oversized.layouts[0].history = [second.layouts[0].saved]
        #expect(try LayoutRepository.encode(oversized).count > byteLimit)
        let primary = url.appendingPathComponent("Library.json")
        let backup = url.appendingPathComponent("Library.previous.json")
        for _ in 0..<2 {
            do {
                try await repo.save(oversized)
                Issue.record("An oversized library must be rejected before replacing saved files")
            } catch RepositoryError.sizeLimitExceeded(let limit) {
                #expect(limit == byteLimit)
            }
            #expect(try Data(contentsOf: primary) == secondData)
            #expect(try Data(contentsOf: backup) == firstData)
        }
        #expect(try await LayoutRepository(directory: url, byteLimit: byteLimit).load().layouts[0].name == "Second")
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() == ["Library.json", "Library.previous.json"])

        // A rejected save must neither lock writes nor become the next last-good backup.
        try await repo.save(third)
        #expect(try Data(contentsOf: backup) == secondData)
        #expect(try await LayoutRepository(directory: url, byteLimit: byteLimit).load().layouts[0].name == "Third")
    }
    @Test func oversizedFirstSaveDoesNotCreateUnreadableLibrary() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let valid = fixture()
        let byteLimit = try LayoutRepository.encode(valid).count
        let repo = LayoutRepository(directory: url, byteLimit: byteLimit)
        _ = try await repo.load()
        var oversized = valid
        oversized.layouts[0].history = [valid.layouts[0].saved]
        await #expect(throws: RepositoryError.self) { try await repo.save(oversized) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty)
        try await repo.save(valid)
        #expect(try await LayoutRepository(directory: url, byteLimit: byteLimit).load().layouts[0].id == valid.layouts[0].id)
    }
    @Test func corruptPrimaryRecoversBackupAndPreservesEvidence() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let repo = LayoutRepository(directory: url); _ = try await repo.load()
        let first = fixture(); try await repo.save(first)
        var second = first; second.layouts[0].name = "Second"; try await repo.save(second)
        try Data("broken".utf8).write(to: url.appendingPathComponent("Library.json"))
        let recovery = LayoutRepository(directory: url)
        #expect(try await recovery.load().layouts[0].name == first.layouts[0].name)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.path).contains { $0.hasPrefix("Library.corrupt-") })
        #expect(await recovery.recoveryNotice != nil)
    }
    @Test func futureSchemaCannotBeOverwritten() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let future = Data("{\"schemaVersion\":999}".utf8)
        try future.write(to: url.appendingPathComponent("Library.json"))
        let repo = LayoutRepository(directory: url)
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
        await #expect(throws: (any Error).self) { try await repo.save(fixture()) }
        #expect(try Data(contentsOf: url.appendingPathComponent("Library.json")) == future)
    }
    @Test func missingPrimaryRecoversInterruptedSave() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let first = fixture()
        try LayoutRepository.encode(first).write(to: url.appendingPathComponent("Library.previous.json"))
        #expect(try await LayoutRepository(directory: url).load().layouts[0].id == first.layouts[0].id)
    }
    @Test func futureSchemaBackupWithoutPrimaryLocksAllWrites() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        let future = Data("{\"schemaVersion\":999}".utf8)
        let backup = url.appendingPathComponent("Library.previous.json")
        try future.write(to: backup)
        let repo = LayoutRepository(directory: url)
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
        await #expect(throws: (any Error).self) { try await repo.save(fixture()) }
        #expect(try Data(contentsOf: backup) == future)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("Library.json").path))
    }
    @Test func invalidGeometryAndEmptyReplacementAreRejected() throws {
        var value = fixture(); value.layouts[0].saved.windows[0].frame.x = .infinity
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.layouts[0].saved.windows = []
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.layouts[0].saved.windows[0].normalizedFrame.width = -1
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
    }
    @Test func inconsistentRelativeOrNormalizedCoordinatesAreRejected() throws {
        var value = fixture()
        value.layouts[0].saved.windows[0].relativeFrame.x += 25
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture()
        value.layouts[0].saved.windows[0].normalizedFrame.width += 0.1
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture()
        value.layouts[0].saved.windows[0].sourceUsableFrame.height += 20
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
    }
    @Test func consistentRememberedGeometryMayDescribeChangedResolution() throws {
        var value = fixture()
        var changed = CoreFixtures.topology
        changed.displays[0].frame.width = 1280
        changed.displays[0].usableFrame.width = 1280
        var observed = CoreFixtures.saved(CoreFixtures.live(frame: Rect(x: 80, y: 100, width: 600, height: 450)), topology: changed)
        observed.id = value.layouts[0].saved.windows[0].id
        value.layouts[0].remembered = LayoutRevision(windows: [observed])
        try LayoutRepository.validate(value)
        #expect(value.layouts[0].topology != changed)
        #expect(value.layouts[0].remembered?.windows[0].sourceUsableFrame.width == 1280)
    }
    @Test func importsRequireMappingAndDisableLearningAndLaunching() throws {
        var value = fixture()
        value.layouts[0].options.rememberAdjustments = true
        value.layouts[0].options.launchMissingApplications = true
        let imported = try LayoutRepository.importPreview(LayoutRepository.encode(value))
        #expect(imported[0].id != value.layouts[0].id)
        #expect(imported[0].importedNeedsMapping)
        #expect(!imported[0].options.rememberAdjustments)
        #expect(!imported[0].options.launchMissingApplications)
    }
    @Test func invalidMappingsAndImportedPreferencesAreRejected() throws {
        var value = fixture()
        value.displayMappings = [.init(layoutID: value.layouts[0].id, targetSetupKey: "target", assignments: ["nonexistent": "display"])]
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.layouts[0].importedNeedsMapping = true
        value.preferredLayouts["setup"] = value.layouts[0].id
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
    }
    @Test func unrelatedCorruptionWithoutBackupLocksWrites() async throws {
        let url = try directory(); defer { try? FileManager.default.removeItem(at: url) }
        try Data("{}".utf8).write(to: url.appendingPathComponent("Library.json"))
        let repo = LayoutRepository(directory: url)
        await #expect(throws: (any Error).self) { _ = try await repo.load() }
        await #expect(throws: (any Error).self) { try await repo.save(fixture()) }
    }
}
