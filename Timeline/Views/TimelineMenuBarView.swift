#if os(macOS)
import AppKit
import SwiftData
import SwiftUI
import WebKit

/// A separate, read-only browser over the same saved data as the main window.
/// Entries stay read-only; sync can refresh saved content from other devices.
struct TimelineMenuBarView: View {
    @EnvironmentObject private var store: TimelineStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var projectSelection
    @Binding var hideDockIcon: Bool
    let onEditEntry: (TimelineEntry) -> Void
    let onQuit: () -> Void

    @Query(sort: [SortDescriptor(\TimelineProject.sortOrder), SortDescriptor(\TimelineProject.createdAt)])
    private var allProjects: [TimelineProject]
    @Query(sort: [SortDescriptor(\TimelineEntry.date, order: .reverse), SortDescriptor(\TimelineEntry.createdAt, order: .reverse)])
    private var allEntries: [TimelineEntry]
    @AppStorage("timeline.menuBar.selectedProject") private var selectedProjectID = ""
    @State private var pageWidth: CGFloat = 396
    @State private var pageOffset: CGFloat?
    @State private var dragStartOffset: CGFloat?
    @State private var offsetPresentation = TimelineMenuBarOffsetPresentation()
    @State private var protectedScrollRegions: [CGRect] = []

    private var projects: [TimelineProject] { allProjects.filter { !$0.isTrashed } }
    private var entries: [TimelineEntry] { allEntries.filter { !$0.isTrashed } }

    private var selectedProject: TimelineProject? {
        projects.first { $0.id.uuidString == selectedProjectID } ?? projects.first
    }

    private var selectedPageIndex: Int {
        projects.firstIndex { $0.id == selectedProject?.id } ?? 0
    }

    private var syncTitle: String {
        if store.isRecoveryMode { return "资料库需要检查" }
        if store.isCloudEnabled { return store.syncState.title }
        return store.nutstoreConfigured ? store.nutstoreState.title : "本地存储"
    }

    private var syncDetail: String {
        store.isCloudEnabled ? store.syncState.detail : store.nutstoreState.detail
    }

    private var canSync: Bool {
        store.nutstoreConfigured && !store.isCloudEnabled && !store.isRecoveryMode
            && !store.nutstoreState.isSyncing
    }

