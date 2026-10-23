import Foundation

public struct Rect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var isValid: Bool {
        [x, y, width, height].allSatisfy { $0.isFinite && abs($0) < 1_000_000 }
            && width > 0 && height > 0 && abs(maxX) < 1_000_000 && abs(maxY) < 1_000_000
    }
    public func approximatelyEquals(_ other: Rect, tolerance: Double = 2) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

public enum LidState: String, Codable, Sendable, CaseIterable { case open, closed, unknown, notApplicable }
public enum LidPolicy: String, Codable, Sendable, CaseIterable { case exact, ignore }

/// IDs contain durable identity hints, never a persisted CGDirectDisplayID.
public struct DisplayRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var uuid: String?
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    public var isBuiltIn: Bool
    public var isActive: Bool
    public var isPrimary: Bool
    public var mirrorSourceID: String?
    public var identityIsAmbiguous: Bool
    public var frame: Rect
    public var usableFrame: Rect
    public var scale: Double
    public var rotation: Double
    public init(id: String, name: String, uuid: String? = nil, vendor: UInt32 = 0,
                model: UInt32 = 0, serial: UInt32 = 0, isBuiltIn: Bool = false,
                isActive: Bool = true, isPrimary: Bool = false, mirrorSourceID: String? = nil,
                identityIsAmbiguous: Bool = false, frame: Rect, usableFrame: Rect? = nil,
                scale: Double = 1, rotation: Double = 0) {
        self.id = id; self.name = name; self.uuid = uuid; self.vendor = vendor; self.model = model
        self.serial = serial; self.isBuiltIn = isBuiltIn; self.isActive = isActive
        self.isPrimary = isPrimary; self.mirrorSourceID = mirrorSourceID
        self.identityIsAmbiguous = identityIsAmbiguous; self.frame = frame
        self.usableFrame = usableFrame ?? frame; self.scale = scale; self.rotation = rotation
    }
}

/// Frame and usableFrame use AppKit bottom-left logical points. Windows use AX top-left points.
public struct DisplayTopology: Codable, Hashable, Sendable {
    public var displays: [DisplayRecord]
    public var lid: LidState
    public init(displays: [DisplayRecord] = [], lid: LidState = .unknown) {
        self.displays = displays; self.lid = lid
    }
    public var surfaces: [DisplayRecord] { displays.filter { $0.isActive && $0.mirrorSourceID == nil && $0.frame.isValid } }
    public var primaryFrame: Rect { displays.first(where: { $0.isPrimary })?.frame ?? surfaces.first?.frame ?? Rect() }
    public var hasAmbiguousIdentity: Bool { displays.contains(where: { $0.identityIsAmbiguous }) }
}

public struct WindowCapabilities: Codable, Hashable, Sendable {
    public var canMove: Bool
    public var canResize: Bool
    public init(canMove: Bool = true, canResize: Bool = true) { self.canMove = canMove; self.canResize = canResize }
}

