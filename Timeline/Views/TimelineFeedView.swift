import Foundation
import SwiftUI

struct TimelineFeedView: View {
    @EnvironmentObject private var referenceInteraction: ReferenceInteraction
    let project: TimelineProject
    let entries: [TimelineEntry]
    let onNewEntry: () -> Void
    let onEditEntry: (TimelineEntry) -> Void
    let onDeleteEntry: (TimelineEntry) -> Void
    var editor: AnyView? = nil
    var editingEntryID: UUID? = nil
    var editingSessionID: UUID? = nil

    @State private var focusedEntryID: UUID?
    @State private var currentDate = Date()
    @State private var searchText = ""
    @State private var showsColumnOptions = false
    @AppStorage("timeline.sections.progress") private var showsProgress = true
    @AppStorage("timeline.sections.issues") private var showsIssues = true
    @AppStorage("timeline.sections.ideas") private var showsIdeas = true

    private var matchingEntries: [TimelineEntry] {
        var ordered = entries.sorted { $0.date > $1.date }
        if let todayIndex = ordered.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: currentDate) }) {
            let todayEntry = ordered.remove(at: todayIndex)
            ordered.insert(todayEntry, at: 0)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ordered }
        return ordered.filter { entry in
            entry.id == editingEntryID || [entry.title, entry.progressText, entry.issuesText, entry.ideasText]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var showsTodayPlaceholder: Bool {
        !isCreatingEntry && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !entries.contains { Calendar.current.isDate($0.date, inSameDayAs: currentDate) }
    }

    private var isCreatingEntry: Bool { editor != nil && editingEntryID == nil }

    private func resolvedFocus(in visibleEntries: [TimelineEntry]) -> UUID? {
        if isCreatingEntry { return nil }
        if let editingEntryID, editor != nil { return editingEntryID }
        if let focusedEntryID, visibleEntries.contains(where: { $0.id == focusedEntryID }) { return focusedEntryID }
        if showsTodayPlaceholder { return nil }
        return visibleEntries.first?.id
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            let visibleEntries = matchingEntries
            let effectiveFocus = resolvedFocus(in: visibleEntries)
            let preload = preloadRequest(entries: visibleEntries, focus: effectiveFocus, width: geometry.size.width, compact: compact)
            VStack(spacing: 0) {
                header(compact: compact)
                if visibleEntries.isEmpty && !showsTodayPlaceholder && !isCreatingEntry {
                    VStack(spacing: 12) {
                        Text("没有找到相关记录").foregroundStyle(FeedColors.muted)
                        Button("清除搜索") { searchText = "" }.buttonStyle(.plain).foregroundStyle(FeedColors.accent)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if isCreatingEntry, let editor {
                                    TodayInlineEditorRow(date: currentDate, isLast: visibleEntries.isEmpty, compact: compact, editor: editor)
                                        .modifier(ReferenceDropFrame(target: .today))
                                        .id("inline-new-entry")
                                }
                                if showsTodayPlaceholder {
                                    TodayPlaceholderRow(
                                        date: currentDate,
                                        isFocused: effectiveFocus == nil,
                                        isLast: visibleEntries.isEmpty,
                                        compact: compact,
                                        showYear: TimelineDateSupport.showsYear(for: currentDate, previousDate: nil),
                                        onFocus: { withAnimation(.easeInOut(duration: 0.2)) { focusedEntryID = nil } },
                                        onCreate: onNewEntry
                                    )
                                    .modifier(ReferenceDropFrame(target: .today))
                                    .id("today-placeholder")
                                }
                                ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                                    EntryTimelineRow(
                                        entry: entry,
                                        isFocused: effectiveFocus == entry.id,
                                        isFirst: index == 0 && !showsTodayPlaceholder && !isCreatingEntry,
                                        isLast: index == visibleEntries.count - 1,
                                        showYear: TimelineDateSupport.showsYear(
                                            for: entry.date,
                                            previousDate: index > 0 ? visibleEntries[index - 1].date : ((showsTodayPlaceholder || isCreatingEntry) ? currentDate : nil)
                                        ),
                                        compact: compact,
                                        showsProgress: showsProgress,
                                        showsIssues: showsIssues,
                                        showsIdeas: showsIdeas,
                                        onFocus: { withAnimation(.easeInOut(duration: 0.2)) { focusedEntryID = entry.id } },
                                        onEdit: { onEditEntry(entry) },
                                        onDelete: { onDeleteEntry(entry) },
                                        editor: editingEntryID == entry.id ? editor : nil
                                    )
                                    .environment(\.markdownLayoutWidth, CGFloat(preload.width))
                                    .modifier(ReferenceDropFrame(target: .entry(entry.id)))
                                    .id(entry.id)
                                }
                            }
                            .frame(maxWidth: 900)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, compact ? 16 : 30)
                            .padding(.vertical, 24)
                        }
                        .background {
                            GeometryReader { viewport in
                                Color.clear
                                    .onChange(of: viewport.frame(in: .named(ReferenceInteraction.workspaceCoordinateSpace)), initial: true) { _, frame in
                                        referenceInteraction.updateFeedViewport(frame)
                                    }
                            }
                            .allowsHitTesting(false)
                        }
                        .onChange(of: effectiveFocus) { _, newID in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if let newID { proxy.scrollTo(newID, anchor: .top) }
                                else if isCreatingEntry { proxy.scrollTo("inline-new-entry", anchor: .top) }
                                else if showsTodayPlaceholder { proxy.scrollTo("today-placeholder", anchor: .top) }
                            }
                        }
                        .task(id: editingSessionID) {
                            guard editingSessionID != nil, let editingEntryID else { return }
                            searchText = ""
                            // Let the target row enter the unfiltered layout first.
                            // A fresh session also repositions an already-open draft.
                            await Task.yield()
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(editingEntryID, anchor: .top)
                            }
                        }
                        .onChange(of: isCreatingEntry) { _, isCreating in
                            if isCreating {
                                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("inline-new-entry", anchor: .top) }
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                bottomToolbar(compact: compact)
                    .padding(.trailing, compact ? 20 : 30)
                    .padding(.top, 8)
                    .padding(.bottom, compact ? 10 : 14)
            }
            .background(FeedColors.canvas)
            .task(id: preload) {
                guard editor == nil else { return }
                await MarkdownRenderCache.preload(documents: preload.documents)
            }
        }
        .onChange(of: project.id) { _, _ in
            focusedEntryID = nil
            searchText = ""
        }
        .onChange(of: editingEntryID) { previousID, currentID in
            if currentID != nil { searchText = "" }
            if let id = currentID ?? previousID { focusedEntryID = id }
        }
        .onChange(of: referenceInteraction.focusRevision) { _, _ in
            switch referenceInteraction.requestedFocusTarget {
            case .entry(let id): focusedEntryID = id
            case .today:
                focusedEntryID = matchingEntries.first { Calendar.current.isDate($0.date, inSameDayAs: currentDate) }?.id
            case nil: break
            }
        }
        .onChange(of: entries.map(\.id)) { previousIDs, currentIDs in
            if let addedID = currentIDs.first(where: { !previousIDs.contains($0) }) {
                focusedEntryID = addedID
                searchText = ""
            }
        }
        .onChange(of: Calendar.current.startOfDay(for: currentDate)) { _, _ in focusedEntryID = nil }
        .task {
            while !Task.isCancelled {
                currentDate = .now
                do { try await Task.sleep(for: .seconds(60)) }
                catch { return }
            }
        }
    }

    private struct PreloadRequest: Equatable {
        var documents: [MarkdownRenderCache.Document]
        var width: Int
    }

    private func preloadRequest(entries: [TimelineEntry], focus: UUID?, width: CGFloat, compact: Bool) -> PreloadRequest {
        let rowWidth = min(900, width - (compact ? 32 : 60))
        let contentWidth = max(40, rowWidth - (compact ? 61 : 145))
        guard !entries.isEmpty else { return PreloadRequest(documents: [], width: Int(contentWidth)) }
        let current = entries.firstIndex { $0.id == focus } ?? -1
        let neighbors = [current + 1, current - 1].filter { entries.indices.contains($0) }
        var documents: [MarkdownRenderCache.Document] = []
        for index in neighbors {
            let entry = entries[index]
            if showsProgress && entry.showProgress { documents.append(.init(source: IssueChecklistSupport.progressDisplaySource(entry.progressText), width: Int(contentWidth))) }
            if showsIdeas && entry.showIdeas { documents.append(.init(source: entry.ideasText, width: Int(contentWidth))) }
            if showsIssues && entry.showIssues {
                for row in IssueChecklistSupport.rows(in: entry.issuesText) {
                    switch row.content {
                    case .task(let task): documents.append(.init(source: task.isChecked ? "~~\(task.text)~~" : task.text, width: Int(contentWidth - 26 - CGFloat(task.indentation) * 10)))
                    case .markdown(let text): documents.append(.init(source: text, width: Int(contentWidth)))
                    case .blank: break
                    }
                }
            }
        }
        return PreloadRequest(documents: Array(documents.filter { !$0.source.isEmpty }.prefix(6)), width: Int(contentWidth))
    }

    private func header(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(FeedColors.muted)
                TextField("搜索记录", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(FeedColors.muted)
                    }.buttonStyle(.plain).accessibilityLabel("清除搜索")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: compact ? 140 : 220)
            Spacer(minLength: 0)
            TimelineWordmark()
                .frame(width: compact ? 91 : 105, height: compact ? 30 : 34)
                .foregroundStyle(Color.gray.opacity(0.40))
                .allowsHitTesting(false).accessibilityLabel("Timeline")
        }
        .frame(minHeight: 40)
        .padding(.horizontal, compact ? 18 : 28).padding(.top, 12)
    }

    private func bottomToolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Button { showsColumnOptions.toggle() } label: {
                Image(systemName: "slider.horizontal.3")
                    .frame(width: compact ? 40 : 32, height: compact ? 40 : 32)
            }
            .buttonStyle(.plain).accessibilityLabel("栏目显示").help("显示设置")
            .popover(isPresented: $showsColumnOptions, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 15) {
                    Text("显示栏目").font(.system(size: 13, weight: .semibold))
                    Toggle("进展记录", isOn: $showsProgress)
                    Toggle("待解决问题", isOn: $showsIssues)
                    Toggle("Idea", isOn: $showsIdeas)
                }
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
                .padding(20).frame(width: 240)
            }
            Button(action: onNewEntry) {
                Image(systemName: "plus")
                    .frame(width: compact ? 40 : 32, height: compact ? 40 : 32)
            }
            .buttonStyle(.plain).accessibilityLabel("新建记录").help("新建记录")
        }
        .font(.system(size: 14, weight: .regular)).foregroundStyle(FeedColors.muted)
    }

}