    var body: some View {
        VStack(spacing: 10) {
            projectHeader
            projectPager
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            footer
        }
        .padding(12)
        .frame(width: 420, height: 580)
        .background(Color(white: 0.955))
        .preferredColorScheme(.light)
        .onChange(of: projects.map(\.id)) { _, ids in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragStartOffset = nil
                if !ids.contains(where: { $0.uuidString == selectedProjectID }) {
                    selectedProjectID = ids.first?.uuidString ?? ""
                }
                pageOffset = -CGFloat(selectedPageIndex) * pageWidth
            }
        }
        .accessibilityIdentifier("timelineMenuBarPopover")
    }

    private var projectPager: some View {
        GeometryReader { geometry in
            Group {
                if store.isRecoveryMode {
                    emptyState(symbol: "externaldrive.badge.exclamationmark", title: "暂时无法读取记录",
                               detail: "原有数据已保留，请打开主窗口查看详情。")
                } else if projects.isEmpty {
                    emptyState(symbol: "square.stack", title: "还没有项目",
                               detail: "在主窗口创建项目后，就能在这里快速浏览。")
                } else {
                    // Only this complete strip moves. Stable project identities
                    // preserve each page's expanded entry and vertical position.
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(projects, id: \.id) { project in
                            projectPage(project)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                                .accessibilityHidden(project.id != selectedProject?.id)
                        }
                    }
                    .frame(width: geometry.size.width * CGFloat(projects.count),
                           height: geometry.size.height, alignment: .leading)
                    .modifier(TimelineMenuBarPagingOffset(
                        x: pageOffset ?? -CGFloat(selectedPageIndex) * geometry.size.width,
                        presentation: offsetPresentation
                    ))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .onChange(of: geometry.size.width, initial: true) { _, width in
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    pageWidth = max(1, width)
                    pageOffset = -CGFloat(selectedPageIndex) * pageWidth
                    dragStartOffset = nil
                }
            }
        }
        .coordinateSpace(name: TimelineMenuBarPagingSpace.name)
        .onPreferenceChange(TimelineMenuBarProtectedScrollRegions.self) { protectedScrollRegions = $0 }
        // This bridge stays mounted throughout a gesture and every page snap.
        .background {
            TimelineMenuBarPagingRegion(enabled: projects.count > 1 && !store.isRecoveryMode,
                                        protectedRegions: protectedScrollRegions,
                                        onChange: updatePageDrag,
                                        onEnd: finishPageDrag)
        }
    }

    @ViewBuilder
    private func projectPage(_ project: TimelineProject) -> some View {
        let savedEntries = entries.filter { $0.project?.id == project.id }
        if savedEntries.isEmpty {
            emptyState(symbol: "text.alignleft", title: "这个项目还没有记录",
                       detail: "在主窗口写下第一条进展。")
        } else {
            TimelineMenuBarProjectTimeline(entries: savedEntries, onEditEntry: onEditEntry)
        }
    }

    private var pageSnapAnimation: Animation? {
        reduceMotion ? nil : .interpolatingSpring(stiffness: 320, damping: 36)
    }

    private var projectHeader: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("项目").font(.system(size: 12, weight: .semibold))
                Spacer()
                TimelineWordmark().frame(width: 62, height: 23)
                    .foregroundStyle(Color(white: 0.60))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 3)
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(projects) { project in
                            projectTab(project).id(project.id)
                        }
                        if projects.isEmpty {
                            Text("项目会显示在这里")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .padding(.horizontal, 11).padding(.vertical, 9)
                        }
                    }
                    .padding(4)
                }
                .scrollIndicators(.hidden)
                .background(Color(white: 0.91), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .onChange(of: selectedProject?.id, initial: true) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
            .accessibilityIdentifier("menuBarProjectTabs")
        }
    }

    private func projectTab(_ project: TimelineProject) -> some View {
        let selected = selectedProject?.id == project.id
        return Button { selectProject(project) } label: {
            HStack(spacing: 6) {
                Image(systemName: project.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(timelineHex: project.colorHex))
                Text(project.name)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1).frame(maxWidth: 120)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background {
                if selected {
                    if reduceMotion {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white)
                    } else {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white)
                            .matchedGeometryEffect(id: "selectedProject", in: projectSelection)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color(white: 0.15) : Color(white: 0.43))
        .help(project.name)
        .accessibilityLabel(project.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("menuBarProject-\(project.id.uuidString)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await store.syncNutstore() }
            } label: {
                HStack(spacing: 6) {
                    if store.nutstoreState.isSyncing && !store.isCloudEnabled {
                        ProgressView().controlSize(.mini).scaleEffect(0.8)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: store.isRecoveryMode ? "exclamationmark.circle" :
                              (store.nutstoreConfigured || store.isCloudEnabled ? "arrow.triangle.2.circlepath" : "internaldrive"))
                            .font(.system(size: 10))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(syncTitle).lineLimit(1)
                        if !store.isCloudEnabled, let lastSync = store.nutstoreState.lastSync {
                            Text("上次同步：\(lastSync.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 9))
                                .foregroundStyle(Color(white: 0.58))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSync)
            .font(.system(size: 10))
            .foregroundStyle(Color(white: 0.46))
            .help(canSync ? "点击立即同步。\(syncDetail)" : syncDetail)
            .accessibilityHint(canSync ? "点击立即同步" : syncDetail)
            .accessibilityIdentifier("menuBarSyncNow")
            Spacer(minLength: 5)
            Menu {
                Toggle("隐藏 Dock 图标", isOn: $hideDockIcon)
                Divider()
                Button("退出 Timeline", action: onQuit)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .frame(width: 30, height: 30)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Color(white: 0.29))
            .help("设置")
            .accessibilityLabel("菜单栏设置")
            .accessibilityIdentifier("menuBarSettings")
        }
        .padding(.leading, 3)
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 11) {
            Image(systemName: symbol).font(.system(size: 27, weight: .light))
                .foregroundStyle(Color(white: 0.65))
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(3)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectProject(_ project: TimelineProject) {
        guard let target = projects.firstIndex(where: { $0.id == project.id }) else { return }
        dragStartOffset = nil
        withAnimation(pageSnapAnimation) {
            pageOffset = -CGFloat(target) * pageWidth
            selectedProjectID = project.id.uuidString
        }
    }

    private func updatePageDrag(_ translation: CGFloat) {
        // Position has one owner. Selection changes never add another page-width
        // translation while the current drag is settling.
        let start = dragStartOffset ?? offsetPresentation.currentOffset ?? pageOffset ?? -CGFloat(selectedPageIndex) * pageWidth
        let upper: CGFloat = 0
        let lower = -CGFloat(max(0, projects.count - 1)) * pageWidth
        let displayedStart = start
        // Undo the edge resistance before applying it again, so interrupting an
        // edge rebound does not compress its existing visible displacement twice.
        let inputStart: CGFloat
        if displayedStart > upper {
            inputStart = upper + (displayedStart - upper) / 0.20
        } else if displayedStart < lower {
            inputStart = lower + (displayedStart - lower) / 0.20
        } else {
            inputStart = displayedStart
        }
        let relativeTranslation = inputStart + translation
        let offset: CGFloat
        if relativeTranslation > upper {
            offset = upper + min(54, (relativeTranslation - upper) * 0.20)
        } else if relativeTranslation < lower {
            offset = lower - min(54, (lower - relativeTranslation) * 0.20)
        } else {
            offset = relativeTranslation
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if dragStartOffset == nil { dragStartOffset = start }
            pageOffset = offset
        }
    }

    private func finishPageDrag(_ velocity: CGFloat, _ cancelled: Bool) {
        dragStartOffset = nil
        guard !projects.isEmpty else { pageOffset = 0; return }
        let projection = max(-pageWidth * 0.40, min(pageWidth * 0.40, velocity * 0.10))
        let currentOffset = pageOffset ?? -CGFloat(selectedPageIndex) * pageWidth
        let proposed = -(currentOffset + projection) / pageWidth
        let target = cancelled ? selectedPageIndex : min(projects.count - 1, max(0, Int(proposed.rounded())))
        withAnimation(pageSnapAnimation) {
            pageOffset = -CGFloat(target) * pageWidth
            selectedProjectID = projects[target].id.uuidString
        }
    }

}

/// A non-observable reference avoids invalidating the view tree on every frame.
/// The lock also keeps render-time samples independent from event delivery.
private final class TimelineMenuBarOffsetPresentation {
    private let lock = NSLock()
    private var offset: CGFloat?

    var currentOffset: CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return offset
    }

    func record(_ value: CGFloat) {
        lock.lock()
        offset = value
        lock.unlock()
    }
}

/// This is the strip's only translation. SwiftUI supplies its interpolated x
/// during snapping, allowing an interrupting drag to pick up that exact position.
private struct TimelineMenuBarPagingOffset: GeometryEffect {
    var x: CGFloat
    let presentation: TimelineMenuBarOffsetPresentation

    var animatableData: CGFloat {
        get { x }
        set { x = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        presentation.record(x)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// The project identity owns this state. Its first entry is expanded before the
/// horizontal transition begins, rather than opening in a second vertical pass.
private struct TimelineMenuBarProjectTimeline: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entries: [TimelineEntry]
    let onEditEntry: (TimelineEntry) -> Void
    @State private var expandedEntryID: UUID?

    init(entries: [TimelineEntry], onEditEntry: @escaping (TimelineEntry) -> Void) {
        self.entries = entries
        self.onEditEntry = onEditEntry
        _expandedEntryID = State(initialValue: entries.first?.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    TimelineMenuBarEntryRow(
                        entry: entry,
                        expanded: expandedEntryID == entry.id,
                        last: index == entries.count - 1,
                        showYear: TimelineDateSupport.showsYear(
                            for: entry.date,
                            previousDate: index > 0 ? entries[index - 1].date : nil
                        ),
                        onToggle: {
                            // Animate only the layout and content opacity. Keep
                            // the user's scroll position instead of jumping up.
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                                expandedEntryID = expandedEntryID == entry.id ? nil : entry.id
                            }
                        },
                        onEdit: { onEditEntry(entry) }
                    )
                    .id(entry.id)
                }
            }
            .padding(14)
            .environment(\.markdownLayoutWidth, 346)
        }
        .scrollIndicators(.automatic)
        .onChange(of: entries.map(\.id)) { _, currentIDs in
            if let expandedEntryID, !currentIDs.contains(expandedEntryID) {
                self.expandedEntryID = nil
            }
        }
        .accessibilityIdentifier("menuBarReadOnlyTimeline")
    }
}

private struct TimelineMenuBarEntryRow: View {
    let entry: TimelineEntry
    let expanded: Bool
    let last: Bool
    let showYear: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void

    private var hasProgress: Bool { entry.showProgress && !entry.progressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasIssues: Bool { entry.showIssues && !entry.issuesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var hasIdeas: Bool { entry.showIdeas && !entry.ideasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(expanded ? Color(white: 0.32) : Color(white: 0.78))
                    .frame(width: expanded ? 7 : 5, height: expanded ? 7 : 5)
                    .frame(width: 12, height: 16)
                Rectangle().fill(last ? Color.clear : Color(white: 0.90)).frame(width: 1)
            }
            .frame(width: 12)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(entry.date.formatted(showYear ? .dateTime.year().month(.twoDigits).day(.twoDigits) : .dateTime.month(.twoDigits).day(.twoDigits)))
                            .font(.system(size: 10, design: .monospaced))
                        Spacer(minLength: 0)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(Color(white: 0.55))
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(white: 0.18))
                        .lineLimit(expanded ? nil : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(TimelineMenuBarRecordActions(onSingleClick: onToggle, onDoubleClick: onEdit))
                .accessibilityLabel("\(entry.title)，\(entry.date.formatted(date: .abbreviated, time: .shortened))")
                .accessibilityValue(expanded ? "已展开" : "已折叠")
                .accessibilityHint("单击展开，双击在主窗口编辑")
                if expanded {
                    entryContents
                        .transition(.opacity)
                }
            }
            .padding(.bottom, last ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("menuBarEntry-\(entry.id.uuidString)")
    }

    private var entryContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            if hasProgress {
                contentSection("进展记录") {
                    MarkdownText(source: IssueChecklistSupport.progressDisplaySource(entry.progressText), onDoubleClick: onEdit)
                        .modifier(TimelineMenuBarProtectHorizontalScroll(source: entry.progressText))
                }
            }
            if hasIssues {
                if hasProgress { Divider().overlay(Color(white: 0.93)) }
                contentSection("待解决问题") {
                    // No toggle callback: these checkboxes only display saved state.
                    IssueChecklistRows(source: entry.issuesText, onDoubleClick: onEdit)
                        .modifier(TimelineMenuBarProtectHorizontalScroll(source: entry.issuesText))
                }
            }
            if hasIdeas {
                if hasProgress || hasIssues { Divider().overlay(Color(white: 0.93)) }
                contentSection("Idea") {
                    MarkdownText(source: entry.ideasText, onDoubleClick: onEdit)
                        .modifier(TimelineMenuBarProtectHorizontalScroll(source: entry.ideasText))
                }
            }
            if !entry.references.isEmpty {
                if hasProgress || hasIssues || hasIdeas { Divider().overlay(Color(white: 0.93)) }
                contentSection("引用") {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(entry.references) { reference in
                            TimelineMenuBarReferenceSnapshot(reference: reference, onEdit: onEdit)
                        }
                    }
                }
            }
            if !hasProgress && !hasIssues && !hasIdeas && entry.references.isEmpty {
                Text("这条记录没有正文内容")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .onTapGesture(count: 2, perform: onEdit)
            }
        }
        .background {
            Color.clear.contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onEdit)
        }
    }

    private func contentSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Circle().fill(Color(white: 0.52)).frame(width: 3, height: 3)
                Text(title).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(white: 0.43))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onEdit)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wait for the second click before expanding, so editing does not first collapse
