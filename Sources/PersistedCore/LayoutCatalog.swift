import Foundation

/// A Carbon-compatible shortcut, kept independent of AppKit for persistence and validation.
public struct LayoutHotkey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.key = key
    }

    public var displayString: String {
        [(UInt32(4096), "⌃"), (2048, "⌥"), (512, "⇧"), (256, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key.uppercased()
    }

    public var isValid: Bool {
        let supportedModifiers: UInt32 = 256 | 512 | 2048 | 4096
        let requiredModifiers: UInt32 = 256 | 4096
        let functionKeys: Set<UInt32> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        return keyCode <= 127 && modifiers & ~supportedModifiers == 0
            && (modifiers & requiredModifiers != 0 || functionKeys.contains(keyCode))
            && !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && key.count <= 32
            && !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum LayoutCatalog {
    public static func suggestedName(for topology: DisplayTopology, existingNames: [String] = []) -> String {
        let displays = topology.surfaces
        let externalCount = displays.filter { !$0.isBuiltIn }.count
        let hasLaptop = displays.contains(where: \.isBuiltIn)
        let base: String
        if externalCount == 0 {
            base = hasLaptop ? "Laptop only" : "New layout"
        } else {
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .spellOut
            let count = formatter.string(from: NSNumber(value: externalCount)) ?? String(externalCount)
            base = count.prefix(1).uppercased() + count.dropFirst()
                + (externalCount == 1 ? " display" : " displays") + (hasLaptop ? " and laptop" : "")
        }
        let occupied = Set(existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        var result = base
        var suffix = 2
        while occupied.contains(result.lowercased()) {
            result = "\(base) (\(suffix))"
            suffix += 1
        }
        return result
    }

    /// All saved layouts remain accessible, irrespective of the connected display setup.
    public static func filteredLayouts(_ layouts: [Layout], query: String) -> [Layout] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return layouts }
        return layouts.filter { layout in
            let searchable = ([layout.name] + layout.effectiveWindows.map(\.identity.appName)).joined(separator: " ")
            return terms.allSatisfy { searchable.localizedStandardContains($0) }
        }
    }
}
