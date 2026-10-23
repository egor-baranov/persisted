import Foundation

public enum LayoutDesktopGroupKind: String, Hashable, Sendable {
    case ordinary, fullscreen, allDesktops, unassigned
}

public struct LayoutDesktopGroup: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: LayoutDesktopGroupKind
    public var savedDesktopID: String?
    public var isSavedActive: Bool
    public var windows: [SavedWindow]

    public init(id: String, title: String, kind: LayoutDesktopGroupKind, savedDesktopID: String? = nil, isSavedActive: Bool = false,
                windows: [SavedWindow] = []) {
        self.id = id; self.title = title; self.kind = kind
        self.savedDesktopID = savedDesktopID
        self.isSavedActive = isSavedActive; self.windows = windows
    }
}

public struct LayoutDisplayGroup: Identifiable, Hashable, Sendable {
    /// The saved physical display ID, or the canonical display for shared Spaces.
    public var id: String
    public var display: DisplayRecord?
    public var sharedAcrossDisplays: Bool
    public var desktops: [LayoutDesktopGroup]

    public init(id: String, display: DisplayRecord?, sharedAcrossDisplays: Bool = false,
                desktops: [LayoutDesktopGroup] = []) {
        self.id = id; self.display = display; self.sharedAcrossDisplays = sharedAcrossDisplays
        self.desktops = desktops
    }
}

/// Presentation grouping for the effective revision. Every saved window appears once,
/// including excluded applications, so the interface can offer to include them again.
public enum LayoutDesktopCatalog {
    public static func groups(for layout: Layout) -> [LayoutDisplayGroup] {
        let snapshot = layout.effectiveDesktopSnapshot
        var groups: [LayoutDisplayGroup] = []
        var displayIndices: [String: Int] = [:]
        var desktopIndices: [String: (display: Int, desktop: Int)] = [:]

        // Keep the saved monitor order and all recorded desktops, even when empty.
        for savedDisplay in snapshot?.displays ?? [] {
            let displayIndex: Int
            if let existing = displayIndices[savedDisplay.displayID] {
                displayIndex = existing
            } else {
                displayIndex = groups.count
                displayIndices[savedDisplay.displayID] = displayIndex
                groups.append(.init(id: savedDisplay.displayID,
                                    display: layout.topology.displays.first { $0.id == savedDisplay.displayID },
                                    sharedAcrossDisplays: snapshot?.separateDisplays == false))
            }
            var ordinaryCount = groups[displayIndex].desktops.filter { $0.kind == .ordinary }.count
            var fullscreenCount = groups[displayIndex].desktops.filter { $0.kind == .fullscreen }.count
            let ordered = savedDisplay.desktops.sorted {
                $0.ordinal == $1.ordinal ? $0.id < $1.id : $0.ordinal < $1.ordinal
            }
            for desktop in ordered {
                // Loaded libraries validate unique IDs. This also keeps a malformed,
                // in-memory preview from duplicating windows or SwiftUI identifiers.
                guard desktopIndices[desktop.id] == nil else { continue }
                let kind: LayoutDesktopGroupKind
                let title: String
                switch desktop.kind {
                case .ordinary:
                    ordinaryCount += 1; kind = .ordinary; title = "Desktop \(ordinaryCount)"
                case .fullscreen:
                    fullscreenCount += 1; kind = .fullscreen; title = "Full-screen Space \(fullscreenCount)"
                }
                desktopIndices[desktop.id] = (displayIndex, groups[displayIndex].desktops.count)
                groups[displayIndex].desktops.append(.init(id: "desktop:\(desktop.id)", title: title,
                                                         kind: kind, savedDesktopID: desktop.id, isSavedActive: desktop.isActive))
            }
        }

        var sticky: [String: [SavedWindow]] = [:]
        var unassigned: [String: [SavedWindow]] = [:]
        for window in layout.effectiveWindows {
            switch window.desktopAssignment {
            case .desktop(let id):
                if let destination = desktopIndices[id] {
                    groups[destination.display].desktops[destination.desktop].windows.append(window)
                } else {
                    unassigned[window.displayID, default: []].append(window)
                }
            case .allDesktops:
                sticky[window.displayID, default: []].append(window)
            case nil:
                unassigned[window.displayID, default: []].append(window)
            }
        }

        // Unknown and sticky memberships retain their physical display. In shared
        // Spaces mode, known desktop windows already belong to the canonical group.
        let neededDisplays = Set(sticky.keys).union(unassigned.keys)
        let topologyOrder = layout.topology.displays.map(\.id).filter { neededDisplays.contains($0) }
        let missingIDs = neededDisplays.subtracting(topologyOrder).sorted()
        for id in topologyOrder + missingIDs where displayIndices[id] == nil {
            displayIndices[id] = groups.count
            groups.append(.init(id: id, display: layout.topology.displays.first { $0.id == id }))
        }
        for index in groups.indices {
            let id = groups[index].id
            if let windows = sticky[id] {
                groups[index].desktops.append(.init(id: "bucket:all:\(id)", title: "All desktops",
                                                   kind: .allDesktops, windows: windows))
            }
            if let windows = unassigned[id] {
                groups[index].desktops.append(.init(id: "bucket:unassigned:\(id)", title: "Desktop not recorded",
                                                   kind: .unassigned, windows: windows))
            }
        }
        return groups
    }
}
