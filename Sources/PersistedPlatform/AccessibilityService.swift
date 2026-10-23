import AppKit
import ApplicationServices
import PersistedCore
import OSLog
import PersistedSpacesBridge

/// The executor only transports Swift actor jobs. Every AX object is owned and used
/// by AccessibilityService on this serial queue, away from the application's UI.
private final class AXSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.persisted.accessibility", qos: .utility)
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

private struct RunningApp: Sendable {
    var instance: ApplicationInstance
    var bundleID: String
    var name: String
    var hidden: Bool
}

/// An immutable callback bridge. It never exposes an AX object to another executor.
private final class AXChangeRelay: Sendable {
    let notify: @Sendable () -> Void
    init(_ notify: @escaping @Sendable () -> Void) { self.notify = notify }
}

public actor AccessibilityService: WindowAccessing {
    private nonisolated let executor = AXSerialExecutor()
    public nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    private struct Entry {
        let element: AXUIElement
        var descriptor: LiveWindow
        var windowID: CGWindowID
        var desktopSpaces: Set<UInt64>?
    }
    private struct Observation {
        let observer: AXObserver
        let application: AXUIElement
        let instance: ApplicationInstance
        var registrations: [(AXUIElement, String)]
        var attemptedRegistrations: [(AXUIElement, String)]
        // This explicitly retained context is released on the callback's main queue
        // after its source has been removed, so an already executing callback is safe.
        let relayPointer: UnsafeMutableRawPointer
    }
    private var entries: [UUID: Entry] = [:]
    private var observations: [Int32: Observation] = [:]
    private var onChange: (@Sendable () -> Void)?
    private var coalescer: Task<Void, Never>?
    private var suppressChangesUntil: Date = .distantPast
    private var exclusions: [WindowExclusion] = []
    private var configured = false
    private var logicalDesktopIDs: [String: String] = [:]
    private var preparedDesktopOrder: (generation: UInt64, inventory: NativeDesktopInventory)?
    private let messagingTimeout: Float = 0.22
    private let applicationBudget: TimeInterval = 1.8
    private let logger = Logger(subsystem: "app.persisted", category: "Accessibility")
    public init() {}

    private func configure() {
        guard !configured else { return }
        // The system-wide element sets this process's default, including children.
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
        configured = true
    }

    @MainActor private static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  let bundle = application.bundleIdentifier, let launch = application.launchDate,
                  !application.isTerminated else { return nil }
            return RunningApp(instance: .init(pid: application.processIdentifier, launchDate: launch),
                bundleID: bundle, name: application.localizedName ?? bundle, hidden: application.isHidden)
        }.sorted { $0.bundleID == $1.bundleID ? $0.instance.pid < $1.instance.pid : $0.bundleID < $1.bundleID }
    }

    public func capture(exclusions: [WindowExclusion]) async -> WindowCapture {
        configure()
        self.exclusions = exclusions
        guard AXIsProcessTrusted() else { return .init(permissionGranted: false) }
        let desktopEnvironment = await DesktopEnvironment.current()
        let desktopsBefore = desktopEnvironment.read()
        let savedDesktops = desktopsBefore.map(desktopSnapshot)
        let apps = await Self.runningApps()
        let previous = entries
        var replacement: [UUID: Entry] = [:]
        var capture = WindowCapture(runningBundleIDs: Set(apps.map(\.bundleID)))
        for app in apps {
            guard !Task.isCancelled else {
                capture.issues.append(.init(bundleID: app.bundleID, message: "Capture was cancelled.")); break
            }
            guard AXIsProcessTrusted() else { capture.permissionGranted = false; break }
            if exclusions.contains(where: { $0.bundleID == app.bundleID && $0.title == nil }) { continue }
            let deadline = Date().addingTimeInterval(applicationBudget)
            let element = AXUIElementCreateApplication(app.instance.pid)
            var rawWindows: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &rawWindows)
            guard status == .success, let windows = rawWindows as? [AXUIElement] else {
                if status == .apiDisabled { capture.permissionGranted = false }
                if status != .noValue {
                    capture.issues.append(.init(bundleID: app.bundleID, message: status == .cannotComplete ? "Application did not respond in time." : "Application windows are temporarily unavailable."))
                }
                continue
            }
            for window in windows {
                guard Date() < deadline else {
                    capture.issues.append(.init(bundleID: app.bundleID, message: "Application capture exceeded its time budget.")); break
                }
                let (descriptor, issue) = describe(window, app: app, deadline: deadline)
                if let issue { capture.issues.append(.init(bundleID: app.bundleID, message: issue)) }
                guard var descriptor, !exclusions.contains(where: { $0.excludes(descriptor.identity) }) else { continue }
                if let old = previous.values.first(where: { $0.descriptor.instance == app.instance && CFEqual($0.element, window) }) {
                    descriptor.id = old.descriptor.id
                }
                let windowID = PSDesktopWindowID(window)
                let desktopSpaces = NativeDesktopAccess.memberships(of: windowID)
                if let desktopsBefore, let savedDesktops, let desktopSpaces {
                    descriptor.desktopAssignment = desktopAssignment(desktopSpaces, inventory: desktopsBefore, snapshot: savedDesktops)
                }
                replacement[descriptor.id] = Entry(element: window, descriptor: descriptor, windowID: windowID, desktopSpaces: desktopSpaces)
                capture.windows.append(descriptor)
            }
        }
        // Preserve only entries still in the current capture. Failed or vanished handles
        // cannot accidentally be used by a plan based on an older enumeration.
        entries = replacement
        // Never attach memberships from a topology that changed mid-enumeration.
        // Geometry remains available when experimental Spaces discovery is unavailable.
        let desktopEnvironmentAfter = await DesktopEnvironment.current()
        if let desktopsBefore, desktopEnvironment.topology == desktopEnvironmentAfter.topology,
           desktopEnvironment.separateDisplays == desktopEnvironmentAfter.separateDisplays,
           desktopsBefore == desktopEnvironmentAfter.read() {
            capture.desktopSnapshot = savedDesktops
        } else {
            for index in capture.windows.indices { capture.windows[index].desktopAssignment = nil }
            for id in entries.keys { entries[id]?.descriptor.desktopAssignment = nil }
        }
        if onChange != nil { synchronizeObservers(apps: apps) }
        logger.debug("Capture completed: \(capture.windows.count) windows; \(capture.issues.count) issues")
        return capture
    }

    private func desktopSnapshot(_ inventory: NativeDesktopInventory) -> DesktopSnapshot {
        let groups = inventory.displays.map { display in
            DesktopDisplay(displayID: display.displayID, desktops: display.desktops.enumerated().map { ordinal, desktop in
                // Stable logical IDs survive recaptures, but never encode a numeric
                // window-server handle into the persisted layout.
                let key = desktop.uuid.map { "uuid:\($0)" } ?? "session:\(display.displayID):\(desktop.runtimeID)"
                let logical = logicalDesktopIDs[key] ?? UUID().uuidString
                logicalDesktopIDs[key] = logical
                return SavedDesktop(id: logical, ordinal: ordinal, kind: desktop.kind, uuidHint: desktop.uuid, isActive: desktop.active)
            })
        }
        return .init(displays: groups, separateDisplays: inventory.separateDisplays)
    }

    private func desktopAssignment(_ membership: Set<UInt64>, inventory: NativeDesktopInventory,
                                   snapshot: DesktopSnapshot) -> DesktopAssignment? {
        guard !membership.isEmpty, membership.isSubset(of: inventory.allRuntimeIDs) else { return nil }
        if membership.count == 1, let runtimeID = membership.first {
            for (displayIndex, display) in inventory.displays.enumerated() {
                if let index = display.desktops.firstIndex(where: { $0.runtimeID == runtimeID }) {
                    return .desktop(snapshot.displays[displayIndex].desktops[index].id)
                }
            }
        }
        // Multiple membership is only described as “all desktops” when it covers
        // every ordinary desktop of that display. Arbitrary memberships stay unknown.
        for display in inventory.displays {
            let ordinary = Set(display.ordinaryDesktops.map(\.runtimeID))
            let all = Set(display.desktops.map(\.runtimeID))
            if ordinary.count > 1, ordinary.isSubset(of: membership), membership.isSubset(of: all) { return .allDesktops }
        }
        return nil
    }

    /// Read-only diagnostics, including the discovered capability, without titles,
    /// application identities, or mutations to the user's desktops.
    public func desktopDiagnostics() async -> [String: String] {
        let environment = await DesktopEnvironment.current()
        let inventory = environment.read()
        var result = ["readSupported": String(inventory != nil), "moveSupported": String(PSDesktopCanMoveWindows()),
                      "accessibilityTrusted": String(AXIsProcessTrusted()), "separateDisplays": String(environment.separateDisplays)]
        if let inventory {
            let snapshot = desktopSnapshot(inventory)
            result["desktopCount"] = String(snapshot.desktopCount)
            result["spaceCount"] = String(snapshot.totalSpaceCount)
            result["displayCount"] = String(snapshot.displays.count)
            if let data = try? JSONEncoder().encode(snapshot) { result["snapshot"] = String(data: data, encoding: .utf8) }
        }
        return result
    }

    public func desktopRestorationCapability() async -> DesktopRestorationCapability {
        currentDesktopRestorationCapability()
    }

    private func currentDesktopRestorationCapability() -> DesktopRestorationCapability {
        guard PSDesktopCanMoveWindows() else {
            return .unavailable("Desktop restoration is unavailable on this macOS version. Window positions and sizes can still be restored.")
        }
        return .available
    }

    public func prepareDesktops(_ snapshot: DesktopSnapshot, mapping: [String: String], generation: UInt64,
                                gate: MutationGate, automatic: Bool) async -> DesktopPreparation {
        configure()
        var result = DesktopPreparation()
        preparedDesktopOrder = nil
        // Creating or activating desktops is unsafe when their windows cannot follow.
        // Check the same version/ABI gate as the move before touching Mission Control.
        if let limitation = currentDesktopRestorationCapability().limitation { return .init(issues: [limitation]) }
        guard desktopMutationAllowed(generation, gate: gate) else { return .init(issues: ["Desktop restoration was cancelled or Accessibility permission is unavailable."]) }
        let environment = await DesktopEnvironment.current()
        guard var inventory = environment.read() else { return .init(issues: ["macOS did not provide a complete desktop inventory."]) }
        guard snapshot.separateDisplays == inventory.separateDisplays else {
            return .init(issues: ["The saved layout and this Mac use different ‘Displays have separate Spaces’ settings. Desktop assignments were left unchanged."])
        }
        let plan = DesktopRestorePlanner.plan(snapshot: snapshot, displayMapping: mapping)
        if !plan.unsupportedDesktopIDs.isEmpty {
            result.issues.append("Full-screen and Split View Spaces remain as they are; their order cannot be restored.")
        }
        if !plan.mergedActiveDesktopIDs.isEmpty {
            result.issues.append("Some saved monitors share one destination, so only the first saved active desktop can remain visible there.")
        }
        let initiallyOpen = NativeDesktopAccess.missionControl() != nil
        var openedMissionControl = false
        defer {
            if openedMissionControl, !initiallyOpen, desktopMutationAllowed(generation, gate: gate), NativeDesktopAccess.missionControl() != nil {
                _ = PSDesktopToggleMissionControl()
            }
        }
        let operationDeadline = Date().addingTimeInterval(30)
        for (displayID, count) in plan.requiredCounts.sorted(by: { $0.key < $1.key }) {
            guard count > 0, count <= 16 else {
                result.issues.append("The requested desktop count exceeds macOS’s supported desktop limit."); continue
            }
            guard let initial = inventory.display(displayID) else {
                result.issues.append("A destination monitor is no longer available for desktop restoration."); continue
            }
            while (inventory.display(displayID)?.ordinaryDesktops.count ?? count) < count {
                guard Date() < operationDeadline, desktopMutationAllowed(generation, gate: gate) else {
                    result.issues.append("Desktop creation stopped before all saved desktops could be restored."); break
                }
                if NativeDesktopAccess.missionControl() == nil {
                    guard await openMissionControl(generation: generation, gate: gate) else {
                        result.issues.append("Mission Control could not be opened to create the missing desktops."); break
                    }
                    openedMissionControl = true
                }
                guard let fresh = environment.read(), sameDesktopOrder(fresh, inventory),
                      let add = NativeDesktopAccess.subgroup("mc.spaces.add", display: initial.runtimeDisplayID) else {
                    result.issues.append("The desktop arrangement changed or Mission Control’s add button was unavailable."); break
                }
                guard desktopMutationAllowed(generation, gate: gate) else { break }
                result.didMutate = true
                let status = AXUIElementPerformAction(add, kAXPressAction as CFString)
                guard status == .success else {
                    result.issues.append("Mission Control could not create a missing desktop."); break
                }
                var created: NativeDesktopInventory?
                for _ in 0..<15 {
                    guard desktopMutationAllowed(generation, gate: gate) else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if let next = environment.read(), expectedDesktopAdded(before: inventory, after: next, displayID: initial.displayID) {
                        created = next; break
                    }
                }
                guard let created else {
                    result.issues.append("macOS did not confirm that the new desktop was created. Further creation stopped."); break
                }
                inventory = created
            }
            if let current = inventory.display(displayID), current.ordinaryDesktops.count > count {
                result.issues.append("\(current.ordinaryDesktops.count - count) extra desktop(s) were kept on a monitor to preserve windows outside this layout.")
            }
        }
        guard let final = environment.read(), sameDesktopOrder(final, inventory), desktopMutationAllowed(generation, gate: gate) else {
            result.issues.append("The desktop arrangement changed before window assignments could be restored."); return result
        }
        for (savedID, target) in plan.targets {
            guard let display = final.display(target.displayID), display.ordinaryDesktops.indices.contains(target.ordinal) else { continue }
            result.destinations[savedID] = display.ordinaryDesktops[target.ordinal].runtimeID
        }
        preparedDesktopOrder = (generation, final)
        suppressChangesUntil = Date().addingTimeInterval(2)
        return result
    }

    public func moveToDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                              generation: UInt64, gate: MutationGate, automatic: Bool) async -> DesktopMoveResult {
        configure()
        func failure(_ text: String, mutated: Bool = false) -> DesktopMoveResult { .init(succeeded: false, didMutate: mutated, message: text) }
        if let limitation = currentDesktopRestorationCapability().limitation { return failure(limitation) }
        guard desktopMutationAllowed(generation, gate: gate) else { return failure("Desktop placement was cancelled or Accessibility permission is unavailable.") }
        guard var entry = entries[live.id], entry.descriptor.instance == live.instance,
              validInstance(live.instance, bundleID: live.identity.bundleID), entry.windowID != 0,
              PSDesktopWindowID(entry.element) == entry.windowID else { return failure("The original window is no longer available for desktop placement.") }
        guard !exclusions.contains(where: { $0.excludes(live.identity) }) else { return failure("This window is excluded.") }
        let environment = await DesktopEnvironment.current()
        guard let inventory = environment.read(), let membership = NativeDesktopAccess.memberships(of: entry.windowID) else {
            return failure("The window’s current desktop could not be verified.")
        }
        guard let preparedDesktopOrder, preparedDesktopOrder.generation == generation,
              sameDesktopOrder(preparedDesktopOrder.inventory, inventory) else {
            return failure("The desktop order changed after preparation; further desktop placement stopped.")
        }
        switch assignment {
        case .allDesktops:
            let saved = desktopSnapshot(inventory)
            return desktopAssignment(membership, inventory: inventory, snapshot: saved) == .allDesktops
                ? .init(succeeded: true)
                : failure("The saved window appeared on all desktops. Its app’s all-desktop assignment must be restored manually.")
        case .desktop(let logicalID):
            guard let target = destinations[logicalID], let targetDesktop = inventory.desktop(target), targetDesktop.kind == .ordinary else {
                return failure("The saved desktop is unavailable, or is a full-screen Space that cannot be recreated.")
            }
            if membership == [target] { return .init(succeeded: true) }
            guard membership.count == 1, let source = membership.first, inventory.desktop(source)?.kind == .ordinary else {
                return failure("Full-screen and all-desktop windows keep their current desktop membership.")
            }
            guard PSDesktopCanMoveWindows() else { return failure("Moving windows between desktops is unavailable on this macOS version.") }
            if automatic, entry.desktopSpaces != membership { return failure("The window changed desktops after capture; automatic placement was deferred.") }
            let app = RunningApp(instance: live.instance, bundleID: live.identity.bundleID, name: live.identity.appName,
                                 hidden: NSRunningApplication(processIdentifier: live.instance.pid)?.isHidden ?? true)
            let (current, issue) = describe(entry.element, app: app, deadline: Date().addingTimeInterval(applicationBudget))
            guard let current, issue == nil, current.identity.bundleID == live.identity.bundleID,
                  current.identity.role == live.identity.role, current.identity.subrole == live.identity.subrole,
                  live.identity.accessibilityID == nil || current.identity.accessibilityID == live.identity.accessibilityID,
                  live.identity.documentID == nil || current.identity.documentID == live.identity.documentID else {
                return failure("The window changed or stopped responding before desktop placement.")
            }
            guard !current.fullscreen, !current.minimized, !current.hidden else {
                return failure("Hidden, minimized, and full-screen windows keep their current desktop membership.")
            }
            if automatic, !current.frame.approximatelyEquals(entry.descriptor.frame) {
                return failure("Recent window movement deferred automatic desktop placement.")
            }
            guard validInstance(live.instance, bundleID: live.identity.bundleID),
                  PSDesktopWindowID(entry.element) == entry.windowID,
                  NativeDesktopAccess.memberships(of: entry.windowID) == membership,
                  let immediatelyBeforeMove = environment.read(),
                  sameDesktopOrder(preparedDesktopOrder.inventory, immediatelyBeforeMove),
                  desktopMutationAllowed(generation, gate: gate) else { return failure("The window or active request changed before desktop placement.") }
            suppressChangesUntil = Date().addingTimeInterval(2)
            let submitted = PSDesktopMoveWindow(entry.windowID, target)
            guard submitted else { return failure("macOS rejected the experimental desktop placement request.", mutated: true) }
            for _ in 0..<15 {
                guard desktopMutationAllowed(generation, gate: gate), validInstance(live.instance, bundleID: live.identity.bundleID) else {
                    return failure("Desktop placement verification stopped because permission or the active request changed.", mutated: true)
                }
                if NativeDesktopAccess.memberships(of: entry.windowID) == [target] {
                    // A bridge move can alter screen coordinates. The following AX
                    // placement must compare against this fresh geometry, not label
                    // the bridge's own movement as a user's drag.
                    if let frame = currentFrame(entry.element).0 { entry.descriptor.frame = frame }
                    entry.descriptor.desktopAssignment = assignment
                    entry.desktopSpaces = [target]
                    entries[live.id] = entry
                    return .init(succeeded: true, didMutate: true)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return failure("macOS did not confirm that the window reached its saved desktop.", mutated: true)
        }
    }

    /// Geometry writes can themselves transfer a window to another monitor's
    /// desktop. Verify the final membership without issuing another move or
    /// masking the original placement outcome.
    public func verifyDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                              generation: UInt64, gate: MutationGate) async -> DesktopMoveResult {
        func failure(_ message: String) -> DesktopMoveResult { .init(succeeded: false, message: message) }
        guard desktopMutationAllowed(generation, gate: gate) else {
            return failure("Final desktop verification stopped because permission or the active request changed.")
        }
        let environment = await DesktopEnvironment.current()
        guard let entry = entries[live.id], entry.descriptor.instance == live.instance,
              validInstance(live.instance, bundleID: live.identity.bundleID), entry.windowID != 0,
              PSDesktopWindowID(entry.element) == entry.windowID else {
            return failure("The original window is no longer available for final desktop verification.")
        }
        guard let inventory = environment.read(), let preparedDesktopOrder,
              preparedDesktopOrder.generation == generation,
              sameDesktopOrder(preparedDesktopOrder.inventory, inventory),
              let membership = NativeDesktopAccess.memberships(of: entry.windowID) else {
            return failure("The desktop arrangement changed or the final window membership could not be verified.")
        }
        guard desktopMutationAllowed(generation, gate: gate), validInstance(live.instance, bundleID: live.identity.bundleID) else {
            return failure("Final desktop verification stopped because the window or active request changed.")
        }
        switch assignment {
        case .desktop(let savedID):
            guard let target = destinations[savedID], inventory.desktop(target)?.kind == .ordinary else {
                return failure("The saved desktop is unavailable for final verification.")
            }
            return membership == [target] ? .init(succeeded: true)
                : failure("The window did not remain on its saved desktop after its position was restored.")
        case .allDesktops:
            return desktopAssignment(membership, inventory: inventory, snapshot: desktopSnapshot(inventory)) == .allDesktops
                ? .init(succeeded: true)
                : failure("The window no longer appears on all desktops after its position was restored.")
        }
    }

    public func restoreActiveDesktops(_ snapshot: DesktopSnapshot, destinations: [String: UInt64], generation: UInt64,
                                      gate: MutationGate, automatic: Bool) async -> [String] {
        if let limitation = currentDesktopRestorationCapability().limitation { return [limitation] }
        let environment = await DesktopEnvironment.current()
        guard let original = environment.read(), original.separateDisplays == snapshot.separateDisplays else {
            return ["The active desktops could not be verified."]
        }
        guard let preparedDesktopOrder, preparedDesktopOrder.generation == generation,
              sameDesktopOrder(preparedDesktopOrder.inventory, original) else {
            return ["The desktop order changed after preparation; the active desktop was left unchanged."]
        }
        var issues: [String] = []
        var handledDisplays: Set<String> = []
        for saved in snapshot.displays.flatMap(\.desktops).filter(\.isActive) {
            guard let target = destinations[saved.id],
                  let display = original.displays.first(where: { $0.desktops.contains { $0.runtimeID == target } }),
                  handledDisplays.insert(display.displayID).inserted else { continue }
            guard desktopMutationAllowed(generation, gate: gate), let inventory = environment.read(), sameDesktopOrder(original, inventory),
                  let current = inventory.display(display.displayID), let targetIndex = current.desktops.firstIndex(where: { $0.runtimeID == target }) else {
                issues.append("The desktop arrangement changed before the saved active desktop could be selected."); break
            }
            if current.desktops[targetIndex].active { continue }
            let initiallyOpen = NativeDesktopAccess.missionControl() != nil
            guard await openMissionControl(generation: generation, gate: gate) else {
                issues.append("Mission Control could not be opened to select the saved active desktop."); continue
            }
            // Mission Control's tiles appear after its opening transition. Read the
            // current list only after a bounded settling interval and compare order.
            try? await Task.sleep(for: .milliseconds(250))
            let list = NativeDesktopAccess.subgroup("mc.spaces.list", display: display.runtimeDisplayID)
            let children = list.map(NativeDesktopAccess.children) ?? []
            if let fresh = environment.read(), sameDesktopOrder(fresh, inventory), children.count == current.desktops.count,
               children.indices.contains(targetIndex), desktopMutationAllowed(generation, gate: gate) {
                _ = AXUIElementPerformAction(children[targetIndex], kAXPressAction as CFString)
                var verified = false
                for _ in 0..<15 {
                    guard desktopMutationAllowed(generation, gate: gate) else { break }
                    try? await Task.sleep(for: .milliseconds(100))
                    if environment.read()?.desktop(target)?.active == true { verified = true; break }
                }
                if !verified { issues.append("macOS did not confirm that the saved active desktop was selected.") }
            } else { issues.append("Mission Control’s desktop tiles did not match the saved destination.") }
            if !initiallyOpen, NativeDesktopAccess.missionControl() != nil, desktopMutationAllowed(generation, gate: gate) {
                _ = PSDesktopToggleMissionControl()
            }
        }
        // Selecting a desktop can trigger macOS's automatic Spaces reordering.
        // Never report full restoration or resume learning against changed slots.
        if let final = environment.read(), sameDesktopOrder(preparedDesktopOrder.inventory, final) {
            return issues
        }
        issues.append("The desktop order changed after selecting the active desktop. The saved arrangement could not be verified.")
        return issues
    }

    private func desktopMutationAllowed(_ generation: UInt64, gate: MutationGate) -> Bool {
        gate.isValid(generation) && !Task.isCancelled && AXIsProcessTrusted()
    }
    private func openMissionControl(generation: UInt64, gate: MutationGate) async -> Bool {
        if NativeDesktopAccess.missionControl() != nil { return true }
        guard desktopMutationAllowed(generation, gate: gate), PSDesktopToggleMissionControl() else { return false }
        for _ in 0..<15 {
            guard desktopMutationAllowed(generation, gate: gate) else { return false }
            try? await Task.sleep(for: .milliseconds(100))
            if NativeDesktopAccess.missionControl() != nil { return true }
        }
        return false
    }
    private func sameDesktopOrder(_ lhs: NativeDesktopInventory, _ rhs: NativeDesktopInventory) -> Bool {
        guard lhs.separateDisplays == rhs.separateDisplays, lhs.displays.count == rhs.displays.count else { return false }
        return zip(lhs.displays, rhs.displays).allSatisfy { left, right in
            left.displayID == right.displayID && left.runtimeDisplayID == right.runtimeDisplayID &&
            left.desktops.map(\.runtimeID) == right.desktops.map(\.runtimeID) && left.desktops.map(\.kind) == right.desktops.map(\.kind)
        }
    }
    private func expectedDesktopAdded(before: NativeDesktopInventory, after: NativeDesktopInventory, displayID: String) -> Bool {
        guard before.separateDisplays == after.separateDisplays, before.displays.count == after.displays.count else { return false }
        for (left, right) in zip(before.displays, after.displays) {
            guard left.displayID == right.displayID, left.runtimeDisplayID == right.runtimeDisplayID else { return false }
            if left.displayID == displayID {
                let oldIDs = Set(left.desktops.map(\.runtimeID))
                let added = right.desktops.filter { !oldIDs.contains($0.runtimeID) }
                guard added.count == 1, added[0].kind == .ordinary,
                      right.desktops.filter({ oldIDs.contains($0.runtimeID) }).map(\.runtimeID) == left.desktops.map(\.runtimeID) else { return false }
            } else if left.desktops.map(\.runtimeID) != right.desktops.map(\.runtimeID) { return false }
        }
        return true
    }

    private func describe(_ element: AXUIElement, app: RunningApp, deadline: Date) -> (LiveWindow?, String?) {
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXIdentifierAttribute,
            kAXDocumentAttribute, kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen"]
        var raw: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &raw)
        guard result == .success, let values = raw as? [AnyObject], values.count == names.count else {
            return (nil, result == .cannotComplete ? "A window did not respond in time." : "A window could not be inspected.")
        }
        let role = values[0] as? String ?? ""
        let subrole = values[1] as? String ?? ""
        guard role == kAXWindowRole, subrole == kAXStandardWindowSubrole else { return (nil, nil) }
        guard let frame = frame(position: values[5], size: values[6]), frame.isValid else { return (nil, "A standard window did not expose valid geometry.") }
        guard Date() < deadline else { return (nil, "Application capture exceeded its time budget.") }
        var movable = DarwinBoolean(false), resizable = DarwinBoolean(false)
        let moveStatus = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &movable)
        let sizeStatus = Date() < deadline ? AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &resizable) : .cannotComplete
        let identity = WindowIdentity(bundleID: app.bundleID, appName: app.name, accessibilityID: values[3] as? String,
            documentID: values[4] as? String, title: values[2] as? String ?? "", role: role, subrole: subrole)
        let issue = moveStatus == .cannotComplete || sizeStatus == .cannotComplete ? "Window capability inspection timed out." : nil
        return (.init(instance: app.instance, identity: identity, frame: frame,
            capabilities: .init(canMove: moveStatus == .success && movable.boolValue, canResize: sizeStatus == .success && resizable.boolValue),
            minimized: values[7] as? Bool ?? false, hidden: app.hidden, fullscreen: values[8] as? Bool ?? false), issue)
    }

    private func frame(position: AnyObject, size: AnyObject) -> Rect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let position = position as! AXValue, size = size as! AXValue
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else { return nil }
        return .init(x: point.x, y: point.y, width: dimensions.width, height: dimensions.height)
    }

    private func currentFrame(_ element: AXUIElement) -> (Rect?, AXError) {
        var values: CFArray?
        let status = AXUIElementCopyMultipleAttributeValues(element, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values)
        guard status == .success, let array = values as? [AnyObject], array.count == 2 else { return (nil, status) }
        return (frame(position: array[0], size: array[1]), status)
    }

    public func place(_ placement: PlannedPlacement, generation: UInt64, gate: MutationGate, automatic: Bool) async -> WindowOutcome {
        configure()
        let saved = placement.savedWindow
        var didMutate = false
        var lastKnownFrame: Rect?
        func outcome(_ kind: WindowOutcomeKind, _ explanation: String = "", frame: Rect? = nil) -> WindowOutcome {
            .init(id: saved.id, appName: saved.identity.appName, kind: kind, explanation: explanation, actualFrame: frame ?? lastKnownFrame, didMutate: didMutate)
        }
        guard gate.isValid(generation), !Task.isCancelled else { return outcome(.cancelled, "A newer request replaced this operation.") }
        guard AXIsProcessTrusted() else { return outcome(.cancelled, "Accessibility permission is required.") }
        guard let entry = entries[placement.liveWindow.id], entry.descriptor.instance == placement.liveWindow.instance else {
            return outcome(.missingWindow, "The original window is no longer available.")
        }
        let live = entry.descriptor
        guard !exclusions.contains(where: { $0.excludes(live.identity) }) else { return outcome(.unsupported, "This window is excluded.") }
        guard placement.targetFrame.isValid else { return outcome(.unsupported, "The destination geometry is invalid.") }
        // NSRunningApplication is documented as thread-safe. Check the launch date,
        // not just the PID, so PID reuse cannot revalidate a stale window reference.
        guard validInstance(live.instance, bundleID: live.identity.bundleID) else { return outcome(.missingApplication, "The application instance has changed.") }
        let deadline = Date().addingTimeInterval(applicationBudget)
        let app = RunningApp(instance: live.instance, bundleID: live.identity.bundleID, name: live.identity.appName, hidden: NSRunningApplication(processIdentifier: live.instance.pid)?.isHidden ?? true)
        let (current, issue) = describe(entry.element, app: app, deadline: deadline)
        guard let current else { return outcome(issue?.contains("time") == true ? .timedOut : .missingWindow, issue ?? "The window is no longer available.") }
        lastKnownFrame = current.frame
        guard current.identity.bundleID == live.identity.bundleID, current.identity.role == live.identity.role,
              current.identity.subrole == live.identity.subrole else { return outcome(.missingWindow, "The window identity changed.") }
        if let identifier = live.identity.accessibilityID, current.identity.accessibilityID != identifier { return outcome(.missingWindow, "The window identity changed.") }
        if let document = live.identity.documentID, current.identity.documentID != document { return outcome(.missingWindow, "The window document changed.") }
        let target = placement.targetFrame
        if current.frame.approximatelyEquals(target) { return outcome(.alreadyPositioned, frame: current.frame) }
        guard !current.minimized, !current.hidden, !current.fullscreen else {
            return outcome(.unsupported, "Hidden, minimized, and fullscreen windows keep their current state.")
        }
        if let issue { return outcome(.timedOut, issue, frame: current.frame) }
        // Compare against the planning capture, not an earlier stable topology:
        // geometry changes made by macOS during docking are not evidence of a drag.
        if automatic && !current.frame.approximatelyEquals(live.frame) {
            return outcome(.cancelled, "Recent window movement deferred automatic placement.", frame: current.frame)
        }
        var expected = current.frame
        suppressChangesUntil = Date().addingTimeInterval(1.5)
        // One bounded size–position–size sequence, then at most one corrective
        // position if the application's final minimum size would leave its work area.
        // Every actual write has independent permission, identity, and generation guards.
        for step in 0..<4 {
            guard Date() < deadline else { return outcome(.timedOut, "Window placement exceeded its time budget.", frame: expected) }
            let (before, readStatus) = currentFrame(entry.element)
            guard let before else { return outcome(readStatus == .cannotComplete ? .timedOut : .missingWindow, "The window stopped responding.") }
            lastKnownFrame = before
            if !before.approximatelyEquals(expected, tolerance: 4) {
                return outcome(.cancelled, "The window changed during placement; further writes were stopped.", frame: before)
            }
            let attribute: String
            let value: AXValue
            if step == 1 || step == 3 {
                let proposed = step == 1
                    ? Rect(x: target.x, y: target.y, width: before.width, height: before.height)
                    : before
                let reachable = placement.targetUsableFrame.map { CoordinateMapper.clamp(proposed, to: $0) } ?? proposed
                if abs(before.x - reachable.x) <= 2 && abs(before.y - reachable.y) <= 2 { expected = before; continue }
                attribute = kAXPositionAttribute
                var point = CGPoint(x: reachable.x, y: reachable.y)
                guard let position = AXValueCreate(.cgPoint, &point) else { return outcome(.unsupported) }
                value = position
            } else {
                if abs(before.width - target.width) <= 2 && abs(before.height - target.height) <= 2 { expected = before; continue }
                attribute = kAXSizeAttribute
                var size = CGSize(width: target.width, height: target.height)
                guard let dimensions = AXValueCreate(.cgSize, &size) else { return outcome(.unsupported) }
                value = dimensions
            }
            guard validInstance(live.instance, bundleID: live.identity.bundleID) else { return outcome(.missingApplication, "The application instance has changed.") }
            guard NSRunningApplication(processIdentifier: live.instance.pid)?.isHidden == false else {
                return outcome(.unsupported, "The application became hidden; placement stopped.", frame: before)
            }
            var settable = DarwinBoolean(false)
            let capabilityStatus = AXUIElementIsAttributeSettable(entry.element, attribute as CFString, &settable)
            guard capabilityStatus == .success, settable.boolValue else {
                return outcome(capabilityStatus == .cannotComplete ? .timedOut : .unsupported,
                    attribute == kAXPositionAttribute ? "The application cannot move this window." : "The application cannot resize this window.", frame: before)
            }
            var stateValues: CFArray?
            let stateStatus = AXUIElementCopyMultipleAttributeValues(entry.element, [kAXMinimizedAttribute, "AXFullScreen"] as CFArray, [], &stateValues)
            guard stateStatus == .success, let states = stateValues as? [AnyObject], states.count == 2 else {
                return outcome(stateStatus == .cannotComplete ? .timedOut : .unsupported, "Window state could not be revalidated.", frame: before)
            }
            guard !(states[0] as? Bool ?? false), !(states[1] as? Bool ?? false) else {
                return outcome(.unsupported, "The window became minimized or fullscreen; placement stopped.", frame: before)
            }
            guard Date() < deadline else { return outcome(.timedOut, "Window placement exceeded its time budget.", frame: before) }
            guard validInstance(live.instance, bundleID: live.identity.bundleID) else { return outcome(.missingApplication, "The application instance has changed.", frame: before) }
            // No suspension or other AX operation occurs between these guards and write.
            guard gate.isValid(generation), !Task.isCancelled else { return outcome(.cancelled, "The setup or active request changed.") }
            guard AXIsProcessTrusted() else { return outcome(.cancelled, "Accessibility permission was revoked.") }
            // A timed-out setter may still have changed the remote window. Record
            // the mutation attempt before entering AX so undo retains its original.
            didMutate = true
            let status = AXUIElementSetAttributeValue(entry.element, attribute as CFString, value)
            if status == .apiDisabled { return outcome(.cancelled, "Accessibility permission was revoked.", frame: before) }
            if status == .invalidUIElement { return outcome(.missingWindow, "The window disappeared during placement.", frame: before) }
            guard status == .success else { return outcome(status == .cannotComplete ? .timedOut : .unsupported, status == .cannotComplete ? "Application did not respond to placement in time." : "Application declined this operation.", frame: before) }
            let (accepted, acceptedStatus) = currentFrame(entry.element)
            guard let accepted else { return outcome(acceptedStatus == .cannotComplete ? .timedOut : .unsupported, "Placement could not be verified.") }
            expected = accepted
            lastKnownFrame = accepted
        }
        if var cached = entries[live.id] { cached.descriptor.frame = expected; entries[live.id] = cached }
        if let usable = placement.targetUsableFrame {
            let reachable = CoordinateMapper.clamp(expected, to: usable)
            if abs(expected.x - reachable.x) > 2 || abs(expected.y - reachable.y) > 2 {
                return outcome(.unsupported, "The application prevented a reachable placement; no further retries were made.", frame: expected)
            }
        }
        logger.debug("Placement completed with verified geometry")
        return expected.approximatelyEquals(target) ? outcome(.restored, frame: expected) : outcome(.adjustedToConstraints, "The application adjusted its size or position.", frame: expected)
    }

    private func validInstance(_ instance: ApplicationInstance, bundleID: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: instance.pid), !app.isTerminated,
              app.bundleIdentifier == bundleID, let date = app.launchDate else { return false }
        return date == instance.launchDate
    }

    public func startObserving(onChange: @escaping @Sendable () -> Void) async {
        configure()
        self.onChange = onChange
        let apps = await Self.runningApps()
        guard AXIsProcessTrusted() else { return }
        synchronizeObservers(apps: apps)
    }

    private func synchronizeObservers(apps: [RunningApp]) {
        let byPID = Dictionary(uniqueKeysWithValues: apps.map { ($0.instance.pid, $0) })
        for pid in Array(observations.keys) {
            if byPID[pid]?.instance != observations[pid]?.instance { removeObserver(pid) }
        }
        for app in apps {
            if exclusions.contains(where: { $0.bundleID == app.bundleID && $0.title == nil }) { removeObserver(app.instance.pid); continue }
            let observerDeadline = Date().addingTimeInterval(applicationBudget)
            if observations[app.instance.pid] == nil {
                var observer: AXObserver?
                let status = AXObserverCreate(app.instance.pid, { _, _, _, context in
                    guard let context else { return }
                    Unmanaged<AXChangeRelay>.fromOpaque(context).takeUnretainedValue().notify()
                }, &observer)
                guard status == .success, let observer else { continue }
                let relay = AXChangeRelay { [weak self] in Task { await self?.observedChange() } }
                let pointer = Unmanaged.passRetained(relay).toOpaque()
                let element = AXUIElementCreateApplication(app.instance.pid)
                var observation = Observation(observer: observer, application: element, instance: app.instance, registrations: [], attemptedRegistrations: [], relayPointer: pointer)
                for name in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
                    guard Date() < observerDeadline else { break }
                    observation.attemptedRegistrations.append((element, name))
                    if AXObserverAddNotification(observer, element, name as CFString, pointer) == .success { observation.registrations.append((element, name)) }
                }
                observations[app.instance.pid] = observation
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
            guard var observation = observations[app.instance.pid] else { continue }
            // Reconcile window registrations without accumulating destroyed references.
            let current = entries.values.filter { $0.descriptor.instance == app.instance }.map(\.element)
            let observedApplication = observation.application
            let axObserver = observation.observer
            observation.attemptedRegistrations.removeAll { registration in
                !CFEqual(registration.0, observedApplication) && !current.contains(where: { CFEqual($0, registration.0) })
            }
            observation.registrations.removeAll { registration in
                guard !CFEqual(registration.0, observedApplication), !current.contains(where: { CFEqual($0, registration.0) }) else { return false }
                if Date() < observerDeadline { AXObserverRemoveNotification(axObserver, registration.0, registration.1 as CFString) }
                return true
            }
            for element in current {
                guard Date() < observerDeadline else { break }
                for name in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification, kAXTitleChangedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
                    guard Date() < observerDeadline else { break }
                    guard !observation.attemptedRegistrations.contains(where: { CFEqual($0.0, element) && $0.1 == name }) else { continue }
                    observation.attemptedRegistrations.append((element, name))
                    // Unsupported notifications are ordinary per-application capability differences.
                    if AXObserverAddNotification(observation.observer, element, name as CFString, observation.relayPointer) == .success { observation.registrations.append((element, name)) }
                }
            }
            observations[app.instance.pid] = observation
        }
    }

    private func observedChange() {
        guard onChange != nil, Date() > suppressChangesUntil else { return }
        coalescer?.cancel()
        coalescer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await self?.deliverChange()
        }
    }
    private func deliverChange() { onChange?(); coalescer = nil }

    private func removeObserver(_ pid: Int32) {
        guard let observation = observations.removeValue(forKey: pid) else { return }
        // Removing the run-loop source immediately prevents future delivery. Observer
        // destruction releases remaining registrations even if a client is unresponsive.
        let cleanupDeadline = Date().addingTimeInterval(0.5)
        for (element, name) in observation.registrations {
            guard Date() < cleanupDeadline else { break }
            AXObserverRemoveNotification(observation.observer, element, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
        let relay = Unmanaged<AXChangeRelay>.fromOpaque(observation.relayPointer).takeRetainedValue()
        DispatchQueue.main.async { withExtendedLifetime(relay) {} }
    }
    public func stopObserving() async {
        coalescer?.cancel(); coalescer = nil; onChange = nil
        for pid in Array(observations.keys) { removeObserver(pid) }
        entries.removeAll()
    }
}
