import SwiftUI
import AppKit
import PersistedCore

@main
struct PersistedApp: App {
    @NSApplicationDelegateAdaptor(PersistedAppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        if let output = WebsiteScreenshotRenderer.outputDirectory {
            let model = WebsiteScreenshotRenderer.makeModel()
            _model = State(initialValue: model)
            PersistedAppDelegate.model = model
            PersistedAppDelegate.startupTask = Task { await WebsiteScreenshotRenderer.run(model: model, output: output) }
            return
        }
        let model = AppModel()
        _model = State(initialValue: model)
        PersistedAppDelegate.model = model
        PersistedAppDelegate.startupTask = Task { await model.startup() }
    }
    var body: some Scene {
        MenuBarExtra {
            MenuPopover(model: model)
        } label: {
            MenuBarIcon(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Manage layouts", id: "manage") {
            ManageLayoutsView(model: model)
                .task { await model.startup() }
        }
        .defaultSize(width: 960, height: 700)
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            PersistedSettingsView(model: model)
                .task { await model.startup() }
        }
        .defaultSize(width: 620, height: 640)
        .windowResizability(.contentMinSize)

        Window("Welcome to Persisted", id: "onboarding") {
            OnboardingView(model: model)
                .task { await model.startup() }
        }
        .defaultSize(width: 580, height: 600)
        .windowResizability(.contentSize)

        Window("Save current layout", id: "save") {
            SaveLayoutView(model: model)
        }
        .defaultSize(width: 660, height: 620)
        .windowResizability(.contentMinSize)
    }
}


@MainActor
private final class PersistedAppDelegate: NSObject, NSApplicationDelegate {
    static var model: AppModel?
    static var startupTask: Task<Void, Never>?
    private var terminationPending = false
    private var switcherPanel: LayoutSwitcherPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.model?.presentPanel = { [weak self] in self?.showSwitcher() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSwitcher()
        return false
    }

    private func showSwitcher() {
        guard let model = Self.model, !model.isIntegrationCheck else { return }
        if switcherPanel == nil {
            let panel = LayoutSwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 446, height: 690),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Persisted"
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.center()
            switcherPanel = panel
        }
        // Reopening or invoking the quick switcher always starts at the catalog,
        // even if the reusable panel was last left on Settings or Schedule.
        switcherPanel?.contentViewController = NSHostingController(rootView: PersistedMenuPanel(model: model))
        NSApplication.shared.activate(ignoringOtherApps: true)
        switcherPanel?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        guard let model = Self.model else { return .terminateNow }
        terminationPending = true
        Task {
            await Self.startupTask?.value
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private final class LayoutSwitcherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

private struct MenuBarIcon: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var didPresentOnboarding = false
    var body: some View {
        Image(systemName: "rectangle.3.group")
            .accessibilityLabel("Persisted window layouts")
            .task {
                await PersistedAppDelegate.startupTask?.value
                if model.isIntegrationCheck {
                    NSApplication.shared.terminate(nil)
                    return
                }
                if !model.isIntegrationCheck && !didPresentOnboarding && !model.library.settings.onboardingCompleted {
                    didPresentOnboarding = true
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "onboarding")
                }
            }
    }
}