public struct WindowIdentity: Codable, Hashable, Sendable {
    public var bundleID: String
    public var appName: String
    public var accessibilityID: String?
    public var documentID: String?
    public var title: String
    public var role: String
    public var subrole: String
    public init(bundleID: String, appName: String, accessibilityID: String? = nil,
                documentID: String? = nil, title: String = "", role: String = "AXWindow", subrole: String = "AXStandardWindow") {
        self.bundleID = bundleID; self.appName = appName; self.accessibilityID = accessibilityID
        self.documentID = documentID; self.title = title; self.role = role; self.subrole = subrole
    }
    public var normalizedTitle: String {
        title.precomposedStringWithCanonicalMapping.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

public enum MatchingRule: Codable, Hashable, Sendable {
    case automatic
    case exactTitle(String)
    case titleContains(String)
}

public struct SavedWindow: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var identity: WindowIdentity
    public var displayID: String
    public var frame: Rect
    public var sourceUsableFrame: Rect
    public var relativeFrame: Rect
    public var normalizedFrame: Rect
    public var minimized: Bool
    public var hidden: Bool
    public var fullscreen: Bool
    public var capabilities: WindowCapabilities
    public var matchingRule: MatchingRule
    public var desktopAssignment: DesktopAssignment?
    public init(id: UUID = UUID(), identity: WindowIdentity, displayID: String, frame: Rect,
                sourceUsableFrame: Rect, relativeFrame: Rect, normalizedFrame: Rect,
                minimized: Bool = false, hidden: Bool = false, fullscreen: Bool = false,
                capabilities: WindowCapabilities = .init(), matchingRule: MatchingRule = .automatic,
                desktopAssignment: DesktopAssignment? = nil) {
        self.id = id; self.identity = identity; self.displayID = displayID; self.frame = frame
        self.sourceUsableFrame = sourceUsableFrame; self.relativeFrame = relativeFrame
        self.normalizedFrame = normalizedFrame; self.minimized = minimized; self.hidden = hidden
        self.fullscreen = fullscreen; self.capabilities = capabilities; self.matchingRule = matchingRule
        self.desktopAssignment = desktopAssignment
    }
}

public struct ApplicationInstance: Hashable, Sendable {
    public var pid: Int32
    public var launchDate: Date
    public init(pid: Int32, launchDate: Date) { self.pid = pid; self.launchDate = launchDate }
}

/// Opaque worker token. AX objects never leave the Accessibility worker.
public struct LiveWindow: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var instance: ApplicationInstance
    public var identity: WindowIdentity
    public var frame: Rect
    public var capabilities: WindowCapabilities
    public var minimized: Bool
    public var hidden: Bool
    public var fullscreen: Bool
    public var desktopAssignment: DesktopAssignment?
    public init(id: UUID = UUID(), instance: ApplicationInstance, identity: WindowIdentity, frame: Rect,
                capabilities: WindowCapabilities = .init(), minimized: Bool = false, hidden: Bool = false, fullscreen: Bool = false,
                desktopAssignment: DesktopAssignment? = nil) {
        self.id = id; self.instance = instance; self.identity = identity; self.frame = frame
        self.capabilities = capabilities; self.minimized = minimized; self.hidden = hidden; self.fullscreen = fullscreen
        self.desktopAssignment = desktopAssignment
    }
}

public struct CaptureIssue: Hashable, Sendable, Identifiable {
    public var id: String { bundleID + message }
    public var bundleID: String
    public var message: String
    public init(bundleID: String, message: String) { self.bundleID = bundleID; self.message = message }
}
public struct WindowCapture: Sendable {
    public var windows: [LiveWindow]
    public var issues: [CaptureIssue]
    public var permissionGranted: Bool
    public var runningBundleIDs: Set<String>
    public var desktopSnapshot: DesktopSnapshot?
    public init(windows: [LiveWindow] = [], issues: [CaptureIssue] = [], permissionGranted: Bool = true,
                runningBundleIDs: Set<String> = [], desktopSnapshot: DesktopSnapshot? = nil) {
        self.windows = windows; self.issues = issues; self.permissionGranted = permissionGranted
        self.runningBundleIDs = runningBundleIDs.union(windows.map { $0.identity.bundleID })
        self.desktopSnapshot = desktopSnapshot
    }
    public var isComplete: Bool { permissionGranted && issues.isEmpty }
}

