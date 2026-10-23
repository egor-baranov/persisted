import Foundation
import Testing
@testable import PersistedCore

struct CatalogScheduleTests {
    private func fixture() -> Library {
        var library = Library()
        library.layouts = [CoreFixtures.layout()]
        library.layouts[0].saved.date = Date(timeIntervalSince1970: 1_700_000_000)
        return library
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func legacyLibraryDecodesWithoutLosingSavedContent() throws {
        var original = fixture()
        original.layouts[0].remembered = LayoutRevision(date: Date(timeIntervalSince1970: 1_700_000_100), windows: original.layouts[0].saved.windows)
        original.layouts[0].history = [original.layouts[0].saved]
        original.layouts[0].options.rememberAdjustments = true
        original.settings.onboardingCompleted = true
        original.preferredLayouts["desk"] = original.layouts[0].id
        var json = try #require(JSONSerialization.jsonObject(with: LayoutRepository.encode(original)) as? [String: Any])
        json.removeValue(forKey: "schedules")
        json.removeValue(forKey: "displayProfileNames")
        var layouts = try #require(json["layouts"] as? [[String: Any]])
        layouts[0].removeValue(forKey: "iconName")
        layouts[0].removeValue(forKey: "hotkey")
        layouts[0].removeValue(forKey: "excludedBundleIDs")
        json["layouts"] = layouts

        let decoded = try LayoutRepository.decode(JSONSerialization.data(withJSONObject: json))
        #expect(decoded.layouts == original.layouts)
        #expect(decoded.preferredLayouts == original.preferredLayouts)
        #expect(decoded.settings == original.settings)
        #expect(decoded.schedules.isEmpty)
        #expect(decoded.displayProfileNames.isEmpty)
        #expect(decoded.layouts[0].iconName == "rectangle.3.group")
        #expect(decoded.layouts[0].hotkey == nil)
        #expect(decoded.layouts[0].excludedBundleIDs.isEmpty)
    }

    @Test func newMetadataRoundTripsWithoutFilteringStoredWindows() throws {
        var original = fixture()
        original.layouts[0].iconName = "terminal"
        original.layouts[0].hotkey = LayoutHotkey(keyCode: 18, modifiers: 256 | 512, key: "1")
        original.layouts[0].excludedBundleIDs = ["example.editor"]
        original.schedules = [.init(name: "Morning", layoutID: original.layouts[0].id, weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 720)]
        original.displayProfileNames = ["desk-profile": "Desk"]
        let decoded = try LayoutRepository.decode(LayoutRepository.encode(original))
        #expect(decoded.layouts == original.layouts)
        #expect(decoded.layouts[0].effectiveWindows.count == 1)
        #expect(decoded.schedules == original.schedules)
        #expect(decoded.displayProfileNames == original.displayProfileNames)
        #expect(decoded.layouts[0].hotkey?.displayString == "⇧⌘1")
    }

    @Test func catalogIncludesEverySetupInSavedOrder() {
        var desk = CoreFixtures.layout()
        desk.name = "Coding"
        var laptop = CoreFixtures.layout(topology: DisplayTopology(displays: [CoreFixtures.primary], lid: .open))
        laptop.name = "Writing"
        let layouts = [desk, laptop]
        #expect(LayoutCatalog.filteredLayouts(layouts, query: "").map(\.id) == layouts.map(\.id))
        #expect(LayoutCatalog.filteredLayouts(layouts, query: " \n ").map(\.id) == layouts.map(\.id))
        #expect(LayoutCatalog.filteredLayouts(layouts, query: "editor").map(\.id) == layouts.map(\.id))
        #expect(LayoutCatalog.filteredLayouts(layouts, query: "writing EDITOR").map(\.id) == [laptop.id])
        #expect(LayoutCatalog.filteredLayouts(layouts, query: "missing").isEmpty)
    }

    @Test func shortcutsRejectUnsafeAndUnknownCombinations() {
        #expect(LayoutHotkey(keyCode: 18, modifiers: 4096, key: "1").isValid)
        #expect(LayoutHotkey(keyCode: 122, modifiers: 0, key: "F1").isValid)
        #expect(LayoutHotkey(keyCode: 90, modifiers: 512, key: "F20").isValid)
        #expect(!LayoutHotkey(keyCode: 18, modifiers: 0, key: "1").isValid)
        #expect(!LayoutHotkey(keyCode: 18, modifiers: 2048, key: "1").isValid)
        #expect(!LayoutHotkey(keyCode: 18, modifiers: 512, key: "1").isValid)
        #expect(!LayoutHotkey(keyCode: 18, modifiers: 256 | 1, key: "1").isValid)
        #expect(!LayoutHotkey(keyCode: 128, modifiers: 256, key: "1").isValid)
        #expect(!LayoutHotkey(keyCode: 18, modifiers: 256, key: "\n").isValid)
    }

    @Test func invalidMetadataAndShortcutCollisionsAreRejected() throws {
        var value = fixture()
        value.layouts[0].iconName = " "
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.layouts[0].excludedBundleIDs = [""]
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.displayProfileNames["desk"] = ""
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture(); value.layouts[0].hotkey = .init(keyCode: 18, modifiers: 2048, key: "1")
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
        value = fixture()
        var duplicate = value.layouts[0]; duplicate.id = UUID()
        value.layouts[0].hotkey = .init(keyCode: 18, modifiers: 256, key: "1")
        duplicate.hotkey = .init(keyCode: 18, modifiers: 256, key: "Different label")
        value.layouts.append(duplicate)
        #expect(throws: (any Error).self) { try LayoutRepository.validate(value) }
    }

    @Test func malformedNewFieldIsNotSilentlyDiscarded() throws {
        var json = try #require(JSONSerialization.jsonObject(with: LayoutRepository.encode(fixture())) as? [String: Any])
        json["schedules"] = "not an array"
        #expect(throws: (any Error).self) { try LayoutRepository.decode(JSONSerialization.data(withJSONObject: json)) }
    }

    @Test func importsPreservePresentationButClearShortcutsAndAutomaticRules() throws {
        var library = fixture()
        library.layouts[0].iconName = "book"
        library.layouts[0].hotkey = .init(keyCode: 18, modifiers: 256, key: "1")
        library.layouts[0].excludedBundleIDs = ["example.editor"]
        library.schedules = [.init(name: "Morning", layoutID: library.layouts[0].id, weekdays: [2], startMinute: 540, endMinute: 720)]
        let imported = try LayoutRepository.importPreview(LayoutRepository.encode(library))
        #expect(imported.count == 1)
        #expect(imported[0].hotkey == nil)
        #expect(imported[0].id != library.layouts[0].id)
        #expect(imported[0].iconName == "book")
        #expect(imported[0].excludedBundleIDs == ["example.editor"])
        #expect(imported[0].importedNeedsMapping)
    }

    @Test func invalidSchedulesAreRejectedIncludingDanglingReferences() throws {
        var library = fixture()
        let valid = LayoutSchedule(name: "Morning", layoutID: library.layouts[0].id, weekdays: [2], startMinute: 540, endMinute: 720)
        var candidates: [LayoutSchedule] = []
        var item = valid; item.weekdays = []; candidates.append(item)
        item = valid; item.weekdays = [0, 8]; candidates.append(item)
        item = valid; item.startMinute = -1; candidates.append(item)
        item = valid; item.endMinute = 1440; candidates.append(item)
        item = valid; item.endMinute = item.startMinute; candidates.append(item)
        item = valid; item.name = " "; candidates.append(item)
        item = valid; item.layoutID = UUID(); candidates.append(item)
        for invalid in candidates {
            library.schedules = [invalid]
            #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        }
        library.schedules = [valid, valid]
        #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        library.schedules = [valid]
        library.layouts[0].importedNeedsMapping = true
        #expect(throws: (any Error).self) { try LayoutRepository.validate(library) }
        library.schedules[0].enabled = false
        try LayoutRepository.validate(library)
    }

    @Test func dayScheduleUsesStartInclusiveEndExclusiveAndWeekdays() {
        let schedule = LayoutSchedule(name: "Morning", layoutID: UUID(), weekdays: [2], startMinute: 540, endMinute: 720)
        func occurrence(_ date: Date) -> ScheduleOccurrence? { ScheduleMatcher.activeOccurrence(schedules: [schedule], at: date, calendar: calendar) }
        #expect(occurrence(date(19, 8, 59)) == nil)
        #expect(occurrence(date(19, 9))?.startDate == date(19, 9))
        #expect(occurrence(date(19, 11, 59))?.layoutID == schedule.layoutID)
        #expect(occurrence(date(19, 12)) == nil)
        #expect(occurrence(date(20, 10)) == nil)
    }

    @Test func overnightScheduleBelongsToItsStartingWeekday() {
        let schedule = LayoutSchedule(name: "Night", layoutID: UUID(), weekdays: [2], startMinute: 22 * 60, endMinute: 2 * 60)
        func occurrence(_ date: Date) -> ScheduleOccurrence? { ScheduleMatcher.activeOccurrence(schedules: [schedule], at: date, calendar: calendar) }
        #expect(occurrence(date(19, 1)) == nil)
        #expect(occurrence(date(19, 21, 59)) == nil)
        #expect(occurrence(date(19, 22))?.startDate == date(19, 22))
        #expect(occurrence(date(20, 0))?.startDate == date(19, 22))
        #expect(occurrence(date(20, 1, 59))?.startDate == date(19, 22))
        #expect(occurrence(date(20, 2)) == nil)
        #expect(occurrence(date(20, 22)) == nil)
    }

    @Test func overlappingSchedulesUseSavedOrderAndIgnoreDisabledRules() {
        let first = LayoutSchedule(name: "First", layoutID: UUID(), weekdays: [2], startMinute: 540, endMinute: 720)
        var second = first; second.id = UUID(); second.layoutID = UUID()
        #expect(ScheduleMatcher.activeOccurrence(schedules: [first, second], at: date(19, 10), calendar: calendar)?.scheduleID == first.id)
        #expect(ScheduleMatcher.activeOccurrence(schedules: [second, first], at: date(19, 10), calendar: calendar)?.scheduleID == second.id)
        var disabled = first; disabled.enabled = false
        #expect(ScheduleMatcher.activeOccurrence(schedules: [disabled, second], at: date(19, 10), calendar: calendar)?.scheduleID == second.id)
    }

    @Test func overnightRangeAcrossSpringDSTKeepsLocalEndTime() {
        let schedule = LayoutSchedule(name: "Night", layoutID: UUID(), weekdays: [7], startMinute: 22 * 60, endMinute: 4 * 60)
        let occurrence = ScheduleMatcher.activeOccurrence(schedules: [schedule], at: date(29, 3, 30, month: 3), calendar: calendar)
        #expect(occurrence?.startDate == date(28, 22, month: 3))
        #expect(ScheduleMatcher.activeOccurrence(schedules: [schedule], at: date(29, 4, month: 3), calendar: calendar) == nil)
    }

    @Test func overnightRangeAcrossAutumnDSTHasOneStableOccurrence() {
        let schedule = LayoutSchedule(name: "Night", layoutID: UUID(), weekdays: [7], startMinute: 22 * 60, endMinute: 4 * 60)
        let firstTwoThirty = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: date(25), repeatedTimePolicy: .first)!
        let secondTwoThirty = calendar.date(bySettingHour: 2, minute: 30, second: 0, of: date(25), repeatedTimePolicy: .last)!
        #expect(firstTwoThirty != secondTwoThirty)
        #expect(ScheduleMatcher.activeOccurrence(schedules: [schedule], at: firstTwoThirty, calendar: calendar)?.startDate == date(24, 22))
        #expect(ScheduleMatcher.activeOccurrence(schedules: [schedule], at: secondTwoThirty, calendar: calendar)?.startDate == date(24, 22))
    }
}
