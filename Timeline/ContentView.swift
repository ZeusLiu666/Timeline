import SwiftUI
import SwiftData

struct ContentView: View {
    @EnvironmentObject private var store: TimelineStore
    @Query(sort: [SortDescriptor(\TimelineProject.sortOrder), SortDescriptor(\TimelineProject.createdAt)]) private var allProjects: [TimelineProject]
    @Query(sort: [SortDescriptor(\TimelineEntry.date, order: .reverse), SortDescriptor(\TimelineEntry.createdAt, order: .reverse)]) private var allEntries: [TimelineEntry]
    @AppStorage("timeline.selectedProject") private var selectedProjectID = ""
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projectEditor: ProjectEditorItem?
    @State private var entryEditor: EntryEditorItem?
    @State private var entryDrafts: [String: EntryDraft] = [:]
    @State private var deletingProject: TimelineProject?
    @State private var deletingEntry: TimelineEntry?
    @State private var showSyncInfo = false
    @State private var showTrash = false
    @State private var syncEditingOwner = UUID()

    private var projects: [TimelineProject] { allProjects.filter { !$0.isTrashed } }
    private var entries: [TimelineEntry] { allEntries.filter { !$0.isTrashed } }
    private var activeWorkspaceIDs: [String] {
        projects.map { $0.id.uuidString } + entries.map { $0.id.uuidString }
    }