/// the record or reference the user is trying to open.
private struct TimelineMenuBarRecordActions: ViewModifier {
    let onSingleClick: () -> Void
    let onDoubleClick: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
                switch result {
                case .first: onDoubleClick()
                case .second: onSingleClick()
                }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSingleClick() }
            .accessibilityAction(named: Text("在主窗口编辑"), onDoubleClick)
    }
}

private struct TimelineMenuBarReferenceSnapshot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reference: TimelineReference
    let onEdit: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "quote.opening").font(.system(size: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(reference.sourceTitle.isEmpty ? "未命名记录" : reference.sourceTitle)
                        .font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Text(reference.sourceDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.40))
            .modifier(TimelineMenuBarRecordActions(
                onSingleClick: { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { expanded.toggle() } },
                onDoubleClick: onEdit
            ))
            .accessibilityHint("单击查看引用，双击在主窗口编辑当前记录")
            if expanded {
                if !reference.contextBefore.isEmpty {
                    Text(reference.contextBefore).font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.60)).textSelection(.enabled)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in onEdit() })
                }
                MarkdownText(source: reference.excerpt, onDoubleClick: onEdit)
                    .modifier(TimelineMenuBarProtectHorizontalScroll(source: reference.excerpt))
                    .environment(\.markdownLayoutWidth, 326)
                if !reference.contextAfter.isEmpty {
                    Text(reference.contextAfter).font(.system(size: 12))
                        .foregroundStyle(Color(white: 0.60)).textSelection(.enabled)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { _ in onEdit() })
                }
            } else {
                Text(reference.excerpt).font(.system(size: 11)).lineLimit(2)
                    .foregroundStyle(Color(white: 0.40))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onEdit)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(white: 0.965))
                .onTapGesture(count: 2, perform: onEdit)
        }
    }
}

