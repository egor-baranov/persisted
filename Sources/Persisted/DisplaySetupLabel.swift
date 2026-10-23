import SwiftUI
import PersistedCore

/// A compact inventory of active screens, including mirrored outputs.
struct DisplaySetupLabel: View {
    let topology: DisplayTopology
    var name: String? = nil

    private var activeDisplays: [DisplayRecord] { topology.displays.filter { $0.isActive && $0.frame.isValid } }
    private var hasLaptop: Bool { activeDisplays.contains(where: \.isBuiltIn) }
    private var externalCount: Int { activeDisplays.filter { !$0.isBuiltIn }.count }
    private var profileName: String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
    private var setupDescription: String {
        let external = "\(externalCount) external \(externalCount == 1 ? "display" : "displays")"
        if hasLaptop { return externalCount > 0 ? "Laptop and \(external)" : "Laptop display" }
        return externalCount > 0 ? external : "No active displays"
    }
    var helpText: String {
        var lines = [profileName.map { "\($0) · \(setupDescription)" } ?? setupDescription]
        let mirroredCount = activeDisplays.filter { $0.mirrorSourceID != nil }.count
        if mirroredCount > 0 { lines.append("\(mirroredCount) \(mirroredCount == 1 ? "display mirrors" : "displays mirror") another screen") }
        lines.append(contentsOf: activeDisplays.map(\.name))
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 5) {
            HStack(spacing: 4) {
                if hasLaptop { Image(systemName: "laptopcomputer") }
                if hasLaptop && externalCount > 0 { Text("+") }
                if externalCount > 0 {
                    Image(systemName: "display")
                    Text("\(externalCount)").monospacedDigit()
                }
                if !hasLaptop && externalCount == 0 {
                    Image(systemName: "display")
                    Text("0").monospacedDigit()
                }
            }.fixedSize()
            if let profileName { Text(profileName).lineLimit(1).truncationMode(.tail) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(profileName.map { "\($0), \(setupDescription)" } ?? setupDescription)
        .help(helpText)
    }
}
