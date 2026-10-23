import Foundation

public enum RepositoryError: LocalizedError, Sendable {
    case unsupportedVersion(Int), invalid(String), corrupt(String), readOnly, sizeLimitExceeded(Int)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This library uses format \(version), which requires a newer Persisted. Your data has been preserved."
        case .invalid(let reason): "The layout data is invalid: \(reason)"
        case .corrupt(let path): "The library could not be read. Its original contents were preserved at \(path)."
        case .readOnly: "The library is protected because it could not be safely loaded. Export your layouts before repairing it."
        case .sizeLimitExceeded(let limit):
            "The library exceeds the \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) size limit. Remove unused layouts or older saved revisions and try again. Your previously saved library has been preserved."
        }
    }
}

/// One serialized owner for local data. Atomic writes preserve a separately validated last-good copy.
public actor LayoutRepository: LibraryStoring {
    static let maximumLibraryBytes = 25_000_000
    public let directory: URL
    private let byteLimit: Int
    private var writable = true
    private var lastGoodData: Data?
    public private(set) var recoveryNotice: String?
    private var primaryURL: URL { directory.appendingPathComponent("Library.json") }
    private var backupURL: URL { directory.appendingPathComponent("Library.previous.json") }
    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Persisted", isDirectory: true)
        byteLimit = Self.maximumLibraryBytes
    }
    /// A smaller limit permits boundary and recovery tests without allocating large libraries.
    init(directory: URL, byteLimit: Int) {
        precondition((1...Self.maximumLibraryBytes).contains(byteLimit))
        self.directory = directory
        self.byteLimit = byteLimit
    }
    public func load() throws -> Library {
        do { return try loadValidated() }
        catch { writable = false; throw error }
    }
    private func loadValidated() throws -> Library {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard fm.fileExists(atPath: primaryURL.path) else {
            if fm.fileExists(atPath: backupURL.path) {
                let data = try Data(contentsOf: backupURL)
                let library = try Self.decode(data, byteLimit: byteLimit)
                lastGoodData = data
                recoveryNotice = "Recovered the previous library after an interrupted save."
                return library
            }
            return Library()
        }
        let data = try Data(contentsOf: primaryURL)
        do {
            let library = try Self.decode(data, byteLimit: byteLimit)
            lastGoodData = data
            return library
        } catch RepositoryError.unsupportedVersion(let version) {
            writable = false
            throw RepositoryError.unsupportedVersion(version)
        } catch {
            let preserved = directory.appendingPathComponent("Library.corrupt-\(UUID().uuidString).json")
            try data.write(to: preserved, options: .atomic)
            if let backup = try? Data(contentsOf: backupURL), let library = try? Self.decode(backup, byteLimit: byteLimit) {
                lastGoodData = backup
                recoveryNotice = "Recovered the previous valid library. The unreadable version was preserved for diagnosis."
                return library
            }
            writable = false
            throw RepositoryError.corrupt(preserved.path)
        }
    }
    public func save(_ library: Library) throws {
        guard writable else { throw RepositoryError.readOnly }
        // Validate the exact bytes before replacing either the primary file or its backup.
        let data = try Self.encode(library, byteLimit: byteLimit)
        if data == lastGoodData { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let previous = lastGoodData { try previous.write(to: backupURL, options: .atomic) }
        try data.write(to: primaryURL, options: .atomic)
        lastGoodData = data
    }
    public static func encode(_ library: Library) throws -> Data {
        try encode(library, byteLimit: maximumLibraryBytes)
    }
    static func encode(_ library: Library, byteLimit: Int) throws -> Data {
        try validate(library)
        var current = library
        current.schemaVersion = 2
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(current)
        try validateSize(data, byteLimit: byteLimit)
        return data
    }
    public static func decode(_ data: Data) throws -> Library {
        try decode(data, byteLimit: maximumLibraryBytes)
    }
    static func decode(_ data: Data, byteLimit: Int) throws -> Library {
        try validateSize(data, byteLimit: byteLimit)
        struct Header: Decodable { let schemaVersion: Int }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(Header.self, from: data)
        guard (1...2).contains(header.schemaVersion) else { throw RepositoryError.unsupportedVersion(header.schemaVersion) }
        var library = try decoder.decode(Library.self, from: data)
        try validate(library)
        library.schemaVersion = 2
        return library
    }
    private static func validateSize(_ data: Data, byteLimit: Int) throws {
        precondition((1...maximumLibraryBytes).contains(byteLimit))
        guard data.count <= byteLimit else { throw RepositoryError.sizeLimitExceeded(byteLimit) }
    }
    public static func validate(_ library: Library) throws {
        guard (1...2).contains(library.schemaVersion) else { throw RepositoryError.unsupportedVersion(library.schemaVersion) }
        guard library.layouts.count <= 500, library.recovery.count <= 30, library.schedules.count <= 500,
              library.displayProfileNames.count <= 500 else { throw RepositoryError.invalid("too many records") }
        guard Set(library.layouts.map(\.id)).count == library.layouts.count else { throw RepositoryError.invalid("duplicate layout identifiers") }
        var shortcuts: Set<String> = []
        for layout in library.layouts {
            guard !layout.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, layout.name.count <= 200,
                  layout.history.count <= 20 else { throw RepositoryError.invalid("layout name or revision count") }
            guard isNonemptyText(layout.iconName, maximum: 100), layout.excludedBundleIDs.count <= 500,
                  layout.excludedBundleIDs.allSatisfy({ isNonemptyText($0, maximum: 512) }),
                  layout.options.excludedDesktopIDs.count <= 2_048,
                  layout.options.excludedDesktopIDs.allSatisfy({ isNonemptyText($0, maximum: 512) }) else {
                throw RepositoryError.invalid("layout icon or excluded applications")
            }
            if let hotkey = layout.hotkey {
                guard hotkey.isValid else { throw RepositoryError.invalid("invalid layout shortcut") }
                guard shortcuts.insert("\(hotkey.keyCode):\(hotkey.modifiers)").inserted else {
                    throw RepositoryError.invalid("layouts cannot share the same shortcut")
                }
            }
            try validate(topology: layout.topology)
            for revision in [layout.saved] + [layout.remembered].compactMap({ $0 }) + layout.history {
                try validate(windows: revision.windows, topology: layout.topology)
                try validate(desktopSnapshot: revision.desktopSnapshot, windows: revision.windows, topology: layout.topology)
            }
        }
        for snapshot in library.recovery {
            try validate(topology: snapshot.topology)
            try validate(windows: snapshot.windows, topology: snapshot.topology)
            try validate(desktopSnapshot: snapshot.desktopSnapshot, windows: snapshot.windows, topology: snapshot.topology)
        }
        for mapping in library.displayMappings {
            guard let layout = library.layouts.first(where: { $0.id == mapping.layoutID }),
                  Set(mapping.assignments.keys).isSubset(of: Set(layout.topology.surfaces.map(\.id))),
                  mapping.skipped.isSubset(of: Set(layout.topology.surfaces.map(\.id))),
                  Set(mapping.assignments.keys).isDisjoint(with: mapping.skipped),
                  !mapping.targetSetupKey.isEmpty else { throw RepositoryError.invalid("invalid display mapping") }
        }
        guard library.preferredLayouts.values.allSatisfy({ id in library.layouts.contains(where: { $0.id == id && !$0.importedNeedsMapping }) }) else {
            throw RepositoryError.invalid("preferred layout is unavailable or awaiting import review")
        }
        guard library.autoLayoutIDs.count <= 500, library.autoLayoutIDs.allSatisfy({ key, id in
            isNonemptyText(key, maximum: 100_000)
                && library.layouts.contains(where: { $0.id == id && !$0.importedNeedsMapping && $0.topology.setupKey == key })
        }) else { throw RepositoryError.invalid("invalid Auto mode preset") }
        guard Set(library.schedules.map(\.id)).count == library.schedules.count else {
            throw RepositoryError.invalid("duplicate schedule identifiers")
        }
        for schedule in library.schedules {
            guard schedule.isValid,
                  let layout = library.layouts.first(where: { $0.id == schedule.layoutID }),
                  !schedule.enabled || !layout.importedNeedsMapping else {
                throw RepositoryError.invalid("invalid schedule or unavailable layout")
            }
        }
        guard library.displayProfileNames.allSatisfy({ isNonemptyText($0.key, maximum: 10_000) && isNonemptyText($0.value, maximum: 200) }) else {
            throw RepositoryError.invalid("invalid display profile name")
        }
    }
    private static func isNonemptyText(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func validate(topology: DisplayTopology) throws {
        guard !topology.surfaces.isEmpty, topology.displays.count <= 128,
              Set(topology.displays.map(\.id)).count == topology.displays.count,
              topology.surfaces.filter(\.isPrimary).count == 1 else { throw RepositoryError.invalid("invalid display inventory or primary display") }
        for display in topology.displays {
            guard !display.id.isEmpty, display.scale.isFinite, display.scale > 0, display.scale <= 16,
                  display.rotation.isFinite else { throw RepositoryError.invalid("invalid display geometry") }
            if display.isActive {
                guard display.frame.isValid, display.usableFrame.isValid,
                      display.usableFrame.minX >= display.frame.minX - 2,
                      display.usableFrame.minY >= display.frame.minY - 2,
                      display.usableFrame.maxX <= display.frame.maxX + 2,
                      display.usableFrame.maxY <= display.frame.maxY + 2 else { throw RepositoryError.invalid("invalid usable display geometry") }
            } else {
                // Inactive physical outputs can honestly have unknown (zero) geometry.
                for rect in [display.frame, display.usableFrame] {
                    guard [rect.x, rect.y, rect.width, rect.height].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
                          rect.width >= 0, rect.height >= 0 else { throw RepositoryError.invalid("invalid inactive display geometry") }
                }
            }
            if let mirror = display.mirrorSourceID {
                guard mirror != display.id, topology.surfaces.contains(where: { $0.id == mirror }) else { throw RepositoryError.invalid("invalid mirror group") }
            }
        }
    }
    private static func validate(windows: [SavedWindow], topology: DisplayTopology) throws {
        guard !windows.isEmpty, windows.count <= 2_000, Set(windows.map(\.id)).count == windows.count else { throw RepositoryError.invalid("empty or duplicate windows") }
        for window in windows {
            guard !window.identity.bundleID.isEmpty, topology.surfaces.contains(where: { $0.id == window.displayID }),
                  window.frame.isValid, window.relativeFrame.isValid, window.sourceUsableFrame.isValid,
                  window.normalizedFrame.isValid else { throw RepositoryError.invalid("invalid saved window geometry or display") }
            let relative = Rect(x: window.frame.x - window.sourceUsableFrame.x, y: window.frame.y - window.sourceUsableFrame.y,
                                width: window.frame.width, height: window.frame.height)
            let normalized = Rect(x: relative.x / window.sourceUsableFrame.width, y: relative.y / window.sourceUsableFrame.height,
                                  width: relative.width / window.sourceUsableFrame.width, height: relative.height / window.sourceUsableFrame.height)
            guard window.relativeFrame.approximatelyEquals(relative, tolerance: 0.01),
                  window.normalizedFrame.approximatelyEquals(normalized, tolerance: 0.00001) else {
                throw RepositoryError.invalid("inconsistent saved window coordinates")
            }
        }
    }
    private static func validate(desktopSnapshot: DesktopSnapshot?, windows: [SavedWindow], topology: DisplayTopology) throws {
        guard let snapshot = desktopSnapshot else {
            guard windows.allSatisfy({ $0.desktopAssignment == nil }) else {
                throw RepositoryError.invalid("desktop assignments require a matching desktop snapshot")
            }
            return
        }
        let groups = snapshot.displays
        guard !groups.isEmpty, groups.count <= 128,
              snapshot.separateDisplays || groups.count == 1,
              Set(groups.map(\.displayID)).count == groups.count,
              Set(groups.map(\.displayID)).isSubset(of: Set(topology.surfaces.map(\.id))),
              snapshot.totalSpaceCount <= 2_048 else {
            throw RepositoryError.invalid("invalid desktop display inventory")
        }
        var desktopDisplays: [String: String] = [:]
        for group in groups {
            guard !group.desktops.isEmpty, group.desktops.count <= 128,
                  group.desktops.contains(where: { $0.kind == .ordinary }),
                  group.desktops.filter(\.isActive).count <= 1,
                  group.desktops.map(\.ordinal).sorted() == Array(0..<group.desktops.count) else {
                throw RepositoryError.invalid("invalid desktop count, order, or active desktop")
            }
            for desktop in group.desktops {
                guard isNonemptyText(desktop.id, maximum: 512), desktopDisplays[desktop.id] == nil,
                      desktop.uuidHint.map({ isNonemptyText($0, maximum: 512) }) ?? true else {
                    throw RepositoryError.invalid("invalid or duplicate desktop identifiers")
                }
                desktopDisplays[desktop.id] = group.displayID
            }
        }
        for window in windows {
            guard case let .desktop(desktopID) = window.desktopAssignment else { continue }
            guard let displayID = desktopDisplays[desktopID],
                  !snapshot.separateDisplays || displayID == window.displayID else {
                throw RepositoryError.invalid("window desktop assignment is missing or belongs to another display")
            }
        }
    }
    /// Imports always receive fresh IDs and lose automatic activation and machine-specific mappings.
    public static func importPreview(_ data: Data) throws -> [Layout] {
        let imported = try decode(data)
        return imported.layouts.map { source in
            var layout = source
            layout.id = UUID()
            layout.importedNeedsMapping = true
            layout.options.rememberAdjustments = false
            layout.options.launchMissingApplications = false
            layout.hotkey = nil
            layout.saved.desktopSnapshot = layout.saved.desktopSnapshot?.removingMachineHints()
            if var remembered = layout.remembered {
                remembered.desktopSnapshot = remembered.desktopSnapshot?.removingMachineHints()
                layout.remembered = remembered
            }
            layout.history = layout.history.map { revision in
                var portable = revision
                portable.desktopSnapshot = revision.desktopSnapshot?.removingMachineHints()
                return portable
            }
            return layout
        }
    }
}
