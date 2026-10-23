import Testing
@testable import PersistedCore

struct LayoutDesktopCatalogTests {
    private func window(_ number: Int, display: String = "laptop", assignment: DesktopAssignment? = nil,
                        bundle: String = "example.editor") -> SavedWindow {
        var saved = CoreFixtures.saved(CoreFixtures.live(number, bundle: bundle))
        saved.displayID = display
        saved.desktopAssignment = assignment
        return saved
    }

    private var snapshot: DesktopSnapshot {
        .init(displays: [
            .init(displayID: "office", desktops: [.init(id: "office-1", ordinal: 0, isActive: true)]),
            .init(displayID: "laptop", desktops: [
                .init(id: "laptop-2", ordinal: 2, isActive: true),
                .init(id: "movie", ordinal: 1, kind: .fullscreen),
                .init(id: "laptop-1", ordinal: 0),
                .init(id: "laptop-3", ordinal: 3)
            ])
        ], separateDisplays: true)
    }

    private func allWindows(_ groups: [LayoutDisplayGroup]) -> [SavedWindow] {
        groups.flatMap(\.desktops).flatMap(\.windows)
    }

    @Test func preservesSavedMonitorOrderAndEmptyDesktopsWithSeparateNumbering() throws {
        let saved = window(1, assignment: .desktop("laptop-2"))
        let layout = Layout(name: "Work", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: snapshot)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        #expect(groups.map(\.id) == ["office", "laptop"])
        #expect(groups[0].display == CoreFixtures.external)
        #expect(groups[1].display == CoreFixtures.primary)
        #expect(groups[1].desktops.map(\.title) == ["Desktop 1", "Full-screen Space 1", "Desktop 2", "Desktop 3"])
        #expect(groups[1].desktops.map(\.kind) == [.ordinary, .fullscreen, .ordinary, .ordinary])
        #expect(groups[1].desktops.map(\.isSavedActive) == [false, false, true, false])
        #expect(groups[1].desktops.map { $0.windows.count } == [0, 0, 1, 0])
        #expect(groups[0].desktops.count == 1)
        #expect(groups[0].desktops[0].windows.isEmpty)
        #expect(!groups[1].sharedAcrossDisplays)
        #expect(allWindows(groups) == [saved])
    }

    @Test func allMembershipKindsAppearExactlyOnceIncludingExcludedApps() throws {
        let windows = [
            window(1, assignment: .desktop("laptop-1")),
            window(2, display: "office", assignment: .desktop("office-1")),
            window(3, display: "office", assignment: .allDesktops),
            window(4),
            window(5, assignment: .desktop("no-longer-recorded")),
            window(6, assignment: .desktop("movie"), bundle: "example.excluded")
        ]
        let layout = Layout(name: "Work", topology: CoreFixtures.topology, windows: windows,
                            excludedBundleIDs: ["example.excluded"], desktopSnapshot: snapshot)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        let displayed = allWindows(groups)
        #expect(displayed.count == windows.count)
        #expect(Set(displayed.map(\.id)) == Set(windows.map(\.id)))
        #expect(groups[0].desktops.map(\.kind) == [.ordinary, .allDesktops])
        #expect(groups[0].desktops[1].windows == [windows[2]])
        #expect(groups[1].desktops.last?.kind == .unassigned)
        #expect(groups[1].desktops.last?.windows == [windows[3], windows[4]])
        #expect(groups[1].desktops.first { $0.kind == .fullscreen }?.windows == [windows[5]])
    }

    @Test func legacyLayoutsUsePhysicalDisplaysWithoutInventingDesktops() {
        let windows = [window(1, display: "office"), window(2), window(3, display: "office")]
        let layout = CoreFixtures.layout(windows: windows)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        #expect(groups.map(\.id) == ["laptop", "office"])
        #expect(groups.allSatisfy { $0.desktops.count == 1 && $0.desktops[0].kind == .unassigned })
        #expect(groups.allSatisfy { !$0.sharedAcrossDisplays && !$0.desktops[0].isSavedActive })
        #expect(groups[0].desktops[0].windows == [windows[1]])
        #expect(groups[1].desktops[0].windows == [windows[0], windows[2]])
        #expect(LayoutDesktopCatalog.groups(for: CoreFixtures.layout(windows: [])).isEmpty)
    }

