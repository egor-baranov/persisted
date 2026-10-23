import AppKit
import SwiftUI
import PersistedCore

/// Reproducible website assets, rendered from the actual app views with sample data.
/// This mode never starts the production coordinator or reads the user's library.
@MainActor
enum WebsiteScreenshotRenderer {
    static var outputDirectory: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--website-screenshots") else { return nil }
        guard arguments.indices.contains(flag + 1), !arguments[flag + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("Usage: Persisted --website-screenshots <output-directory>\n".utf8))
            exit(EXIT_FAILURE)
        }
        return URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
    }

    static func makeModel() -> AppModel {
        let library = WebsiteFixtures.library
        var timing = CoordinatorTiming()
        timing.quietPeriod = .milliseconds(5)
        timing.observationInterval = .milliseconds(5)
        let coordinator = RestoreCoordinator(
            displays: WebsiteTopology(topology: library.layouts[0].topology),
            accessibility: WebsiteWindows(), permission: WebsitePermission(), launcher: WebsiteLauncher(),
            repository: WebsiteLibrary(library: library), timing: timing)
        return AppModel(websitePreview: coordinator)
    }

    static func run(model: AppModel, output: URL) async {
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            // Allow the AppKit application to finish launching before hosting views.
            try await Task.sleep(for: .milliseconds(200))
            await model.coordinator.start()
            await model.coordinator.waitForSettling()
            try LayoutRepository.validate(model.library)
            guard let layout = model.library.layouts.first else { throw WebsiteRenderError.noFixture }
            try await render(PersistedMenuPanel(model: model), size: .init(width: 446, height: 710),
                             to: output.appendingPathComponent("catalog.png"))
            try await render(PersistedMenuPanel(model: model, showingLayoutID: layout.id),
                             size: .init(width: 446, height: 710), to: output.appendingPathComponent("details.png"))
            try await render(LayoutWorkspaceView(model: model, layout: layout, matchWindow: { _ in }, assignWindow: { _ in })
                .padding(20), size: .init(width: 540, height: 580), to: output.appendingPathComponent("desktops.png"))
            try await render(LayoutEditorView(model: model, layout: layout, save: { _ in false }, cancel: {}),
                             size: .init(width: 540, height: 920), to: output.appendingPathComponent("editor.png"))
            let provenance = """
            These PNGs render Persisted's production SwiftUI views inside AppKit NSHostingViews at 2× resolution.
            The catalog and full details use PersistedMenuPanel. The desktop close-up uses its production
            LayoutWorkspaceView component. The editor uses LayoutEditorView.
            All layouts, window titles, display identities, and desktop assignments are synthetic fixtures.
            Application icons come from installed macOS applications through the production AppIcon view.
            No user layouts, Accessibility data, window captures, or private files were read.
            The renderer uses inert services and an in-memory library; it cannot place real windows.

            Regenerate from the repository root:
              swift run Persisted --website-screenshots "$PWD/site/assets/screenshots"

            Source: Sources/Persisted/WebsiteScreenshotRenderer.swift
            Appearance: native macOS light appearance, flat system backgrounds.
            """
            try provenance.write(to: output.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
            print("Rendered 4 native Persisted screenshots to \(output.path)")
            exit(EXIT_SUCCESS)
        } catch {
            FileHandle.standardError.write(Data("Website screenshots failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func render<V: View>(_ content: V, size: NSSize, to url: URL) async throws {
        let root = content
            .environment(\.colorScheme, .light)
            .environment(\.controlActiveState, .active)
            .environment(\.locale, Locale(identifier: "en_US"))
            .tint(.blue)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = WebsiteRenderWindow(contentRect: NSRect(x: -12000, y: -12000, width: size.width, height: size.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw WebsiteRenderError.bitmap }
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw WebsiteRenderError.bitmap }
        try data.write(to: url, options: .atomic)
        window.close()
    }
}

private enum WebsiteRenderError: Error { case noFixture, bitmap }

/// Draw native controls as active without activating the app or stealing focus.
private final class WebsiteRenderWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

@MainActor private final class WebsiteTopology: TopologyProviding {
    let topology: DisplayTopology
    init(topology: DisplayTopology) { self.topology = topology }
    func snapshot() -> DisplayTopology { topology }
}
@MainActor private final class WebsitePermission: PermissionChecking {
    var isTrusted: Bool { true }
}
@MainActor private final class WebsiteLauncher: ApplicationLaunching {
    func launch(bundleIDs: Set<String>) async -> [CaptureIssue] { [] }
}
private actor WebsiteLibrary: LibraryStoring {
    private var library: Library
    init(library: Library) { self.library = library }
    func load() async throws -> Library { library }
    func save(_ library: Library) async throws { self.library = library }
}
private struct WebsiteWindows: WindowAccessing {
    func capture(exclusions: [WindowExclusion]) async -> WindowCapture { .init() }
    func place(_ placement: PlannedPlacement, generation: UInt64, gate: MutationGate, automatic: Bool) async -> WindowOutcome {
        .init(id: placement.savedWindow.id, appName: placement.savedWindow.identity.appName,
              kind: .unsupported, explanation: "Website preview does not control real windows.")
    }
}

private enum WebsiteFixtures {
    static let savedDate = Date(timeIntervalSince1970: 1_787_137_200)
    static let studio = DisplayRecord(id: "demo-studio", name: "Studio Display", uuid: "demo-studio", isPrimary: true,
        frame: .init(x: 0, y: 0, width: 1728, height: 1117), usableFrame: .init(x: 0, y: 42, width: 1728, height: 1050), scale: 2)
    static let laptop = DisplayRecord(id: "demo-laptop", name: "MacBook Pro", uuid: "demo-laptop", isBuiltIn: true,
        frame: .init(x: 1728, y: 0, width: 1512, height: 982), usableFrame: .init(x: 1728, y: 42, width: 1512, height: 914), scale: 2)
    static let desk = DisplayTopology(displays: [studio, laptop], lid: .open)
    static var portable: DisplayTopology {
        var display = laptop
        display.isPrimary = true; display.frame.x = 0; display.usableFrame.x = 0
        return .init(displays: [display], lid: .open)
    }
    static let desktops = DesktopSnapshot(displays: [
        .init(displayID: studio.id, desktops: [
            .init(id: "studio-1", ordinal: 0, isActive: true),
            .init(id: "studio-2", ordinal: 1),
            .init(id: "studio-3", ordinal: 2)]),
        .init(displayID: laptop.id, desktops: [
            .init(id: "laptop-1", ordinal: 0, isActive: true),
            .init(id: "laptop-2", ordinal: 1)])
    ], separateDisplays: true)

    static var library: Library {
        var library = Library()
        library.settings.onboardingCompleted = true
        library.settings.automaticSwitching = false
        library.settings.autoModeEnabled = false
        let deskWindows = [
            window(app: "Safari", bundle: "com.apple.Safari", title: "Project overview", display: studio, topology: desk,
                   frame: .init(x: 24, y: 24, width: 1020, height: 1002), desktop: "studio-1"),
            window(app: "Notes", bundle: "com.apple.Notes", title: "Design notes", display: studio, topology: desk,
                   frame: .init(x: 1060, y: 24, width: 644, height: 1002), desktop: "studio-1"),
            window(app: "Terminal", bundle: "com.apple.Terminal", title: "Build session", display: studio, topology: desk,
                   frame: .init(x: 120, y: 85, width: 1350, height: 880), desktop: "studio-2"),
            window(app: "Calendar", bundle: "com.apple.iCal", title: "Week ahead", display: laptop, topology: desk,
                   frame: .init(x: 25, y: 25, width: 1462, height: 864), desktop: "laptop-1"),
            window(app: "Music", bundle: "com.apple.Music", title: "Focus mix", display: laptop, topology: desk,
                   frame: .init(x: 90, y: 65, width: 1300, height: 780), desktop: "laptop-2")
        ]
        var workspace = Layout(name: "At my desk", topology: desk, windows: deskWindows,
                               iconName: "display.2", desktopSnapshot: desktops)
        workspace.saved.date = savedDate
        library.layouts.append(workspace)
        var writing = Layout(name: "Writing", topology: desk, windows: Array(deskWindows.prefix(2)), iconName: "doc.text",
                             desktopSnapshot: desktops)
        writing.saved.windows[0] = window(app: "Safari", bundle: "com.apple.Safari", title: "Reference reading", display: studio,
            topology: desk, frame: .init(x: 35, y: 35, width: 700, height: 980), desktop: "studio-1")
        writing.saved.windows[1] = window(app: "Notes", bundle: "com.apple.Notes", title: "First draft", display: studio,
            topology: desk, frame: .init(x: 755, y: 35, width: 938, height: 980), desktop: "studio-1")
        writing.saved.date = savedDate
        library.layouts.append(writing)
        var focus = Layout(name: "Deep work", topology: desk, windows: [deskWindows[2], deskWindows[4]],
                           iconName: "moon", desktopSnapshot: desktops)
        focus.saved.date = savedDate
        library.layouts.append(focus)
        var planning = Layout(name: "Planning", topology: desk, windows: [deskWindows[0], deskWindows[1], deskWindows[3]],
                              iconName: "calendar", desktopSnapshot: desktops)
        planning.saved.date = savedDate
        library.layouts.append(planning)
        let portableDesktops = DesktopSnapshot(displays: [
            .init(displayID: laptop.id, desktops: [.init(id: "portable-1", ordinal: 0, isActive: true), .init(id: "portable-2", ordinal: 1)])
        ], separateDisplays: true)
        let portableWindows = [
            window(app: "Safari", bundle: "com.apple.Safari", title: "Reading list", display: portable.displays[0], topology: portable,
                   frame: .init(x: 20, y: 20, width: 900, height: 874), desktop: "portable-1"),
            window(app: "Notes", bundle: "com.apple.Notes", title: "Travel notes", display: portable.displays[0], topology: portable,
                   frame: .init(x: 940, y: 20, width: 552, height: 874), desktop: "portable-1")
        ]
        var portableLayout = Layout(name: "Laptop only", topology: portable, windows: portableWindows,
                                    iconName: "laptopcomputer", desktopSnapshot: portableDesktops)
        portableLayout.saved.date = savedDate
        library.layouts.append(portableLayout)
        return library
    }

    private static func window(app: String, bundle: String, title: String, display: DisplayRecord,
                               topology: DisplayTopology, frame: Rect, desktop: String) -> SavedWindow {
        let usable = CoordinateMapper.usableAX(display, in: topology)
        return SavedWindow(identity: .init(bundleID: bundle, appName: app, title: title), displayID: display.id,
            frame: .init(x: usable.x + frame.x, y: usable.y + frame.y, width: frame.width, height: frame.height),
            sourceUsableFrame: usable, relativeFrame: frame,
            normalizedFrame: .init(x: frame.x / usable.width, y: frame.y / usable.height,
                                   width: frame.width / usable.width, height: frame.height / usable.height),
            desktopAssignment: .desktop(desktop))
    }
}