    private var selectedProject: TimelineProject? {
        projects.first { $0.id.uuidString == selectedProjectID } ?? projects.first
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 254, max: 320)
        } detail: {
            Group {
                if let project = selectedProject {
                    workspace(for: project)
                    .id(project.id)
                } else {
                    ContentUnavailableView {
                        Label("为想法留下一条时间线", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    } description: {
                        Text("创建第一个项目，记录进展、问题和每一个新想法。")
                    } actions: {
                        Button("创建项目") { beginProjectEditing() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .background(TimelineTheme.background)
        }
        .navigationSplitViewStyle(.balanced)
        .background(TimelineTheme.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let message = store.lastSaveError ?? store.persistenceNotice {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(TimelineTheme.background)
            }
        }
        .sheet(item: $projectEditor) { item in
            ProjectEditorView(project: item.project) { name, icon, color in
                if let project = item.project {
                    guard !project.isTrashed else { return }
                    project.name = name
                    project.icon = icon
                    project.colorHex = color
                    store.save()
                } else {
                    let project = store.addProject(name: name, icon: icon, colorHex: color)
                    selectedProjectID = project.id.uuidString
                }
            }
        }
        .confirmationDialog("将项目移到回收站？", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } }), titleVisibility: .visible) {
            Button("移到回收站", role: .destructive) {
                if let project = deletingProject {
                    if store.deleteProject(project) {
                        discardDeletedDrafts()
                        if selectedProjectID == project.id.uuidString { selectedProjectID = "" }
                    }
                }
                deletingProject = nil
            }
        } message: { Text("项目及其全部记录将移到回收站，30 天内可以恢复，之后自动清除。") }
        .confirmationDialog("将这条记录移到回收站？", isPresented: Binding(get: { deletingEntry != nil }, set: { if !$0 { deletingEntry = nil } }), titleVisibility: .visible) {
            Button("移到回收站", role: .destructive) {
                if let entry = deletingEntry, store.deleteEntry(entry) { discardDeletedDrafts() }
                deletingEntry = nil
            }
        } message: { Text("记录将在回收站中保留 30 天，期间可以恢复，之后自动清除。") }
        .sheet(isPresented: $showSyncInfo) { NutstoreSyncSettingsView().environmentObject(store) }
        .sheet(isPresented: $showTrash) { TimelineTrashView().environmentObject(store) }
        .onReceive(NotificationCenter.default.publisher(for: .timelineNewEntry)) { _ in
            if let project = selectedProject { beginEditing(project: project) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .timelineNewProject)) { _ in beginProjectEditing() }
        .onReceive(NotificationCenter.default.publisher(for: .timelineEditEntry)) { notification in
            guard let id = notification.object as? UUID,
                  let entry = entries.first(where: { $0.id == id }),
                  let project = entry.project else { return }
            selectedProjectID = project.id.uuidString
            beginEditing(project: project, entry: entry)
        }
        .onChange(of: entryEditor?.id) { _, _ in updateSyncEditing() }
        .onChange(of: projectEditor?.id) { _, _ in updateSyncEditing() }
        .onChange(of: entryDrafts.isEmpty) { _, _ in updateSyncEditing() }
        .onChange(of: activeWorkspaceIDs) { _, _ in discardDeletedDrafts() }
        .onAppear { updateSyncEditing() }
        .onDisappear { store.setNutstoreEditing(false, owner: syncEditingOwner) }
    }

    @MainActor
    private func saveEntry(_ draft: EntryDraft, using item: EntryEditorItem) -> Bool {
        TimelineEntrySaveOperation.save(draft, project: item.project, existingEntry: item.entry,
                                        additionalReferences: item.additionalReferences,
                                        context: store.modelContext, persist: { store.touch($0) })
    }

    @ViewBuilder
    private func workspace(for project: TimelineProject) -> some View {
        if project.isTrashed {
            ContentUnavailableView("项目已移到回收站", systemImage: "trash",
                                   description: Text("可以在回收站中恢复这个项目。"))
        } else {
            TimelineWorkspaceView(
                project: project, entries: entries.filter { $0.project?.id == project.id }, store: store,
                onNewEntry: { beginEditing(project: project) },
                onEditEntry: { beginEditing(project: project, entry: $0) },
                onDeleteEntry: { deletingEntry = $0 },
                onInsertReference: { entry, reference in
                    beginEditing(project: project, entry: entry, references: [reference])
                },
                editor: inlineEditor(for: project),
                editingEntryID: entryEditor?.project.id == project.id ? entryEditor?.entry?.id : nil,
                editingSessionID: entryEditor?.project.id == project.id ? entryEditor?.id : nil
            )
        }
    }

    private func inlineEditor(for project: TimelineProject) -> AnyView? {
        guard let item = entryEditor, item.project.id == project.id else { return nil }
        let key = draftKey(project: project, entry: item.entry)
        return AnyView(EntryEditorView(project: project, entry: item.entry, additionalReferences: item.additionalReferences,
                                       initialDraft: entryDrafts[key], onDraftChange: { draft in
            if entryEditor?.id == item.id { entryDrafts[key] = draft }
        }, inline: true, onCancel: {
            entryDrafts.removeValue(forKey: key)
            entryEditor = nil
        }) { draft in
            let saved = saveEntry(draft, using: item)
            if saved { entryDrafts.removeValue(forKey: key) }
            return saved
        }.id(item.id))
    }

    private func draftKey(project: TimelineProject, entry: TimelineEntry?) -> String {
        project.id.uuidString + ":" + (entry?.id.uuidString ?? "new")
    }

    private func beginEditing(project: TimelineProject, entry: TimelineEntry? = nil, references: [TimelineReference] = []) {
        guard !project.isTrashed, !(entry?.isTrashed ?? false) else { return }
        store.setNutstoreEditing(true, owner: syncEditingOwner)
        let key = draftKey(project: project, entry: entry)
        if var draft = entryDrafts[key] {
            let known = Set(draft.references.map(\.id))
            draft.references.append(contentsOf: references.filter { !known.contains($0.id) })
            entryDrafts[key] = draft
        }
        let previous = entryEditor?.project.id == project.id && entryEditor?.entry?.id == entry?.id
            ? entryEditor?.additionalReferences ?? [] : []
        let known = Set(previous.map(\.id))
        entryEditor = EntryEditorItem(project: project, entry: entry,
                                      additionalReferences: previous + references.filter { !known.contains($0.id) })
    }

    private func beginProjectEditing(_ project: TimelineProject? = nil) {
        guard !(project?.isTrashed ?? false) else { return }
        store.setNutstoreEditing(true, owner: syncEditingOwner)
        projectEditor = ProjectEditorItem(project: project)
    }

    private func updateSyncEditing() {
        store.setNutstoreEditing(entryEditor != nil || projectEditor != nil || !entryDrafts.isEmpty, owner: syncEditingOwner)
    }

    private func discardDeletedDrafts() {
        let projectIDs = Set(projects.map { $0.id.uuidString })
        let entryIDs = Set(entries.map { $0.id.uuidString })
        entryDrafts = entryDrafts.filter { key, _ in
            let components = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard components.count == 2, projectIDs.contains(components[0]) else { return false }
            return components[1] == "new" || entryIDs.contains(components[1])
        }
        if let item = entryEditor,
           item.project.isTrashed || (item.entry?.isTrashed ?? false) || !projectIDs.contains(item.project.id.uuidString) {
            entryEditor = nil
        }
        if let project = projectEditor?.project, project.isTrashed || !projectIDs.contains(project.id.uuidString) {
            projectEditor = nil
        }
        updateSyncEditing()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("项目").font(.system(size: 14, weight: .medium)).foregroundStyle(TimelineTheme.muted)
                Spacer()
                Button { beginProjectEditing() } label: {
                    Image(systemName: "plus").font(.system(size: 14, weight: .medium)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("新建项目").accessibilityLabel("新建项目")
            }.padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(projects) { project in
                        #if os(macOS)
                        Button { selectedProjectID = project.id.uuidString } label: { projectRow(project) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑项目", systemImage: "pencil") { beginProjectEditing(project) }
                            Button("删除项目", systemImage: "trash", role: .destructive) { deletingProject = project }
                        }
                        #else
                        NavigationLink {
                            workspace(for: project)
                        } label: {
                            projectRow(project)
                        }
                        .simultaneousGesture(TapGesture().onEnded { selectedProjectID = project.id.uuidString })
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("编辑项目", systemImage: "pencil") { beginProjectEditing(project) }
                            Button("删除项目", systemImage: "trash", role: .destructive) { deletingProject = project }
                        }
                        #endif
                    }
                }.padding(.horizontal, 12)
            }

            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 12) {
                Divider().overlay(TimelineTheme.line)
                Button { showTrash = true } label: {
                    Label("回收站", systemImage: "trash")
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(TimelineTheme.muted)
                .accessibilityIdentifier("openTrash")
                HStack(spacing: 8) {
                    Button(action: requestSync) {
                        HStack(spacing: 8) {
                            if store.nutstoreState.isSyncing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.nutstoreState.title).font(.system(size: 11)).lineLimit(1)
                                if let lastSync = store.nutstoreState.lastSync {
                                    Text("上次同步：\(lastSync.formatted(date: .numeric, time: .shortened))")
                                        .font(.system(size: 10)).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.nutstoreState.isSyncing || store.isRecoveryMode || store.isCloudEnabled)
                    .help(store.nutstoreState.detail)
                    .accessibilityLabel("同步状态")
                    .accessibilityHint(store.nutstoreConfigured ? "点击立即同步" : "设置坚果云同步")
                    .accessibilityIdentifier("mainSyncStatus")

                    Button { showSyncInfo = true } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 12))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("同步设置")
                    .accessibilityLabel("同步设置")
                    .accessibilityIdentifier("mainSyncSettings")
                }
                .foregroundStyle(TimelineTheme.muted)
            }.padding(.horizontal, 24).padding(.bottom, 22)
        }
        .background(TimelineTheme.sidebar)
        .navigationTitle("")
    }

    private func requestSync() {
        guard !store.nutstoreState.isSyncing, !store.isRecoveryMode, !store.isCloudEnabled else { return }
        guard store.nutstoreConfigured else {
            showSyncInfo = true
            return
        }
        Task { await store.syncNutstore() }
    }

    private func projectRow(_ project: TimelineProject) -> some View {
        let selected = selectedProject?.id == project.id
        return HStack(spacing: 11) {
            Image(systemName: project.icon).font(.system(size: 16)).foregroundStyle(Color(timelineHex: project.colorHex)).frame(width: 19)
            Text(project.name).font(.system(size: 16, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(entries.filter { $0.project?.id == project.id }.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(TimelineTheme.muted)
        }
        .foregroundStyle(TimelineTheme.ink)
        .padding(.horizontal, 13).padding(.vertical, 10)
        .background(selected ? Color.white.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
    }
}

private struct ProjectEditorItem: Identifiable {
    let id = UUID()
    var project: TimelineProject? = nil
}

private struct EntryEditorItem: Identifiable {
    let id = UUID()
    let project: TimelineProject
    var entry: TimelineEntry? = nil
    var additionalReferences: [TimelineReference] = []
}

private struct TimelineTrashView: View {
    @EnvironmentObject private var store: TimelineStore
    @Environment(\.dismiss) private var dismiss
    @Query private var projects: [TimelineProject]
    @Query private var entries: [TimelineEntry]

    private var deletedProjects: [TimelineProject] {
        projects.filter { $0.deletedAt != nil }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    private var deletedEntries: [TimelineEntry] {
        // A deleted project is restored as a unit. Records deleted separately
        // become visible here again once their parent project is restored.
        entries.filter { $0.deletedAt != nil && !($0.project?.isTrashed ?? false) }
            .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text("删除的项目和记录会保留 30 天，之后自动清除。")
                    .font(.system(size: 12))
                    .foregroundStyle(TimelineTheme.muted)
                    .padding(.horizontal, 22).padding(.vertical, 16)
                Divider().overlay(TimelineTheme.line)
                if deletedProjects.isEmpty && deletedEntries.isEmpty {
                    ContentUnavailableView("回收站为空", systemImage: "trash",
                                           description: Text("删除的项目和记录会暂存在这里。"))
                } else {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                if !deletedProjects.isEmpty {
                                    trashSectionTitle("项目")
                                    ForEach(deletedProjects) { project in
                                        projectRow(project, now: context.date)
                                    }
                                }
                                if !deletedEntries.isEmpty {
                                    trashSectionTitle("记录")
                                        .padding(.top, deletedProjects.isEmpty ? 0 : 4)
                                    ForEach(deletedEntries) { entry in
                                        entryRow(entry, now: context.date)
                                    }
                                }
                            }
                            .padding(22)
                        }
                    }
                }
                if let error = store.lastSaveError {
                    Text(error)
                        .font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 22).padding(.bottom, 16)
                }
            }
            .background(TimelineTheme.background)
            .navigationTitle("回收站")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, idealWidth: 600, minHeight: 380, idealHeight: 540)
        #endif
        .onAppear { store.purgeExpiredTrash() }
        .accessibilityIdentifier("timelineTrash")
    }

    private func trashSectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TimelineTheme.muted)
    }

    private func projectRow(_ project: TimelineProject, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: project.icon)
                .font(.system(size: 17))
                .foregroundStyle(Color(timelineHex: project.colorHex))
                .frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(project.name).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TimelineTheme.ink)
                Text("\((project.entries ?? []).count) 条记录")
                    .font(.system(size: 12)).foregroundStyle(TimelineTheme.muted)
                retentionText(deletedAt: project.deletedAt, now: now)
            }
            Spacer(minLength: 8)
            Button("恢复") { store.restoreProject(project) }
                .buttonStyle(.bordered)
                .disabled(store.isRecoveryMode)
                .accessibilityLabel("恢复项目：\(project.name)")
                .accessibilityIdentifier("restoreProject-\(project.id.uuidString)")
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Divider().overlay(TimelineTheme.line) }
    }

    private func entryRow(_ entry: TimelineEntry, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 17))
                .foregroundStyle(TimelineTheme.muted)
                .frame(width: 22).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TimelineTheme.ink)
                Text("原项目：\(entry.project?.name ?? "未分类") · \(entry.date.formatted(date: .numeric, time: .omitted))")
                    .font(.system(size: 12)).foregroundStyle(TimelineTheme.muted)
                retentionText(deletedAt: entry.deletedAt, now: now)
            }
            Spacer(minLength: 8)
            Button("恢复") { store.restoreEntry(entry) }
                .buttonStyle(.bordered)
                .disabled(store.isRecoveryMode)
                .accessibilityLabel("恢复记录：\(entry.title)")
                .accessibilityIdentifier("restoreEntry-\(entry.id.uuidString)")
        }
        .padding(.bottom, 16)
        .overlay(alignment: .bottom) { Divider().overlay(TimelineTheme.line) }
    }

    @ViewBuilder
    private func retentionText(deletedAt: Date?, now: Date) -> some View {
        if let deletedAt {
            let remaining = max(0, Int(ceil(deletedAt.addingTimeInterval(TimelineTrashSupport.retentionInterval).timeIntervalSince(now) / (24 * 60 * 60))))
            Text("删除于 \(deletedAt.formatted(date: .numeric, time: .shortened)) · \(remaining > 0 ? "剩余 \(remaining) 天" : "即将自动清除")")
                .font(.system(size: 11)).foregroundStyle(TimelineTheme.muted)
        }
    }
}