public struct LayoutOptions: Codable, Hashable, Sendable {
    public var rememberAdjustments = false
    public var launchMissingApplications = false
    public var preserveWindowSize = false
    public var lidPolicy: LidPolicy = .exact
    public var restoreDesktops = true
    public var autoModeEnabled = true
    public var autoSaveEnabled = true
    public var excludedDesktopIDs: Set<String> = []
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case rememberAdjustments, launchMissingApplications, preserveWindowSize, lidPolicy, restoreDesktops
        case autoModeEnabled, autoSaveEnabled, excludedDesktopIDs
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rememberAdjustments = try container.decodeIfPresent(Bool.self, forKey: .rememberAdjustments) ?? false
        launchMissingApplications = try container.decodeIfPresent(Bool.self, forKey: .launchMissingApplications) ?? false
        preserveWindowSize = try container.decodeIfPresent(Bool.self, forKey: .preserveWindowSize) ?? false
        lidPolicy = try container.decodeIfPresent(LidPolicy.self, forKey: .lidPolicy) ?? .exact
        restoreDesktops = try container.decodeIfPresent(Bool.self, forKey: .restoreDesktops) ?? true
        autoModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoModeEnabled) ?? true
        autoSaveEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoSaveEnabled) ?? true
        excludedDesktopIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedDesktopIDs) ?? []
    }
}
public struct LayoutRevision: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var windows: [SavedWindow]
    public var desktopSnapshot: DesktopSnapshot?
    public init(id: UUID = UUID(), date: Date = Date(), windows: [SavedWindow], desktopSnapshot: DesktopSnapshot? = nil) {
        self.id = id; self.date = date; self.windows = windows
        self.desktopSnapshot = desktopSnapshot
    }
}
public struct Layout: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var topology: DisplayTopology
    public var saved: LayoutRevision
    public var remembered: LayoutRevision?
    public var history: [LayoutRevision]
    public var options: LayoutOptions
    public var importedNeedsMapping: Bool
    public var iconName: String
    public var hotkey: LayoutHotkey?
    public var excludedBundleIDs: Set<String>
    /// Offline edits must be applied or explicitly recaptured before live learning
    /// can replace them. This is independent of the user's Auto Save preference.
    public var editedAwaitingApply: Bool
    public init(id: UUID = UUID(), name: String, topology: DisplayTopology, windows: [SavedWindow], options: LayoutOptions = .init(),
                iconName: String = "rectangle.3.group", hotkey: LayoutHotkey? = nil, excludedBundleIDs: Set<String> = [],
                desktopSnapshot: DesktopSnapshot? = nil, editedAwaitingApply: Bool = false) {
        self.id = id; self.name = name; self.topology = topology
        self.saved = .init(windows: windows, desktopSnapshot: desktopSnapshot); self.remembered = nil; self.history = []
        self.options = options; self.importedNeedsMapping = false
        self.iconName = iconName; self.hotkey = hotkey; self.excludedBundleIDs = excludedBundleIDs
        self.editedAwaitingApply = editedAwaitingApply
    }
    public var effectiveWindows: [SavedWindow] { remembered?.windows ?? saved.windows }
    public var effectiveDesktopSnapshot: DesktopSnapshot? { (remembered ?? saved).desktopSnapshot }

    private enum CodingKeys: String, CodingKey {
        case id, name, topology, saved, remembered, history, options, importedNeedsMapping
        case iconName, hotkey, excludedBundleIDs, editedAwaitingApply
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        topology = try container.decode(DisplayTopology.self, forKey: .topology)
        saved = try container.decode(LayoutRevision.self, forKey: .saved)
        remembered = try container.decodeIfPresent(LayoutRevision.self, forKey: .remembered)
        history = try container.decode([LayoutRevision].self, forKey: .history)
        options = try container.decode(LayoutOptions.self, forKey: .options)
        importedNeedsMapping = try container.decode(Bool.self, forKey: .importedNeedsMapping)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName) ?? "rectangle.3.group"
        hotkey = try container.decodeIfPresent(LayoutHotkey.self, forKey: .hotkey)
        excludedBundleIDs = try container.decodeIfPresent(Set<String>.self, forKey: .excludedBundleIDs) ?? []
        editedAwaitingApply = try container.decodeIfPresent(Bool.self, forKey: .editedAwaitingApply) ?? false
    }
}

