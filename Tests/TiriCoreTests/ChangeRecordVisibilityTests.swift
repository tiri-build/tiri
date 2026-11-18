import Foundation
import Testing
@testable import TiriCore

@Suite struct ChangeRecordVisibilityTests {
    @Test func deletionSurvivesReloadAndKeepsOtherRecordsAndChangeState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("records.json")
        var visibility = try ChangeRecordVisibility(file: file)
        let on = PersonalChange(id: "on", sentence: "Enabled change", commit: "abc", date: Date(),
                                files: 1, added: 1, removed: 0, isOn: true, hasCheck: true, repairTouched: [])
        var off = on
        off.id = "off"
        off.isOn = false
        var repaired = on
        repaired.commit = "new-commit-after-update"
        let records = [on, off]
        #expect(visibility.visible(records) == records)
        try visibility.delete(on.id, file: file)
        try visibility.delete(on.id, file: file)
        let reloaded = try ChangeRecordVisibility(file: file)
        #expect(reloaded.visible([repaired, off]) == [off])
        #expect(records == [on, off])
        #expect(on.isOn)
        var next = reloaded
        try next.delete(off.id, file: file)
        #expect(try ChangeRecordVisibility(file: file).visible(records).isEmpty)
    }

    @Test func failedSaveLeavesRecordVisibleAndBadDataIsNotSilentlyReset() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("records.json")
        var visibility = try ChangeRecordVisibility(file: file)
        #expect(throws: (any Error).self) { try visibility.delete("on", file: folder) }
        #expect(visibility.deleted.isEmpty)
        try Data("invalid".utf8).write(to: file)
        #expect(throws: (any Error).self) { _ = try ChangeRecordVisibility(file: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "invalid")
    }
}
