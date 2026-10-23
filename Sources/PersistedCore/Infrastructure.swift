import Foundation

/// The only shared mutable value used by the AX worker. Every mutation checks this gate.
/// A lock is required because a synchronous AX call must not hop to the main actor.
public final class MutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    public init() {}
    public var current: UInt64 { lock.withLock { value } }
    @discardableResult public func invalidate() -> UInt64 { lock.withLock { value &+= 1; return value } }
    public func isValid(_ generation: UInt64) -> Bool { lock.withLock { value == generation } }
}

public protocol WindowAccessing: Sendable {
    func capture(exclusions: [WindowExclusion]) async -> WindowCapture
    func place(_ placement: PlannedPlacement, generation: UInt64, gate: MutationGate, automatic: Bool) async -> WindowOutcome
    /// Read-only preflight. Desktop creation and activation require assignment support too.
    func desktopRestorationCapability() async -> DesktopRestorationCapability
    func prepareDesktops(_ snapshot: DesktopSnapshot, mapping: [String: String], generation: UInt64,
                         gate: MutationGate, automatic: Bool) async -> DesktopPreparation
    func moveToDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate, automatic: Bool) async -> DesktopMoveResult
    func verifyDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate) async -> DesktopMoveResult
    func restoreActiveDesktops(_ snapshot: DesktopSnapshot, destinations: [String: UInt64],
                               generation: UInt64, gate: MutationGate, automatic: Bool) async -> [String]
}

public enum DesktopRestorationCapability: Equatable, Sendable {
    case available
    case unavailable(String)

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
    public var limitation: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

/// Runtime destinations are never encoded into a saved layout.
public struct DesktopPreparation: Sendable {
    public var destinations: [String: UInt64]
    public var issues: [String]
    public var didMutate: Bool
    public init(destinations: [String: UInt64] = [:], issues: [String] = [], didMutate: Bool = false) {
        self.destinations = destinations; self.issues = issues; self.didMutate = didMutate
    }
}
public struct DesktopMoveResult: Sendable {
    public var succeeded: Bool
    public var didMutate: Bool
    public var message: String?
    public init(succeeded: Bool, didMutate: Bool = false, message: String? = nil) {
        self.succeeded = succeeded; self.didMutate = didMutate; self.message = message
    }
}
public extension WindowAccessing {
    func desktopRestorationCapability() async -> DesktopRestorationCapability {
        .unavailable("Desktop restoration is unavailable on this Mac. Window positions and sizes can still be restored.")
    }
    func prepareDesktops(_ snapshot: DesktopSnapshot, mapping: [String: String], generation: UInt64,
                         gate: MutationGate, automatic: Bool) async -> DesktopPreparation {
        .init(issues: ["Desktop restoration is unavailable on this Mac."])
    }
    func moveToDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate, automatic: Bool) async -> DesktopMoveResult {
        .init(succeeded: false, message: "The window’s desktop could not be restored.")
    }
    func restoreActiveDesktops(_ snapshot: DesktopSnapshot, destinations: [String: UInt64],
                               generation: UInt64, gate: MutationGate, automatic: Bool) async -> [String] { [] }
    func verifyDesktop(_ live: LiveWindow, assignment: DesktopAssignment, destinations: [String: UInt64],
                       generation: UInt64, gate: MutationGate) async -> DesktopMoveResult {
        .init(succeeded: false, message: "The window’s final desktop could not be verified.")
    }
}
@MainActor public protocol TopologyProviding: AnyObject {
    func snapshot() -> DisplayTopology
}
@MainActor public protocol PermissionChecking: AnyObject {
    var isTrusted: Bool { get }
}
@MainActor public protocol ApplicationLaunching: AnyObject {
    func launch(bundleIDs: Set<String>) async -> [CaptureIssue]
}
public protocol RestoreClock: Sendable {
    func sleep(for duration: Duration) async throws
    func now() -> Date
}
public struct SystemRestoreClock: RestoreClock {
    public init() {}
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
    public func now() -> Date { Date() }
}
public enum RestoreEvent: Sendable {
    case displayChanged, lidChanged, sleep, wake, screenSleep, screenWake
    case sessionInactive, sessionActive, applicationsChanged, windowsChanged, permissionChanged
}
public enum CoordinatorState: String, Sendable {
    case idle, settling, restoring, suspended, permissionRequired, waiting
}
public struct CoordinatorTiming: Sendable {
    public var quietPeriod: Duration = .seconds(1)
    public var observationInterval: Duration = .milliseconds(400)
    public var wakeGrace: Duration = .seconds(2)
    public var learningDebounce: Duration = .seconds(2)
    public var writeSuppression: TimeInterval = 4
    public var maxObservations = 8
    public var launchRetries = 4
    public init() {}
}

public protocol LibraryStoring: Sendable {
    func load() async throws -> Library
    func save(_ library: Library) async throws
}
