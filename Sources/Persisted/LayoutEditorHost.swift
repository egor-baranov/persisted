import SwiftUI
import PersistedCore

/// Each visible editor suspends automatic work independently. Closing the panel
/// releases its token; the draft's source revision still protects it on reopening.
struct LayoutEditorHost: View {
    let model: AppModel
    let layout: PersistedCore.Layout
    let done: () -> Void
    @State private var sessionID = UUID()

    var body: some View {
        LayoutEditorView(model: model, layout: layout, save: { draft in
            guard model.beginLayoutEditing(layoutID: layout.id, sessionID: sessionID),
                  model.saveLayoutEdits(draft) else { return false }
            done()
            return true
        }, cancel: done)
        .onAppear { _ = model.beginLayoutEditing(layoutID: layout.id, sessionID: sessionID) }
        .onDisappear { model.endLayoutEditing(sessionID: sessionID) }
    }
}

struct EditedLayoutNotice: View {
    var body: some View {
        Label("Saved edits are ready to apply. Automatic learning resumes after a successful full restore on this setup.", systemImage: "pencil.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