public struct WindowExclusion: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var bundleID: String
    public var title: String?
    public init(id: UUID = UUID(), bundleID: String, title: String? = nil) { self.id = id; self.bundleID = bundleID; self.title = title }
    public func excludes(_ identity: WindowIdentity) -> Bool {
        bundleID == identity.bundleID && (title == nil || title == identity.title)
    }
}
public struct DisplayMapping: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var layoutID: UUID
    public var targetSetupKey: String
    public var assignments: [String: String]
    public var skipped: Set<String>
    public init(id: UUID = UUID(), layoutID: UUID, targetSetupKey: String, assignments: [String: String], skipped: Set<String> = []) {
        self.id = id; self.layoutID = layoutID; self.targetSetupKey = targetSetupKey; self.assignments = assignments; self.skipped = skipped
    }
}
public struct AppSettings: Codable, Hashable, Sendable {
    public var automaticSwitching = false
    public var enableAutomaticAfterFirstSave = true
    public var onboardingCompleted = false
    public var autoModeEnabled = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case automaticSwitching, enableAutomaticAfterFirstSave, onboardingCompleted, autoModeEnabled
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        automaticSwitching = try container.decodeIfPresent(Bool.self, forKey: .automaticSwitching) ?? false
        enableAutomaticAfterFirstSave = try container.decodeIfPresent(Bool.self, forKey: .enableAutomaticAfterFirstSave) ?? true
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? false
        autoModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoModeEnabled) ?? false
    }
}
public struct RecoverySnapshot: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var topology: DisplayTopology
    public var windows: [SavedWindow]
    public var desktopSnapshot: DesktopSnapshot?
    public init(id: UUID = UUID(), date: Date = Date(), topology: DisplayTopology, windows: [SavedWindow], desktopSnapshot: DesktopSnapshot? = nil) {
        self.id = id; self.date = date; self.topology = topology; self.windows = windows
        self.desktopSnapshot = desktopSnapshot
    }
}
public struct Library: Codable, Sendable {
    public var schemaVersion = 2
    public var layouts: [Layout] = []
    public var preferredLayouts: [String: UUID] = [:]
    public var displayAliases: [String: String] = [:]
    public var displayMappings: [DisplayMapping] = []
    public var exclusions: [WindowExclusion] = []
    public var settings = AppSettings()
    public var recovery: [RecoverySnapshot] = []
    public var schedules: [LayoutSchedule] = []
    public var displayProfileNames: [String: String] = [:]
    public var autoLayoutIDs: [String: UUID] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, layouts, preferredLayouts, displayAliases, displayMappings, exclusions, settings, recovery
        case schedules, displayProfileNames, autoLayoutIDs
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        layouts = try container.decode([Layout].self, forKey: .layouts)
        preferredLayouts = try container.decode([String: UUID].self, forKey: .preferredLayouts)
        displayAliases = try container.decode([String: String].self, forKey: .displayAliases)
        displayMappings = try container.decode([DisplayMapping].self, forKey: .displayMappings)
        exclusions = try container.decode([WindowExclusion].self, forKey: .exclusions)
        settings = try container.decode(AppSettings.self, forKey: .settings)
        recovery = try container.decode([RecoverySnapshot].self, forKey: .recovery)
        schedules = try container.decodeIfPresent([LayoutSchedule].self, forKey: .schedules) ?? []
        displayProfileNames = try container.decodeIfPresent([String: String].self, forKey: .displayProfileNames) ?? [:]
        autoLayoutIDs = try container.decodeIfPresent([String: UUID].self, forKey: .autoLayoutIDs) ?? [:]
    }
}

public enum WindowOutcomeKind: String, Codable, Sendable, CaseIterable {
    case restored, alreadyPositioned, adjustedToConstraints, missingApplication, missingWindow
    case ambiguous, unsupported, timedOut, cancelled
    public var succeeded: Bool { [.restored, .alreadyPositioned, .adjustedToConstraints].contains(self) }
}
public struct WindowOutcome: Identifiable, Sendable {
    public var id: UUID
    public var appName: String
    public var kind: WindowOutcomeKind
    public var explanation: String
    public var actualFrame: Rect?
    public var didMutate: Bool
    public init(id: UUID, appName: String, kind: WindowOutcomeKind, explanation: String = "", actualFrame: Rect? = nil, didMutate: Bool = false) {
        self.id = id; self.appName = appName; self.kind = kind; self.explanation = explanation; self.actualFrame = actualFrame
        self.didMutate = didMutate
    }
}
public struct PlannedPlacement: Sendable {
    public var savedWindow: SavedWindow
    public var liveWindow: LiveWindow
    public var targetFrame: Rect
    public var targetUsableFrame: Rect?
    public init(savedWindow: SavedWindow, liveWindow: LiveWindow, targetFrame: Rect, targetUsableFrame: Rect? = nil) {
        self.savedWindow = savedWindow; self.liveWindow = liveWindow; self.targetFrame = targetFrame
        self.targetUsableFrame = targetUsableFrame
    }
}
public struct RestorePlan: Sendable {
    public var layoutID: UUID
    public var revisionID: UUID
    public var generation: UInt64
    public var topology: DisplayTopology
    public var placements: [PlannedPlacement]
    public var unresolved: [WindowOutcome]
    public var mappings: [String: String]
    public init(layoutID: UUID, revisionID: UUID, generation: UInt64, topology: DisplayTopology,
                placements: [PlannedPlacement], unresolved: [WindowOutcome], mappings: [String: String]) {
        self.layoutID = layoutID; self.revisionID = revisionID; self.generation = generation
        self.topology = topology; self.placements = placements; self.unresolved = unresolved; self.mappings = mappings
    }
}