    @Test func sharedSpacesGroupKnownMembershipOnceAndKeepPhysicalFallbackBuckets() {
        let shared = DesktopSnapshot(displays: [.init(displayID: "laptop", desktops: [
            .init(id: "shared-1", ordinal: 0), .init(id: "shared-2", ordinal: 1, isActive: true)
        ])], separateDisplays: false)
        let windows = [
            window(1, assignment: .desktop("shared-1")),
            window(2, display: "office", assignment: .desktop("shared-1")),
            window(3, display: "office", assignment: .allDesktops),
            window(4, display: "office")
        ]
        let layout = Layout(name: "Shared", topology: CoreFixtures.topology, windows: windows, desktopSnapshot: shared)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        #expect(groups.map(\.id) == ["laptop", "office"])
        #expect(groups[0].sharedAcrossDisplays)
        #expect(!groups[1].sharedAcrossDisplays)
        #expect(groups[0].desktops[0].windows == Array(windows.prefix(2)))
        #expect(groups[0].desktops[1].windows.isEmpty)
        #expect(groups[1].desktops.map(\.kind) == [.allDesktops, .unassigned])
        #expect(groups[1].desktops[0].windows == [windows[2]])
        #expect(groups[1].desktops[1].windows == [windows[3]])
        #expect(allWindows(groups).count == windows.count)
        #expect(Set(allWindows(groups).map(\.id)) == Set(windows.map(\.id)))
    }

    @Test func missingDisplayMetadataKeepsBothKnownAndUnassignedWindowsVisible() {
        let incomplete = DesktopSnapshot(displays: [.init(displayID: "missing-monitor", desktops: [
            .init(id: "missing-desktop", ordinal: 0)
        ])], separateDisplays: true)
        let windows = [
            window(1, display: "missing-monitor", assignment: .desktop("missing-desktop")),
            window(2, display: "z-monitor", assignment: .desktop("dangling")),
            window(3, display: "a-monitor", assignment: .allDesktops)
        ]
        let layout = Layout(name: "Imported", topology: CoreFixtures.topology, windows: windows, desktopSnapshot: incomplete)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        #expect(groups.map(\.id) == ["missing-monitor", "a-monitor", "z-monitor"])
        #expect(groups.allSatisfy { $0.display == nil })
        #expect(groups[0].desktops[0].windows == [windows[0]])
        #expect(groups[1].desktops[0].kind == .allDesktops)
        #expect(groups[2].desktops[0].kind == .unassigned)
        #expect(Set(allWindows(groups).map(\.id)) == Set(windows.map(\.id)))
    }

    @Test func rememberedRevisionUsesItsOwnSnapshotAndCanPreserveEmptyDesktops() {
        let saved = window(1, assignment: .desktop("laptop-1"))
        var layout = Layout(name: "Work", topology: CoreFixtures.topology, windows: [saved], desktopSnapshot: snapshot)
        let remembered = window(2, display: "office", assignment: .desktop("remembered-desktop"))
        let rememberedSnapshot = DesktopSnapshot(displays: [.init(displayID: "office", desktops: [
            .init(id: "remembered-desktop", ordinal: 0)
        ])], separateDisplays: true)
        layout.remembered = .init(windows: [remembered], desktopSnapshot: rememberedSnapshot)
        let groups = LayoutDesktopCatalog.groups(for: layout)
        #expect(groups.map(\.id) == ["office"])
        #expect(groups[0].desktops.count == 1)
        #expect(allWindows(groups) == [remembered])

        layout.remembered = .init(windows: [], desktopSnapshot: snapshot)
        let emptyGroups = LayoutDesktopCatalog.groups(for: layout)
        #expect(emptyGroups.count == 2)
        #expect(emptyGroups.flatMap(\.desktops).count == 5)
        #expect(allWindows(emptyGroups).isEmpty)

        layout.remembered = .init(windows: [window(3)])
        let unknown = LayoutDesktopCatalog.groups(for: layout)
        #expect(unknown.count == 1)
        #expect(unknown[0].desktops.map(\.kind) == [.unassigned])
    }

    @Test func generatedBucketIdentifiersCannotCollideWithSavedDesktopIdentifiers() {
        let collisionID = "bucket:all:laptop"
        let desktopSnapshot = DesktopSnapshot(displays: [.init(displayID: "laptop", desktops: [
            .init(id: collisionID, ordinal: 0)
        ])], separateDisplays: true)
        let windows = [window(1, assignment: .desktop(collisionID)), window(2, assignment: .allDesktops), window(3)]
        let layout = Layout(name: "Work", topology: CoreFixtures.topology, windows: windows, desktopSnapshot: desktopSnapshot)
        let first = LayoutDesktopCatalog.groups(for: layout)
        let second = LayoutDesktopCatalog.groups(for: layout)
        let ids = first.flatMap(\.desktops).map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(first == second)
        #expect(allWindows(first) == windows)
    }
}