private struct ReferenceDropFrame: ViewModifier {
    @EnvironmentObject private var interaction: ReferenceInteraction
    let target: ReferenceDropTarget

    func body(content: Content) -> some View {
        content
            .background(interaction.hoveredTarget == target ? FeedColors.accent.opacity(0.045) : Color.clear)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ReferenceTargetFramesKey.self,
                        value: [target: geometry.frame(in: .named(ReferenceInteraction.workspaceCoordinateSpace))]
                    )
                }
                .allowsHitTesting(false)
            }
    }
}

private struct RecordTapActions: ViewModifier {
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    var doubleTapActionName = "编辑记录"

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 2).exclusively(before: TapGesture(count: 1)).onEnded { result in
                switch result {
                case .first: onDoubleTap()
                case .second: onSingleTap()
                }
            })
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onSingleTap() }
            .accessibilityAction(named: Text(doubleTapActionName)) { onDoubleTap() }
    }
}

private struct TodayPlaceholderRow: View {
    let date: Date
    let isFocused: Bool
    let isLast: Bool
    let compact: Bool
    let showYear: Bool
    let onFocus: () -> Void
    let onCreate: () -> Void

    private var singleTapAction: () -> Void {
        #if os(iOS)
        onCreate
        #else
        onFocus
        #endif
    }

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 9 : 16) {
            if !compact {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                        .foregroundStyle(isFocused ? FeedColors.accent : FeedColors.muted)
                    if showYear {
                        Text(date.formatted(.dateTime.year()))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(FeedColors.faint)
                    }
                }
                .frame(width: 55, alignment: .trailing).padding(.top, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted))
            }
            VStack(spacing: 0) {
                Color.clear.frame(width: 1, height: 18)
                Circle().fill(isFocused ? FeedColors.accent : FeedColors.canvas)
                    .frame(width: isFocused ? 8 : 6, height: isFocused ? 8 : 6)
                    .overlay(Circle().stroke(isFocused ? FeedColors.accent : FeedColors.faint, lineWidth: 1))
                    .frame(width: 18, height: 18)
                    .modifier(RecordTapActions(onSingleTap: singleTapAction, onDoubleTap: onCreate, doubleTapActionName: "新建记录"))
                    .accessibilityLabel("今日记录，双击开始记录")
                    .accessibilityAction { onCreate() }
                Rectangle().fill(isLast ? Color.clear : FeedColors.line).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 9) {
                if compact {
                    Text(date.formatted(showYear ? .dateTime.year().month(.twoDigits).day(.twoDigits) : .dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(FeedColors.muted)
                }
                Text("今日记录").font(.system(size: isFocused ? 20 : 17, weight: .semibold))
                    .foregroundStyle(FeedColors.ink)
                Text("双击开始记录").font(.system(size: 12)).foregroundStyle(FeedColors.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 17 : 20)
            .modifier(RecordTapActions(onSingleTap: singleTapAction, onDoubleTap: onCreate, doubleTapActionName: "新建记录"))
            .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，今日记录，双击开始记录")
            .accessibilityAction { onCreate() }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TodayInlineEditorRow: View {
    let date: Date
    let isLast: Bool
    let compact: Bool
    let editor: AnyView

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 9 : 16) {
            if !compact {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(FeedColors.accent)
                    Text(date.formatted(.dateTime.year()))
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(FeedColors.faint)
                }
                .frame(width: 55, alignment: .trailing).padding(.top, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(date.formatted(date: .abbreviated, time: .omitted))
            }
            VStack(spacing: 0) {
                Color.clear.frame(width: 1, height: 18)
                Circle().fill(FeedColors.accent).frame(width: 8, height: 8).frame(width: 18, height: 18)
                Rectangle().fill(isLast ? Color.clear : FeedColors.line).frame(width: 1).frame(maxHeight: .infinity)
            }.frame(width: 18)
            VStack(alignment: .leading, spacing: 10) {
                if compact {
                    Text(date.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(FeedColors.muted)
                        .padding(.horizontal, 17).padding(.top, 17)
                }
                editor
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

enum TimelineDateSupport {
    /// The previous date is the preceding, newer visible row in a descending
    /// timeline. The newest row of each year carries that year's label.
    static func showsYear(for date: Date, previousDate: Date?, calendar: Calendar = .current) -> Bool {
        guard let previousDate else { return true }
        return calendar.component(.year, from: date) != calendar.component(.year, from: previousDate)
    }
}

private struct EntryTimelineRow: View {
    let entry: TimelineEntry
    let isFocused: Bool
    let isFirst: Bool
    let isLast: Bool
    let showYear: Bool
    let compact: Bool
    let showsProgress: Bool
    let showsIssues: Bool
    let showsIdeas: Bool
    let onFocus: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var editor: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: compact ? 9 : 16) {
            if !compact {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                        .foregroundStyle(isFocused ? FeedColors.accent : FeedColors.muted)
                    if showYear {
                        Text(entry.date.formatted(.dateTime.year()))
                            .font(.system(size: 9, design: .monospaced)).foregroundStyle(FeedColors.faint)
                    }
                }
                .frame(width: 55, alignment: .trailing).padding(.top, 18)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.date.formatted(date: .abbreviated, time: .omitted))
            }
            rail
            Group {
                if let editor {
                    VStack(alignment: .leading, spacing: 0) {
                        if compact {
                            Text(entry.date.formatted(showYear ? .dateTime.year().month(.twoDigits).day(.twoDigits) : .dateTime.month(.twoDigits).day(.twoDigits)))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(FeedColors.muted)
                                .padding(.horizontal, 24).padding(.top, 17)
                        }
                        editor
                    }
                } else if isFocused {
                    EntryFocusCard(entry: entry, compact: compact, showYear: showYear, showsProgress: showsProgress, showsIssues: showsIssues, showsIdeas: showsIdeas, onEdit: onEdit, onDelete: onDelete)
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if compact {
                            Text(entry.date.formatted(showYear ? .dateTime.year().month(.twoDigits).day(.twoDigits) : .dateTime.month(.twoDigits).day(.twoDigits)))
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(FeedColors.muted)
                        }
                        Text(entry.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(FeedColors.secondaryInk)
                            .lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 18)
                    .modifier(RecordTapActions(onSingleTap: onFocus, onDoubleTap: { onFocus(); onEdit() }))
                    .accessibilityLabel("\(entry.date.formatted(date: .abbreviated, time: .omitted))，\(entry.title)，点击展开")
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            Rectangle().fill(isFirst ? Color.clear : FeedColors.line).frame(width: 1, height: 18)
            Circle().fill(isFocused ? FeedColors.accent : FeedColors.canvas)
                .frame(width: isFocused ? 8 : 6, height: isFocused ? 8 : 6)
                .overlay(Circle().stroke(isFocused ? FeedColors.accent : FeedColors.faint, lineWidth: 1))
                .frame(width: 18, height: 18)
                .modifier(RecordTapActions(onSingleTap: onFocus, onDoubleTap: { onFocus(); onEdit() }))
                .accessibilityLabel("聚焦记录：\(entry.date.formatted(date: .abbreviated, time: .omitted))，\(entry.title)")
            Rectangle().fill(isLast ? Color.clear : FeedColors.line).frame(width: 1).frame(maxHeight: .infinity)
        }
        .frame(width: 18)
    }
}

private struct EntryFocusCard: View {
    @EnvironmentObject private var references: ReferenceInteraction
    let entry: TimelineEntry
    let compact: Bool
    let showYear: Bool
    let showsProgress: Bool
    let showsIssues: Bool
    let showsIdeas: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var hasProgress: Bool {
        showsProgress && entry.showProgress && !entry.progressText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasIssues: Bool {
        showsIssues && entry.showIssues && !entry.issuesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var hasIdeas: Bool {
        showsIdeas && entry.showIdeas && !entry.ideasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                if compact {
                    Text(entry.date.formatted(showYear ? .dateTime.year().month(.twoDigits).day(.twoDigits) : .dateTime.month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(FeedColors.muted)
                        .accessibilityLabel(entry.date.formatted(date: .abbreviated, time: .omitted))
                }
                Text(entry.title).font(.system(size: 20, weight: .semibold)).tracking(-0.3)
                    .foregroundStyle(FeedColors.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .contentShape(Rectangle()).onTapGesture(count: 2, perform: onEdit)
            if hasProgress || hasIssues || hasIdeas {
                VStack(alignment: .leading, spacing: 12) {
                    if hasProgress {
                        EntryContentSection(title: "进展记录", symbol: "circle.fill", text: IssueChecklistSupport.progressDisplaySource(entry.progressText), onEdit: onEdit, onQuote: { captureQuote($0, source: entry.progressText) })
                    }
                    if hasIssues {
                        if hasProgress { Divider().overlay(FeedColors.line) }
                        EntryIssuesSection(entry: entry, onEdit: onEdit, onQuote: { captureQuote($0, source: entry.issuesText) })
                    }
                    if hasIdeas {
                        if hasProgress || hasIssues { Divider().overlay(FeedColors.line) }
                        EntryContentSection(title: "Idea", symbol: "circle.fill", text: entry.ideasText, onEdit: onEdit, onQuote: { captureQuote($0, source: entry.ideasText) })
                    }
                }
            }
            if !entry.references.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(entry.references) { reference in
                        AttachedReferenceView(reference: reference)
                    }
                }
            }
            HStack(spacing: 14) {
                Spacer()
                Button(action: onEdit) {
                    Image(systemName: "square.and.pencil").font(.system(size: 12))
                }.buttonStyle(.plain).accessibilityLabel("编辑记录")
                Menu {
                    Button("编辑记录", systemImage: "square.and.pencil", action: onEdit)
                    Button("删除记录", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12)).frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("记录操作")
            }
            .foregroundStyle(FeedColors.muted)
        }
        .padding(compact ? 17 : 20)
    }

    private func captureQuote(_ text: String, source: String) {
        references.capture(text: text, from: entry, source: source)
    }
}

private struct AttachedReferenceView: View {
    let reference: TimelineReference
    @State private var showsSource = false

    var body: some View {
        Button { showsSource = true } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(reference.excerpt)
                    .font(.system(size: 12)).foregroundStyle(FeedColors.secondaryInk)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Text(reference.sourceTitle)
                    .font(.system(size: 10)).foregroundStyle(FeedColors.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 11).padding(.vertical, 4)
            .overlay(alignment: .leading) {
                Rectangle().fill(FeedColors.line).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看引用：\(reference.sourceTitle)")
        .popover(isPresented: $showsSource, arrowEdge: .bottom) {
            ReferencePreviewView(reference: reference)
        }
    }
}

private struct EntrySectionLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 5 : 11))
                .frame(width: 12).foregroundStyle(FeedColors.muted)
            Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(FeedColors.secondaryInk)
        }
    }
}

private struct EntryContentSection: View {
    let title: String
    let symbol: String
    let text: String
    let onEdit: () -> Void
    let onQuote: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EntrySectionLabel(title: title, symbol: symbol).onTapGesture(count: 2, perform: onEdit)
            MarkdownText(source: text, onDoubleClick: onEdit, onQuote: onQuote).font(.system(size: 13))
                .foregroundStyle(FeedColors.secondaryInk).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct EntryIssuesSection: View {
    @EnvironmentObject private var store: TimelineStore
    let entry: TimelineEntry
    let onEdit: () -> Void
    let onQuote: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            EntrySectionLabel(title: "待解决问题", symbol: "circle.fill").onTapGesture(count: 2, perform: onEdit)
            IssueChecklistRows(source: entry.issuesText, onDoubleClick: onEdit, onQuote: onQuote) { lineIndex in
                guard !store.isRecoveryMode else { return }
                entry.issuesText = IssueChecklistSupport.togglingTask(in: entry.issuesText, atLine: lineIndex)
                store.touch(entry)
            }
            .disabled(store.isRecoveryMode)
        }
    }
}

/// Used by the timeline and the editor preview. Only the checkbox is interactive,
/// so links and text selection keep their normal Markdown behavior.
struct IssueChecklistRows: View {
    @Environment(\.markdownLayoutWidth) private var layoutWidth
    let source: String
    var onDoubleClick: (() -> Void)? = nil
    var onQuote: ((String) -> Void)? = nil
    var onToggle: ((Int) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(IssueChecklistSupport.rows(in: source)) { row in
                switch row.content {
                case let .task(task):
                    HStack(alignment: .top, spacing: 8) {
                        if let onToggle {
                            Button { onToggle(task.lineIndex) } label: { checkbox(task.isChecked) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(task.isChecked ? "标记未解决" : "标记已解决")：\(task.text)")
                                .accessibilityValue(task.isChecked ? "已解决" : "未解决")
                        } else {
                            checkbox(task.isChecked).accessibilityLabel(task.isChecked ? "已解决" : "未解决")
                        }
                        MarkdownText(source: task.isChecked ? "~~\(task.text)~~" : task.text,
                                     onDoubleClick: onDoubleClick, onQuote: onQuote)
                            .environment(\.markdownLayoutWidth, max(0, layoutWidth - 26 - CGFloat(task.indentation) * 10))
                            .opacity(task.isChecked ? 0.55 : 1)
                    }
                    .font(.system(size: 13))
                    .padding(.leading, CGFloat(task.indentation) * 10)
                case let .markdown(source):
                    MarkdownText(source: source, onDoubleClick: onDoubleClick, onQuote: onQuote).font(.system(size: 13)).foregroundStyle(FeedColors.secondaryInk)
                case .blank:
                    Color.clear.frame(height: 3).accessibilityHidden(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func checkbox(_ checked: Bool) -> some View {
        Image(systemName: checked ? "checkmark.square.fill" : "square")
            .font(.system(size: 14)).foregroundStyle(checked ? FeedColors.accent : FeedColors.muted)
            .frame(width: 18, height: 20).contentShape(Rectangle())
    }

    private func inline(_ source: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let value = try? AttributedString(markdown: source, options: options) { return Text(value) }
        return Text(verbatim: source)
    }
}

/// Line-based edits preserve every other source character, including empty lines,
/// indentation, Markdown formatting, and CRLF endings.
enum IssueChecklistSupport {
    struct Task {
        let lineIndex: Int
        let text: String
        let isChecked: Bool
        let indentation: Int
        fileprivate let checkboxCharacterLocation: Int?
        fileprivate let checkboxRange: NSRange?
        fileprivate let contentLocation: Int
        fileprivate let hasListMarker: Bool
    }

    struct Row: Identifiable {
        enum Content {
            case task(Task)
            case markdown(String)
            case blank
        }
        let id: Int
        let content: Content
    }

    static func rows(in source: String) -> [Row] {
        let lines = source.components(separatedBy: "\n")
        var result: [Row] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                result.append(Row(id: index, content: .blank))
                index += 1
                continue
            }
            if let fence = fenceMarker(trimmed) {
                let start = index
                index += 1
                while index < lines.count {
                    let next = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    index += 1
                    if next.hasPrefix(fence) { break }
                }
                result.append(Row(id: start, content: .markdown(lines[start..<index].joined(separator: "\n"))))
                continue
            }
            if isMarkdownBlock(line) {
                result.append(Row(id: index, content: .markdown(line)))
            } else {
                result.append(Row(id: index, content: .task(parseTask(line, atLine: index))))
            }
            index += 1
        }
        return result
    }

    static func togglingTask(in source: String, atLine lineIndex: Int) -> String {
        guard let row = rows(in: source).first(where: { $0.id == lineIndex }), case let .task(task) = row.content else { return source }
        var lines = source.components(separatedBy: "\n")
        guard lines.indices.contains(lineIndex) else { return source }
        let changedLine = NSMutableString(string: lines[lineIndex])
        if let location = task.checkboxCharacterLocation {
            changedLine.replaceCharacters(in: NSRange(location: location, length: 1), with: task.isChecked ? " " : "x")
        } else {
            changedLine.insert(task.hasListMarker ? "[x] " : "- [x] ", at: task.contentLocation)
        }
        lines[lineIndex] = changedLine as String
        return lines.joined(separator: "\n")
    }

    static func progressDisplaySource(_ source: String) -> String {
        var lines = source.components(separatedBy: "\n")
        var fence: String?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if let openFence = fence {
                if trimmed.hasPrefix(openFence) { fence = nil }
                continue
            }
            if let marker = fenceMarker(trimmed) { fence = marker; continue }
            guard !isMarkdownBlock(lines[index]) else { continue }
            let task = parseTask(lines[index], atLine: index)
            guard let range = task.checkboxRange else { continue }
            let rendered = NSMutableString(string: lines[index])
            rendered.replaceCharacters(in: range, with: task.hasListMarker ? "" : "- ")
            lines[index] = rendered as String
        }
        return lines.joined(separator: "\n")
    }

    private static func parseTask(_ line: String, atLine lineIndex: Int) -> Task {
        let body = line.hasSuffix("\r") ? String(line.dropLast()) : line
        let string = body as NSString
        let leadingCount = body.prefix(while: { $0 == " " || $0 == "\t" }).utf16.count
        let listPattern = #"^([ \t]*)(?:[-*+]|[0-9]+[.)])[ \t]+"#
        let listMatch = firstMatch(listPattern, in: body)
        let contentLocation = listMatch?.range.length ?? leadingCount
        let remainder = string.substring(from: min(contentLocation, string.length))
        let checkboxMatch = firstMatch(#"^\[([ xX])\](?:[ \t]+|$)"#, in: remainder)
        var textLocation = contentLocation
        var markerLocation: Int?
        var checkboxRange: NSRange?
        var checked = false
        if let checkboxMatch {
            markerLocation = contentLocation + checkboxMatch.range(at: 1).location
            checkboxRange = NSRange(location: contentLocation, length: checkboxMatch.range.length)
            checked = (remainder as NSString).substring(with: checkboxMatch.range(at: 1)).lowercased() == "x"
            textLocation += checkboxMatch.range.length
        }
        return Task(
            lineIndex: lineIndex,
            text: string.substring(from: min(textLocation, string.length)),
            isChecked: checked,
            indentation: min(leadingCount / 2, 5),
            checkboxCharacterLocation: markerLocation,
            checkboxRange: checkboxRange,
            contentLocation: contentLocation,
            hasListMarker: listMatch != nil
        )
    }

    private static func isMarkdownBlock(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("|") || ["---", "***", "___"].contains(trimmed) { return true }
        if firstMatch(#"^#{1,6}[ \t]+"#, in: trimmed) != nil { return true }
        if firstMatch(#"^\[[^\]]+\]:[ \t]*"#, in: trimmed) != nil { return true }
        // Keep indented code untouched, while allowing indented list tasks.
        let indented = line.hasPrefix("    ") || line.hasPrefix("\t")
        return indented && firstMatch(#"^[ \t]*(?:[-*+]|[0-9]+[.)])[ \t]+"#, in: line) == nil
    }

    private static func fenceMarker(_ trimmed: String) -> String? {
        if trimmed.hasPrefix("```") { return String(trimmed.prefix(while: { $0 == "`" })) }
        if trimmed.hasPrefix("~~~") { return String(trimmed.prefix(while: { $0 == "~" })) }
        return nil
    }

    private static func firstMatch(_ pattern: String, in source: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
    }
}

private enum FeedColors {
    static let canvas = Color(red: 0.992, green: 0.992, blue: 0.992)
    static let wash = Color(red: 0.955, green: 0.958, blue: 0.960)
    static let ink = Color(red: 0.18, green: 0.19, blue: 0.20)
    static let secondaryInk = Color(red: 0.32, green: 0.34, blue: 0.36)
    static let muted = Color(red: 0.55, green: 0.57, blue: 0.59)
    static let faint = Color(red: 0.70, green: 0.71, blue: 0.72)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.92)
    static let accent = Color(red: 0.70, green: 0.38, blue: 0.30)
}
