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