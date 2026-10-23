import SwiftUI
import PersistedCore

struct AutoModeSettingsControls: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Auto mode", isOn: Binding(get: { model.library.settings.autoModeEnabled }, set: { model.setAutoMode($0) }))
                .toggleStyle(.switch).controlSize(.small)
            Text("Automatically remember your desktops, apps, and window positions for each display setup, then restore that configuration when you return.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Each setup keeps its own Auto preset. You can choose a different one in layout details. App and desktop inclusion controls apply to Auto mode and manual restoration.")
                .font(.caption).foregroundStyle(.secondary)
            if let limitation = model.desktopRestorationCapability?.limitation {
                DesktopCapabilityNotice(message: limitation)
            }
        }
    }
}

struct LayoutAutoModeControls: View {
    let model: AppModel
    let layout: PersistedCore.Layout

    private var selected: Bool { model.library.autoLayoutIDs[layout.topology.setupKey] == layout.id }
    private var selectedName: String? {
        guard let id = model.library.autoLayoutIDs[layout.topology.setupKey] else { return nil }
        return model.library.layouts.first { $0.id == id }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            option("Use in Auto mode", keyPath: \.autoModeEnabled)
            option("Remember changes in Auto mode", keyPath: \.autoSaveEnabled)
                .disabled(!layout.options.autoModeEnabled)
            if !model.library.settings.autoModeEnabled {
                Text("Auto mode is off. These preferences take effect when you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !layout.options.autoModeEnabled {
                Text("This layout is excluded from Auto mode. You can still apply it manually.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if layout.options.autoModeEnabled {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected ? "Auto preset for this setup" : selectedName.map { "Auto uses “\($0)” for this setup." } ?? "Choose this layout as the Auto preset for its setup.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !layout.options.autoSaveEnabled {
                            Text("Saved positions are restored without remembering new changes.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if !selected {
                        Button("Use this preset") { model.setAutoLayout(layout.id) }
                            .disabled(model.busy || layout.importedNeedsMapping)
                            .fixedSize()
                    }
                }
                if layout.importedNeedsMapping {
                    Text("Review the display mapping before using this layout in Auto mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
    private func option(_ title: String, keyPath: WritableKeyPath<LayoutOptions, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { layout.options[keyPath: keyPath] }, set: { value in
            var options = layout.options
            options[keyPath: keyPath] = value
            model.setOptions(layout.id, options: options)
        })).disabled(model.busy)
    }
}
