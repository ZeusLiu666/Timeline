import SwiftUI

struct TimelineWorkspaceView: View {
    let project: TimelineProject
    let entries: [TimelineEntry]
    let onNewEntry: () -> Void
    let onEditEntry: (TimelineEntry) -> Void
    let onDeleteEntry: (TimelineEntry) -> Void
    let onInsertReference: (TimelineEntry?, TimelineReference) -> Void
    let editor: AnyView?
    let editingEntryID: UUID?
    let editingSessionID: UUID?
    @StateObject private var interaction: ReferenceInteraction

    init(project: TimelineProject, entries: [TimelineEntry], store: TimelineStore,
         onNewEntry: @escaping () -> Void, onEditEntry: @escaping (TimelineEntry) -> Void,
         onDeleteEntry: @escaping (TimelineEntry) -> Void,
         onInsertReference: @escaping (TimelineEntry?, TimelineReference) -> Void,
         editor: AnyView? = nil, editingEntryID: UUID? = nil, editingSessionID: UUID? = nil) {
        self.project = project
        self.entries = entries
        self.onNewEntry = onNewEntry
        self.onEditEntry = onEditEntry
        self.onDeleteEntry = onDeleteEntry
        self.onInsertReference = onInsertReference
        self.editor = editor
        self.editingEntryID = editingEntryID
        self.editingSessionID = editingSessionID
        _interaction = StateObject(wrappedValue: ReferenceInteraction(project: project, store: store))
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < 640
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    TimelineFeedView(project: project, entries: entries, onNewEntry: onNewEntry,
                                     onEditEntry: onEditEntry, onDeleteEntry: onDeleteEntry,
                                     editor: editor, editingEntryID: editingEntryID, editingSessionID: editingSessionID)
                        .environmentObject(interaction)
                    if interaction.isShelfVisible && !narrow {
                        ReferenceShelfView(interaction: interaction)
                            .frame(width: 256)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                if interaction.isShelfVisible && narrow {
                    ReferenceShelfView(interaction: interaction)
                        .frame(width: min(218, geometry.size.width * 0.58))
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                ReferenceDragOverlay(interaction: interaction)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if !interaction.isShelfVisible && !interaction.references.isEmpty {
                    Button { interaction.isShelfVisible = true } label: {
                        Label("\(interaction.references.count)", systemImage: "quote.bubble")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain).accessibilityLabel("打开引用区，\(interaction.references.count) 条待用引用")
                    .padding(.trailing, narrow ? 126 : 114).padding(.bottom, narrow ? 23 : 24)
                }
            }
            .coordinateSpace(name: ReferenceInteraction.workspaceCoordinateSpace)
            .onPreferenceChange(ReferenceTargetFramesKey.self) { interaction.updateTargets($0) }
            .animation(.easeInOut(duration: 0.2), value: interaction.isShelfVisible)
            .onAppear {
                configureDrop()
                interaction.updateWorkspaceBounds(CGRect(origin: .zero, size: geometry.size))
            }
            .onChange(of: geometry.size) { _, size in interaction.updateWorkspaceBounds(CGRect(origin: .zero, size: size)) }
            .onChange(of: entries.map(\.id)) { _, _ in configureDrop() }
            .onChange(of: editor != nil) { _, isEditing in
                if isEditing && narrow { interaction.isShelfVisible = false }
                configureDrop()
            }
            .onChange(of: editingEntryID) { _, _ in configureDrop() }
        }
    }

    private func configureDrop() {
        interaction.onDrop = { target, reference in
            switch target {
            case .today:
                if editor != nil && editingEntryID == nil {
                    onInsertReference(nil, reference)
                    return
                }
                let today = entries.filter { Calendar.current.isDateInToday($0.date) }.max { $0.date < $1.date }
                onInsertReference(today, reference)
            case .entry(let id):
                if let entry = entries.first(where: { $0.id == id }) { onInsertReference(entry, reference) }
            }
        }
    }
}