@MainActor
enum TimelineEntrySaveOperation {
    static func save(_ draft: EntryDraft, project: TimelineProject, existingEntry: TimelineEntry?,
                     additionalReferences: [TimelineReference], context: ModelContext,
                     persist: (TimelineEntry) -> Bool) -> Bool {
        guard !project.isTrashed, !(existingEntry?.isTrashed ?? false) else { return false }
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }

        let originalEntry = existingEntry.map(TimelineEntryEditSnapshot.init)
        let originalPendingJSON = project.pendingReferencesJSON
        let originalProjectEntries = project.entries
        let isNew = existingEntry == nil
        let entry = existingEntry ?? TimelineEntry(title: draft.title, date: draft.date)
        entry.title = draft.title
        entry.date = draft.date
        entry.progress = draft.progress
        entry.progressPercent = draft.progressPercent
        entry.progressText = draft.progressText
        entry.issuesText = draft.issuesText
        entry.ideasText = draft.ideasText
        entry.showProgress = draft.showProgress
        entry.showIssues = draft.showIssues
        entry.showIdeas = draft.showIdeas
        entry.references = draft.references
        if isNew {
            // Insert the complete record once; no empty preliminary record is saved.
            context.insert(entry)
            entry.project = project
        }
        let insertedIDs = Set(additionalReferences.map(\.id)).intersection(draft.references.map(\.id))
        if !insertedIDs.isEmpty {
            project.pendingReferences.removeAll { insertedIDs.contains($0.id) }
        }
        guard persist(entry) else {
            // Restore only this operation. A context-wide rollback could discard
            // unrelated changes made elsewhere in the workspace.
            project.pendingReferencesJSON = originalPendingJSON
            if isNew {
                entry.project = nil
                context.delete(entry)
                context.processPendingChanges()
                project.entries = originalProjectEntries
            } else {
                originalEntry?.restore(entry)
            }
            return false
        }
        return true
    }
}

