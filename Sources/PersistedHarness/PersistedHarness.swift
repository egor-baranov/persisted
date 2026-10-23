import AppKit

/// A real, separate application for controlled Accessibility integration checks.
/// It deliberately presents duplicate titles and an application-enforced minimum size.
@main
@MainActor
struct PersistedHarness {
    static func main() {
        let app = NSApplication.shared
        let delegate = HarnessDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class HarnessDelegate: NSObject, NSApplicationDelegate {
    private var windows: [NSWindow] = []
    private var delay: Task<Void, Never>?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Persisted Harness", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        makeWindow(title: "Duplicate document", identifier: "duplicate-a", origin: NSPoint(x: 100, y: 180), color: .systemBlue)
        makeWindow(title: "Duplicate document", identifier: "duplicate-b", origin: NSPoint(x: 620, y: 220), color: .systemOrange)
        makeWindow(title: "Minimum size 480 × 300", identifier: "minimum-size", origin: NSPoint(x: 300, y: 450), color: .systemGreen, minimum: NSSize(width: 480, height: 300))
        delay = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.makeWindow(title: "Delayed document", identifier: "delayed-window", origin: NSPoint(x: 760, y: 480), color: .systemPurple)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { delay?.cancel() }
    private func makeWindow(title: String, identifier: String, origin: NSPoint, color: NSColor, minimum: NSSize = NSSize(width: 260, height: 180)) {
        let window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 500, height: 320)), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.identifier = NSUserInterfaceItemIdentifier(identifier)
        window.setAccessibilityIdentifier(identifier)
        window.minSize = minimum
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        stack.alignment = .leading
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 22, weight: .semibold)
        heading.textColor = color
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(NSTextField(wrappingLabelWithString: "Integration fixture: \(identifier)\nArrange these windows, save a layout, move them, and apply or undo. The purple window appears after eight seconds."))
        let button = NSButton(title: "Change title", target: self, action: #selector(changeTitle(_:)))
        button.identifier = .init(identifier)
        stack.addArrangedSubview(button)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24)])
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
    }
    @objc private func changeTitle(_ sender: NSButton) { sender.window?.title = "Edited document \(Date().formatted(date: .omitted, time: .standard))" }
}
