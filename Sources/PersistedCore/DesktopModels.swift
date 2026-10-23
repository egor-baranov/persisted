import Foundation

public enum DesktopKind: String, Codable, Hashable, Sendable {
    case ordinary, fullscreen
}

/// A logical saved desktop. Runtime Space numbers are deliberately not persisted.
public struct SavedDesktop: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Zero-based Mission Control order, including full-screen Spaces.
    public var ordinal: Int
    public var kind: DesktopKind
    /// A local identity hint, never required to restore an imported layout.
    public var uuidHint: String?
    public var isActive: Bool
    public init(id: String, ordinal: Int, kind: DesktopKind = .ordinary, uuidHint: String? = nil, isActive: Bool = false) {
        self.id = id; self.ordinal = ordinal; self.kind = kind
        self.uuidHint = uuidHint; self.isActive = isActive
    }
}

public struct DesktopDisplay: Codable, Hashable, Sendable {
    public var displayID: String
    public var desktops: [SavedDesktop]
    public init(displayID: String, desktops: [SavedDesktop]) {
        self.displayID = displayID; self.desktops = desktops
    }
    public var ordinaryDesktops: [SavedDesktop] {
        desktops.filter { $0.kind == .ordinary }.sorted { $0.ordinal < $1.ordinal }
    }
}

/// A stable inventory of desktops. An unavailable or incomplete capture is represented by nil,
/// not by an empty snapshot. With shared Spaces, one canonical display owns the inventory.
public struct DesktopSnapshot: Codable, Hashable, Sendable {
    public var displays: [DesktopDisplay]
    public var separateDisplays: Bool
    public init(displays: [DesktopDisplay], separateDisplays: Bool) {
        self.displays = displays; self.separateDisplays = separateDisplays
    }
    public var desktopCount: Int { displays.reduce(0) { $0 + $1.ordinaryDesktops.count } }
    public var totalSpaceCount: Int { displays.reduce(0) { $0 + $1.desktops.count } }
    public var desktopIDs: Set<String> { Set(displays.flatMap(\.desktops).map(\.id)) }

    public func desktop(id: String) -> SavedDesktop? {
        displays.lazy.flatMap(\.desktops).first { $0.id == id }
    }

    public func displayID(for desktopID: String) -> String? {
        displays.first { $0.desktops.contains { $0.id == desktopID } }?.displayID
    }

    public func removingMachineHints() -> Self {
        var result = self
        for displayIndex in result.displays.indices {
            for desktopIndex in result.displays[displayIndex].desktops.indices {
                result.displays[displayIndex].desktops[desktopIndex].uuidHint = nil
            }
        }
        return result
    }
}

/// Nil membership means unknown. All-desktop windows must never be mistaken for unknown windows.
public enum DesktopAssignment: Codable, Hashable, Sendable {
    case desktop(String)
    case allDesktops
}

/// A destination slot whose ordinal counts ordinary desktops only.
public struct DesktopTarget: Hashable, Sendable {
    public var displayID: String
    public var ordinal: Int
    public init(displayID: String, ordinal: Int) { self.displayID = displayID; self.ordinal = ordinal }
}

public struct DesktopRestorePlan: Sendable {
    public var targets: [String: DesktopTarget]
    public var requiredCounts: [String: Int]
    public var activeTargets: [DesktopTarget]
    public var unsupportedDesktopIDs: Set<String>
    /// Other active desktops cannot remain concurrently visible after their monitors are merged.
    public var mergedActiveDesktopIDs: Set<String>
    public init(targets: [String: DesktopTarget] = [:], requiredCounts: [String: Int] = [:],
                activeTargets: [DesktopTarget] = [], unsupportedDesktopIDs: Set<String> = [],
                mergedActiveDesktopIDs: Set<String> = []) {
        self.targets = targets; self.requiredCounts = requiredCounts; self.activeTargets = activeTargets
        self.unsupportedDesktopIDs = unsupportedDesktopIDs; self.mergedActiveDesktopIDs = mergedActiveDesktopIDs
    }
}

public enum DesktopRestorePlanner {
    /// Maps logical desktop groups to ordered slots without using unstable macOS Space numbers.
    /// When monitors are consolidated, their desktops are concatenated in saved display order.
    /// Full-screen Spaces are reported separately; restoring them requires application support.
    public static func plan(snapshot: DesktopSnapshot, displayMapping: [String: String],
                            windowScopeDisplayIDs: Set<String>? = nil) -> DesktopRestorePlan {
        var result = DesktopRestorePlan()
        var activeDisplays: Set<String> = []
        let eligibleMapping = displayMapping.filter { source, _ in
            windowScopeDisplayIDs.map { $0.contains(source) } ?? true
        }
        for display in snapshot.displays {
            // A shared inventory belongs to every physical display, including when the
            // selected windows use a different monitor from its canonical owner.
            let mappedDisplay = snapshot.separateDisplays
                ? eligibleMapping[display.displayID]
                : eligibleMapping[display.displayID] ?? eligibleMapping.sorted { $0.key < $1.key }.first?.value
            guard let targetDisplay = mappedDisplay else { continue }
            let offset = result.requiredCounts[targetDisplay, default: 0]
            let ordinary = display.ordinaryDesktops
            for (index, desktop) in ordinary.enumerated() {
                let target = DesktopTarget(displayID: targetDisplay, ordinal: offset + index)
                result.targets[desktop.id] = target
                if desktop.isActive {
                    if activeDisplays.insert(targetDisplay).inserted { result.activeTargets.append(target) }
                    else { result.mergedActiveDesktopIDs.insert(desktop.id) }
                }
            }
            result.requiredCounts[targetDisplay] = offset + ordinary.count
            result.unsupportedDesktopIDs.formUnion(display.desktops.filter { $0.kind == .fullscreen }.map(\.id))
        }
        return result
    }
}
