import AppKit
import ApplicationServices
import ColorSync
import CoreGraphics
import PersistedCore

@MainActor
public final class DisplayTopologyService: TopologyProviding {
    private let lidProvider = LidStateProvider()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var handler: (@MainActor @Sendable (SystemEvent) -> Void)?
    private var registered = false
    private var permissionTimer: Timer?
    private var lastPermission = false
    public init() {}

    public func snapshot() -> DisplayTopology {
        let online = displayList(active: false)
        let active = Set(displayList(active: true))
        let screens = NSScreen.screens
        let screenByID: [CGDirectDisplayID: NSScreen] = Dictionary(uniqueKeysWithValues: screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (number.uint32Value, screen)
        })
        let allIDs = Set(online).union(active).union(screenByID.keys).sorted()
        var identities: [CGDirectDisplayID: String] = [:]
        var uuids: [CGDirectDisplayID: String] = [:]
        for id in allIDs {
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuids[id] = CFUUIDCreateString(kCFAllocatorDefault, uuid) as String
            }
            let vendor = CGDisplayVendorNumber(id), model = CGDisplayModelNumber(id), serial = CGDisplaySerialNumber(id)
            if let uuid = uuids[id] { identities[id] = "uuid:\(uuid)" }
            else if serial != 0 { identities[id] = "hardware:\(vendor):\(model):\(serial)" }
            else if CGDisplayIsBuiltin(id) != 0 { identities[id] = "builtin:\(vendor):\(model)" }
            else { identities[id] = "unresolved:\(vendor):\(model)" }
        }
        let counts = Dictionary(grouping: identities.keys, by: { identities[$0]! }).mapValues(\.count)
        var ordinals: [String: Int] = [:]
        var ambiguous = Set<CGDirectDisplayID>()
        for id in allIDs {
            let base = identities[id]!
            if counts[base, default: 0] > 1 || base.hasPrefix("unresolved:") {
                ambiguous.insert(id)
                ordinals[base, default: 0] += 1
                identities[id] = base + ":unassigned-\(ordinals[base]!)"
            }
        }
        // UUIDs can be generated from incomplete EDID. Identical unnumbered outputs
        // require explicit approval even when a dock assigns different UUIDs.
        let repeatedHardware = Dictionary(grouping: allIDs.filter { CGDisplayIsBuiltin($0) == 0 }, by: {
            "\(CGDisplayVendorNumber($0)):\(CGDisplayModelNumber($0)):\(CGDisplaySerialNumber($0))"
        })
        for group in repeatedHardware.values where group.count > 1 { ambiguous.formUnion(group) }
        let primaryID = CGMainDisplayID()
        let primary = screenByID[primaryID]?.frame ?? screens.first?.frame ?? .zero
        let records = allIDs.map { id -> DisplayRecord in
            let screen = screenByID[id]
            let mirrorID = CGDisplayMirrorsDisplay(id)
            let mirrorScreen = screenByID[mirrorID]
            let cg = CGDisplayBounds(id)
            let frame = screen?.frame ?? mirrorScreen?.frame ?? NSRect(x: cg.minX, y: primary.maxY - cg.maxY, width: cg.width, height: cg.height)
            let usable = (screen ?? mirrorScreen).map(Self.usableFrame) ?? frame
            let name = screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in display" : "Display")
            // Only NSScreen-backed roots are independently usable placement surfaces;
            // mirror receivers stay in inventory with the source's identity.
            let isActive = active.contains(id) && (screen != nil || mirrorID != kCGNullDirectDisplay)
            return DisplayRecord(id: identities[id]!, name: name, uuid: uuids[id], vendor: CGDisplayVendorNumber(id),
                model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id), isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                isActive: isActive, isPrimary: id == primaryID, mirrorSourceID: mirrorID == kCGNullDirectDisplay ? nil : identities[mirrorID],
                identityIsAmbiguous: ambiguous.contains(id), frame: Self.rect(frame), usableFrame: Self.rect(usable),
                scale: Double(screen?.backingScaleFactor ?? mirrorScreen?.backingScaleFactor ?? 1), rotation: CGDisplayRotation(id))
        }
        return .init(displays: records, lid: lidProvider.state())
    }

    private func displayList(active: Bool) -> [CGDirectDisplayID] {
        for _ in 0..<3 {
            var count: UInt32 = 0
            let first = active ? CGGetActiveDisplayList(0, nil, &count) : CGGetOnlineDisplayList(0, nil, &count)
            guard first == .success else { return [] }
            guard count > 0 else { return [] }
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count) + 8)
            var actual: UInt32 = 0
            let result = active ? CGGetActiveDisplayList(UInt32(ids.count), &ids, &actual) : CGGetOnlineDisplayList(UInt32(ids.count), &ids, &actual)
            if result == .success && actual <= ids.count { return Array(ids.prefix(Int(actual))) }
        }
        return []
    }

    private static func usableFrame(_ screen: NSScreen) -> NSRect {
        let safe = screen.safeAreaInsets
        let safeFrame = NSRect(x: screen.frame.minX + safe.left, y: screen.frame.minY + safe.bottom,
            width: max(0, screen.frame.width - safe.left - safe.right),
            height: max(0, screen.frame.height - safe.top - safe.bottom))
        return screen.visibleFrame.intersection(safeFrame)
    }

    private static func rect(_ frame: NSRect) -> Rect { .init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }

    public func start(onEvent: @escaping @MainActor @Sendable (SystemEvent) -> Void) {
        stop()
        handler = onEvent
        registered = CGDisplayRegisterReconfigurationCallback(Self.reconfiguration, Unmanaged.passUnretained(self).toOpaque()) == .success
        observe(.default, NSApplication.didChangeScreenParametersNotification, .displayChanged)
        observe(.default, NSApplication.didBecomeActiveNotification, .permissionChanged)
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, event): (Notification.Name, SystemEvent) in [
            (NSWorkspace.willSleepNotification, .sleep), (NSWorkspace.didWakeNotification, .wake),
            (NSWorkspace.screensDidSleepNotification, .screenSleep), (NSWorkspace.screensDidWakeNotification, .screenWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionInactive), (NSWorkspace.sessionDidBecomeActiveNotification, .sessionActive),
            (NSWorkspace.didLaunchApplicationNotification, .applicationsChanged), (NSWorkspace.didTerminateApplicationNotification, .applicationsChanged),
            // A Space switch can change membership visibility and the active
            // desktop without changing physical displays. Reuse the coordinator's
            // debounced capture path; this must not start display stabilization.
            (NSWorkspace.activeSpaceDidChangeNotification, .windowsChanged)
        ] { observe(workspace, name, event) }
        lidProvider.start { [weak self] in self?.handler?(.lidChanged) }
        lastPermission = AXIsProcessTrusted()
        // macOS exposes no supported AX trust-change notification. A low-frequency
        // trust-only check complements immediate per-write checks and app activation.
        let permissionTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let trusted = AXIsProcessTrusted()
                if trusted != self.lastPermission { self.lastPermission = trusted; self.handler?(.permissionChanged) }
            }
        }
        permissionTimer.tolerance = 1
        // Keep checking while the menu-bar popover is tracking input. A timer in
        // the default mode can stall even though the permission UI remains visible.
        RunLoop.main.add(permissionTimer, forMode: .common)
        self.permissionTimer = permissionTimer
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ event: SystemEvent) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handler?(event) }
        }
        observers.append((center, token))
    }

    private nonisolated static let reconfiguration: CGDisplayReconfigurationCallBack = { _, _, context in
        guard let context else { return }
        let owner = Unmanaged<DisplayTopologyService>.fromOpaque(context).takeUnretainedValue()
        // Both begin and completion notifications invalidate old work. Enumeration
        // happens later in the coordinator's quiet-period stabilization loop.
        Task { @MainActor [weak owner] in owner?.handler?(.displayChanged) }
    }

    public func stop() {
        if registered { CGDisplayRemoveReconfigurationCallback(Self.reconfiguration, Unmanaged.passUnretained(self).toOpaque()) }
        registered = false
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        permissionTimer?.invalidate(); permissionTimer = nil
        lidProvider.stop()
        handler = nil
    }
}
