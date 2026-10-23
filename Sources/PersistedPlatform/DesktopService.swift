import AppKit
import ApplicationServices
import PersistedCore
import PersistedSpacesBridge

/// Value-only native inventory. Numeric Space/window handles never enter the saved model.
struct NativeDesktop: Equatable, Sendable {
    var runtimeID: UInt64
    var kind: DesktopKind
    var uuid: String?
    var active: Bool
}
struct NativeDesktopDisplay: Equatable, Sendable {
    var displayID: String
    var runtimeDisplayID: CGDirectDisplayID
    var desktops: [NativeDesktop]
    var ordinaryDesktops: [NativeDesktop] { desktops.filter { $0.kind == .ordinary } }
}
struct NativeDesktopInventory: Equatable, Sendable {
    var displays: [NativeDesktopDisplay]
    var separateDisplays: Bool
    var allRuntimeIDs: Set<UInt64> { Set(displays.flatMap(\.desktops).map(\.runtimeID)) }
    func desktop(_ id: UInt64) -> NativeDesktop? {
        displays.lazy.flatMap(\.desktops).first { $0.runtimeID == id }
    }
    func display(_ id: String) -> NativeDesktopDisplay? {
        if !separateDisplays { return displays.first }
        return displays.first { $0.displayID == id }
    }
}
struct DesktopEnvironment: Sendable {
    var topology: DisplayTopology
    var separateDisplays: Bool
    var runtimeDisplays: [String: CGDirectDisplayID]

    @MainActor static func current() -> Self {
        let topology = DisplayTopologyService().snapshot()
        var runtime: [String: CGDirectDisplayID] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { continue }
            let string = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            if let display = topology.surfaces.first(where: { $0.uuid?.caseInsensitiveCompare(string) == .orderedSame }) {
                runtime[display.id] = number.uint32Value
            }
        }
        return .init(topology: topology, separateDisplays: NSScreen.screensHaveSeparateSpaces, runtimeDisplays: runtime)
    }

    func read() -> NativeDesktopInventory? {
        guard let raw = PSDesktopCopyManagedDisplays() as? [[String: Any]], !raw.isEmpty else { return nil }
        var displays: [NativeDesktopDisplay] = []
        var seenSpaces: Set<UInt64> = []
        for group in raw {
            guard let nativeDisplay = group["Display Identifier"] as? String,
                  let spaces = group["Spaces"] as? [[String: Any]], !spaces.isEmpty,
                  let current = group["Current Space"] as? [String: Any],
                  let active = Self.spaceID(current) else { return nil }
            let display: DisplayRecord?
            if !separateDisplays && nativeDisplay == "Main" {
                display = topology.surfaces.first(where: \.isPrimary) ?? topology.surfaces.first
            } else {
                display = topology.surfaces.first { $0.uuid?.caseInsensitiveCompare(nativeDisplay) == .orderedSame }
            }
            guard let display, let runtimeDisplay = runtimeDisplays[display.id] else { return nil }
            var desktops: [NativeDesktop] = []
            for space in spaces {
                guard let id = Self.spaceID(space), id > 0, seenSpaces.insert(id).inserted,
                      let type = space["type"] as? NSNumber, type.intValue == 0 || type.intValue == 4 else { return nil }
                desktops.append(.init(runtimeID: id, kind: type.intValue == 0 ? .ordinary : .fullscreen,
                    uuid: space["uuid"] as? String, active: id == active))
            }
            guard desktops.contains(where: { $0.kind == .ordinary }), desktops.filter(\.active).count == 1 else { return nil }
            displays.append(.init(displayID: display.id, runtimeDisplayID: runtimeDisplay, desktops: desktops))
        }
        guard Set(displays.map(\.displayID)).count == displays.count,
              separateDisplays ? Set(displays.map(\.displayID)) == Set(topology.surfaces.map(\.id)) : displays.count == 1 else { return nil }
        // A deterministic physical order keeps consolidated monitor groups predictable.
        displays.sort { lhs, rhs in
            let left = topology.surfaces.first { $0.id == lhs.displayID }!
            let right = topology.surfaces.first { $0.id == rhs.displayID }!
            if left.frame.x != right.frame.x { return left.frame.x < right.frame.x }
            if left.frame.y != right.frame.y { return left.frame.y > right.frame.y }
            return left.id < right.id
        }
        return .init(displays: displays, separateDisplays: separateDisplays)
    }

    private static func spaceID(_ dictionary: [String: Any]) -> UInt64? {
        (dictionary["ManagedSpaceID"] as? NSNumber ?? dictionary["id64"] as? NSNumber)?.uint64Value
    }
}

enum NativeDesktopAccess {
    static func memberships(of window: CGWindowID) -> Set<UInt64>? {
        guard window != 0, let raw = PSDesktopCopyWindowSpaces(window) as? [NSNumber], !raw.isEmpty else { return nil }
        let values = Set(raw.map(\.uint64Value))
        return values.contains(0) ? nil : values
    }

    /// AX access remains on AccessibilityService's executor; references never escape it.
    static func missionControl() -> AXUIElement? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              !dock.isTerminated else { return nil }
        let application = AXUIElementCreateApplication(dock.processIdentifier)
        return children(application).first { identifier($0) == "mc" }
    }

    static func subgroup(_ name: String, display: CGDirectDisplayID) -> AXUIElement? {
        guard let mission = missionControl(),
              let monitor = children(mission).first(where: {
                  identifier($0) == "mc.display" && (attribute($0, "AXDisplayID") as? NSNumber)?.uint32Value == display
              }), let spaces = children(monitor).first(where: { identifier($0) == "mc.spaces" }) else { return nil }
        return children(spaces).first { identifier($0) == name }
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
    private static func identifier(_ element: AXUIElement) -> String? { attribute(element, kAXIdentifierAttribute) as? String }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