private struct TimelineEntryEditSnapshot {
    let title: String
    let date: Date
    let progress: String
    let progressPercent: Int
    let progressText: String
    let issuesText: String
    let ideasText: String
    let showProgress: Bool
    let showIssues: Bool
    let showIdeas: Bool
    let referencesJSON: String
    let updatedAt: Date

    init(_ entry: TimelineEntry) {
        title = entry.title
        date = entry.date
        progress = entry.progress
        progressPercent = entry.progressPercent
        progressText = entry.progressText
        issuesText = entry.issuesText
        ideasText = entry.ideasText
        showProgress = entry.showProgress
        showIssues = entry.showIssues
        showIdeas = entry.showIdeas
        referencesJSON = entry.referencesJSON
        updatedAt = entry.updatedAt
    }

    func restore(_ entry: TimelineEntry) {
        entry.title = title
        entry.date = date
        entry.progress = progress
        entry.progressPercent = progressPercent
        entry.progressText = progressText
        entry.issuesText = issuesText
        entry.ideasText = ideasText
        entry.showProgress = showProgress
        entry.showIssues = showIssues
        entry.showIdeas = showIdeas
        entry.referencesJSON = referencesJSON
        entry.updatedAt = updatedAt
    }
}

private struct ProjectEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let project: TimelineProject?
    let onSave: (String, String, String) -> Void
    @State private var name: String
    @State private var icon: String
    @State private var color: String
    private let icons = ["folder", "sparkles", "app.badge", "flask", "book.closed", "paintbrush", "leaf", "terminal"]
    private let colors = ["C75740", "63866B", "64849D", "A47E43", "9275A8", "59616C"]

    init(project: TimelineProject?, onSave: @escaping (String, String, String) -> Void) {
        self.project = project
        self.onSave = onSave
        _name = State(initialValue: project?.name ?? "")
        _icon = State(initialValue: project?.icon ?? "folder")
        _color = State(initialValue: project?.colorHex ?? "C75740")
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("项目名称", text: $name).accessibilityIdentifier("projectName")
                Section("图标") {
                    HStack {
                        ForEach(icons, id: \.self) { symbol in
                            Button { icon = symbol } label: {
                                Image(systemName: symbol).frame(width: 25, height: 30)
                                    .foregroundStyle(icon == symbol ? Color(timelineHex: color) : .secondary)
                                    .background(icon == symbol ? Color(timelineHex: color).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).accessibilityLabel(symbol)
                        }
                    }
                }
                Section("颜色") {
                    HStack(spacing: 17) {
                        ForEach(colors, id: \.self) { value in
                            Button { color = value } label: {
                                Circle().fill(Color(timelineHex: value)).frame(width: 25, height: 25)
                                    .overlay { if color == value { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white) } }
                            }.buttonStyle(.plain).accessibilityLabel(value)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(project == nil ? "新建项目" : "编辑项目")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), icon, color)
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 470, height: 360)
        #endif
    }
}

