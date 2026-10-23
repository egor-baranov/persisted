import SwiftUI
import PersistedCore

struct DesktopCapabilityNotice: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One hierarchy for the saved displays, their desktops, and the windows on each desktop.
struct LayoutWorkspaceView: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let matchWindow: (SavedWindow) -> Void
    let assignWindow: (SavedWindow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if layout.effectiveDesktopSnapshot == nil {
                Label("Update this layout to capture which desktop each window belongs to.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(LayoutDesktopCatalog.groups(for: layout)) { group in
                LayoutDisplayWorkspace(model: model, layout: layout, group: group,
                    matchWindow: matchWindow, assignWindow: assignWindow)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LayoutDisplayWorkspace: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let group: LayoutDisplayGroup
    let matchWindow: (SavedWindow) -> Void
    let assignWindow: (SavedWindow) -> Void
    @State private var selectedID: String?

    private var selection: LayoutDesktopGroup? {
        group.desktops.first { $0.id == selectedID }
            ?? group.desktops.first { !$0.windows.isEmpty }
            ?? group.desktops.first { $0.isSavedActive }
            ?? group.desktops.first
    }
    private var displayName: String {
        group.sharedAcrossDisplays ? "Shared across displays"
            : model.library.displayAliases[group.id] ?? group.display?.name ?? "Saved display"
    }
    private var desktopCount: Int {
        group.desktops.filter { $0.kind == .ordinary }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: group.sharedAcrossDisplays ? "display.2" : group.display?.isBuiltIn == true ? "laptopcomputer" : "display")
                    .font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
                Text(displayName).font(.callout.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 4)
                if desktopCount > 0 {
                    Text("\(desktopCount) \(desktopCount == 1 ? "desktop" : "desktops")")
                        .font(.caption).foregroundStyle(.secondary).fixedSize()
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98, maximum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(group.desktops) { desktop in
                    DesktopTile(desktop: desktop, excludedBundleIDs: layout.excludedBundleIDs, exclusions: model.library.exclusions,
                        included: isIncluded(desktop), selected: selection?.id == desktop.id) { selectedID = desktop.id }
                }
            }
            if let selection {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(selection.title).font(.caption.weight(.medium))
                        if selection.isSavedActive {
                            Text("Active when saved").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if selection.kind == .fullscreen || selection.kind == .allDesktops {
                            Text("Preserved").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if selection.kind == .ordinary, let desktopID = selection.savedDesktopID {
                        Toggle("Include this desktop", isOn: Binding(get: { isIncluded(selection) }, set: {
                            model.setLayoutDesktopEnabled(layoutID: layout.id, desktopID: desktopID, enabled: $0)
                        })).toggleStyle(.checkbox).disabled(model.busy)
                            .accessibilityLabel("Include \(selection.title) on \(displayName)")
                            .help("Include this desktop’s windows in manual and Auto restoration. Its place in the desktop order is always kept.")
                        if !isIncluded(selection) {
                            Text("Its windows stay saved but are not restored or remembered. This desktop keeps its place in the order.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if selection.windows.isEmpty {
                        Text("No saved windows on this desktop.").font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7)
                    } else {
                        DesktopWindowList(model: model, layout: layout, windows: selection.windows, desktopIncluded: isIncluded(selection),
                            matchWindow: matchWindow, assignWindow: assignWindow)
                    }
                }
                .padding(11)
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }
        }.accessibilityElement(children: .contain)
            .accessibilityLabel(displayName)
    }
    private func isIncluded(_ desktop: LayoutDesktopGroup) -> Bool {
        guard desktop.kind == .ordinary, let id = desktop.savedDesktopID else { return true }
        return !layout.options.excludedDesktopIDs.contains(id)
    }
}

private struct DesktopTile: View {
    let desktop: LayoutDesktopGroup
    let excludedBundleIDs: Set<String>
    let exclusions: [WindowExclusion]
    let included: Bool
    let selected: Bool
    let select: () -> Void

    private var apps: [SavedWindow] {
        var seen = Set<String>()
        return desktop.windows.filter { seen.insert($0.identity.bundleID).inserted }
    }
    private var spokenSummary: String {
        let names = apps.map { $0.identity.appName + (appIsExcluded($0.identity.bundleID) ? " (excluded)" : "") }
        return ([desktop.title + (included ? "" : " (excluded)"), "\(desktop.windows.count) saved windows"] + names
            + (desktop.isSavedActive ? ["Active when saved"] : [])).joined(separator: ", ")
    }
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 4) {
                    Text(desktop.title).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 0)
                    if !included {
                        Image(systemName: "minus.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if desktop.isSavedActive {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                            .help("Active when this layout was saved")
                    }
                }.frame(height: 25, alignment: .topLeading)
                HStack(spacing: 5) {
                    if apps.isEmpty {
                        Image(systemName: desktop.kind == .fullscreen ? "arrow.up.left.and.arrow.down.right" : "rectangle.dashed")
                            .font(.system(size: 16)).foregroundStyle(.tertiary)
                        Text("Empty").font(.caption2).foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(apps.prefix(apps.count > 3 ? 2 : 3))) { app in
                            AppIcon(bundleID: app.identity.bundleID, size: 22)
                                .opacity(!included || appIsExcluded(app.identity.bundleID) ? 0.3 : 1)
                        }
                        if apps.count > 3 {
                            Text("+\(apps.count - 2)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.frame(height: 24)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.09), lineWidth: selected ? 1.5 : 0.5) }
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
            .accessibilityLabel(spokenSummary)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(spokenSummary)
    }
    private func appIsExcluded(_ bundleID: String) -> Bool {
        excludedBundleIDs.contains(bundleID) || desktop.windows.filter { $0.identity.bundleID == bundleID }.allSatisfy { window in
            exclusions.contains { $0.excludes(window.identity) }
        }
    }
}

private struct DesktopWindowList: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let windows: [SavedWindow]
    let desktopIncluded: Bool
    let matchWindow: (SavedWindow) -> Void
    let assignWindow: (SavedWindow) -> Void
    private var apps: [String] {
        Set(windows.map { $0.identity.bundleID }).sorted { first, second in
            let firstName = windows.first { $0.identity.bundleID == first }?.identity.appName ?? first
            let secondName = windows.first { $0.identity.bundleID == second }?.identity.appName ?? second
            let comparison = firstName.localizedStandardCompare(secondName)
            return comparison == .orderedSame ? first < second : comparison == .orderedAscending
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(apps, id: \.self) { bundleID in
                let members = windows.filter { $0.identity.bundleID == bundleID }
                let globallyExcluded = model.library.exclusions.contains { $0.bundleID == bundleID && $0.title == nil }
                let enabled = !layout.excludedBundleIDs.contains(bundleID) && !globallyExcluded
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { enabled }, set: {
                            model.setLayoutApplicationEnabled(layoutID: layout.id, bundleID: bundleID, enabled: $0)
                        })) { EmptyView() }
                            .labelsHidden().toggleStyle(.checkbox)
                            .accessibilityLabel("Include \(members.first?.identity.appName ?? bundleID) in this layout")
                            .help(globallyExcluded ? "Excluded in Settings. Use Window options to remove the exclusion." : !desktopIncluded ? "Include this desktop to change its app participation." : "Include this app on all its saved desktops in manual and Auto restoration")
                            .disabled(model.busy || globallyExcluded || !desktopIncluded)
                        AppIcon(bundleID: bundleID, size: 26).opacity(enabled && desktopIncluded ? 1 : 0.35)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(members.first?.identity.appName ?? bundleID).font(.callout.weight(.medium))
                            if globallyExcluded {
                                Text("Excluded in Settings").font(.caption).foregroundStyle(.secondary)
                            } else if members.count == 1, let window = members.first {
                                Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if model.library.exclusions.contains(where: { $0.excludes(window.identity) }) {
                                    Text("Window excluded in Settings").font(.caption2).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("\(members.count) windows").font(.caption).foregroundStyle(.secondary)
                            }
                        }.opacity(enabled && desktopIncluded ? 1 : 0.5)
                        Spacer(minLength: 0)
                        if members.count == 1, let window = members.first { windowMenu(window) }
                    }
                    if members.count > 1 {
                        ForEach(members) { window in
                            HStack(spacing: 8) {
                                Text(window.identity.title.isEmpty ? "Untitled window" : window.identity.title)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if model.library.exclusions.contains(where: { $0.excludes(window.identity) }) {
                                    Image(systemName: "minus.circle").foregroundStyle(.secondary).help("Window excluded in Settings")
                                }
                                Spacer(minLength: 0)
                                windowMenu(window)
                            }.padding(.leading, 49)
                        }
                    }
                }
                if bundleID != apps.last { Divider() }
            }
        }
    }
    private func windowMenu(_ window: SavedWindow) -> some View {
        Menu {
            Button("Matching preference…") { matchWindow(window) }
            Button("Assign window…") { assignWindow(window) }.disabled(!desktopIncluded)
            Divider()
            let exclusions = model.library.exclusions.filter { $0.excludes(window.identity) }
            let windowExclusions = exclusions.filter { $0.title != nil }
            let appExclusions = exclusions.filter { $0.title == nil }
            if windowExclusions.isEmpty {
                Button("Exclude this window from all layouts") { model.excludeWindow(window, wholeApplication: false) }
            } else {
                Button("Remove window exclusion") { windowExclusions.forEach { model.removeExclusion($0.id) } }
            }
            if appExclusions.isEmpty {
                Button("Exclude this app from all layouts") { model.excludeWindow(window, wholeApplication: true) }
            } else {
                Button("Remove app exclusion") { appExclusions.forEach { model.removeExclusion($0.id) } }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary).frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.busy)
        .accessibilityLabel("Window options for \(window.identity.appName), \(window.identity.title)")
        .help("Window options")
    }
}