private enum TimelineMenuBarPagingSpace {
    static let name = "timeline.menuBar.paging"
}

private struct TimelineMenuBarProtectedScrollRegions: PreferenceKey {
    static var defaultValue: [CGRect] { [] }
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Code and table renderers retain horizontal scrolling. Protecting their whole
/// Markdown section is intentional: ordinary text does not require a DOM query.
private struct TimelineMenuBarProtectHorizontalScroll: ViewModifier {
    let source: String

    private var protectsHorizontalScrolling: Bool {
        source.contains("```") || source.contains("~~~") ||
            source.range(of: "(?m)^\\s*\\|?.+\\|.+\\n\\s*\\|?\\s*:?-{3,}", options: .regularExpression) != nil
    }

    func body(content: Content) -> some View {
        content.background {
            if protectsHorizontalScrolling {
                GeometryReader { geometry in
                    Color.clear.preference(key: TimelineMenuBarProtectedScrollRegions.self,
                                           value: [geometry.frame(in: .named(TimelineMenuBarPagingSpace.name))])
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// The event monitor belongs to the fixed viewport, never to an individual page.
/// Horizontal events are consumed once captured so child scroll views cannot
/// scroll at the same time. Ordinary Markdown remains mouse-selectable.
private struct TimelineMenuBarPagingRegion: NSViewRepresentable {
    let enabled: Bool
    let protectedRegions: [CGRect]
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> TimelineMenuBarPagingView {
        let view = TimelineMenuBarPagingView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TimelineMenuBarPagingView, context: Context) {
        view.enabled = enabled
        view.protectedRegions = protectedRegions
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleNSView(_ view: TimelineMenuBarPagingView, coordinator: ()) {
        view.stopMonitoring()
    }
}

private final class TimelineMenuBarPagingView: NSView {
    var enabled = false
    var protectedRegions: [CGRect] = []
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat, Bool) -> Void)?
    private var monitor: Any?
    private var windowObserver: NSObjectProtocol?
    private var endTimer: Timer?
    private var mouseOrigin: CGPoint?
    private var mouseCaptured = false
    private var mouseVertical = false
    private var mouseLastX: CGFloat = 0
    private var mouseLastTime: TimeInterval = 0
    private var mouseVelocity: CGFloat = 0
    private var wheelTotal = CGPoint.zero
    private var wheelCaptured = false
    private var wheelVertical = false
    private var wheelProtected = false
    private var wheelVelocity: CGFloat = 0
    private var lastWheelTime: TimeInterval = 0
    private var suppressMomentum = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopMonitoring()
        guard let window else { return }
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                 object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.mouseCaptured || self.wheelCaptured { self.onEnd?(0, true) }
            self.mouseOrigin = nil
            self.mouseCaptured = false
            self.resetWheel()
            self.suppressMomentum = false
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    deinit {
        endTimer?.invalidate()
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        endTimer?.invalidate()
        endTimer = nil
        mouseOrigin = nil
        mouseCaptured = false
        resetWheel()
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard enabled, let window, event.window === window, window.isVisible,
              !isHiddenOrHasHiddenAncestor else { return event }
        let point = convert(event.locationInWindow, from: nil)
        let inside = bounds.contains(point)
        if event.type == .scrollWheel {
            guard inside || wheelCaptured || suppressMomentum else { return event }
            return handleWheel(event, at: point)
        }
        switch event.type {
        case .leftMouseDown:
            mouseOrigin = nil
            mouseCaptured = false
            mouseVertical = false
            mouseVelocity = 0
            guard inside, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                  !isRenderedText(at: event.locationInWindow) else { return event }
            mouseOrigin = point
            mouseLastX = point.x
            mouseLastTime = event.timestamp
        case .leftMouseDragged:
            guard let origin = mouseOrigin, !mouseVertical else { return event }
            let x = point.x - origin.x, y = point.y - origin.y
            if !mouseCaptured {
                if abs(y) >= 10, abs(y) > abs(x) { mouseVertical = true; return event }
                guard abs(x) >= 10, abs(x) > abs(y) * 1.35 else { return event }
                mouseCaptured = true
            }
            mouseVelocity = smoothedVelocity(delta: point.x - mouseLastX,
                                              elapsed: event.timestamp - mouseLastTime,
                                              previous: mouseVelocity)
            mouseLastX = point.x
            mouseLastTime = event.timestamp
            onChange?(x)
            return nil
        case .leftMouseUp:
            defer { mouseOrigin = nil; mouseCaptured = false }
            guard mouseCaptured else { return event }
            if let origin = mouseOrigin { onChange?(point.x - origin.x) }
            let velocity = event.timestamp - mouseLastTime > 0.12 ? 0 : mouseVelocity
            onEnd?(velocity, false)
            // A completed page drag must not also click a title or reference.
            return nil
        default:
            break
        }
        return event
    }

    private func handleWheel(_ event: NSEvent, at point: CGPoint) -> NSEvent? {
        guard event.hasPreciseScrollingDeltas,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
        if !event.momentumPhase.isEmpty {
            let consume = suppressMomentum
            if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) {
                suppressMomentum = false
            }
            return consume ? nil : event
        }
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp - lastWheelTime > 0.22) {
            if wheelCaptured { onEnd?(0, false) }
            resetWheel()
            suppressMomentum = false
            wheelProtected = protectedRegions.contains { $0.contains(point) }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let captured = wheelCaptured
            if captured {
                let velocity = event.timestamp - lastWheelTime > 0.12 ? 0 : wheelVelocity
                onEnd?(velocity, event.phase.contains(.cancelled))
            }
            suppressMomentum = captured
            resetWheel()
            return captured ? nil : event
        }
        guard !wheelProtected else { return event }
        let elapsed = event.timestamp - lastWheelTime
        lastWheelTime = event.timestamp
        wheelTotal.x += event.scrollingDeltaX
        wheelTotal.y += event.scrollingDeltaY
        if !wheelCaptured {
            if abs(wheelTotal.y) >= 3, abs(wheelTotal.y) > abs(wheelTotal.x) * 1.15 {
                wheelVertical = true
            }
            guard !wheelVertical else { return event }
            guard abs(wheelTotal.x) >= 3, abs(wheelTotal.x) > abs(wheelTotal.y) * 1.35 else { return event }
            wheelCaptured = true
        }
        wheelVelocity = smoothedVelocity(delta: event.scrollingDeltaX, elapsed: elapsed, previous: wheelVelocity)
        onChange?(wheelTotal.x)
        if event.phase.isEmpty { scheduleWheelEnd() }
        return nil
    }

    private func scheduleWheelEnd() {
        endTimer?.invalidate()
        let timer = Timer(timeInterval: 0.14, repeats: false) { [weak self] _ in
            guard let self, self.wheelCaptured else { return }
            self.onEnd?(self.wheelVelocity, false)
            self.suppressMomentum = true
            self.resetWheel()
        }
        endTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func resetWheel() {
        endTimer?.invalidate()
        endTimer = nil
        wheelTotal = .zero
        wheelCaptured = false
        wheelVertical = false
        wheelProtected = false
        wheelVelocity = 0
    }

    private func smoothedVelocity(delta: CGFloat, elapsed: TimeInterval, previous: CGFloat) -> CGFloat {
        guard elapsed > 0, elapsed < 0.2 else { return 0 }
        let current = max(-3500, min(3500, delta / CGFloat(elapsed)))
        return previous * 0.5 + current * 0.5
    }

    private func isRenderedText(at windowPoint: CGPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        var candidate = content.hitTest(content.convert(windowPoint, from: nil))
        while let view = candidate {
            if view is WKWebView || view is NSTextView { return true }
            candidate = view.superview
        }
        return false
    }
}
#endif
