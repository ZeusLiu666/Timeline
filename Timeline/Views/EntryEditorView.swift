import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct EntryDraft: Equatable {
    var title: String
    var date: Date
    var progress: String
    var progressPercent: Int
    var progressText: String
    var issuesText: String
    var ideasText: String
    var showProgress: Bool
    var showIssues: Bool
    var showIdeas: Bool
    var references: [TimelineReference] = []
}

struct EntryEditorView: View {
    let project: TimelineProject
    let entry: TimelineEntry?
    let onSave: (EntryDraft) -> Bool
    let onDraftChange: ((EntryDraft) -> Void)?
    let inline: Bool
    let onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var date: Date
    @State private var progress: String
    @State private var progressPercent: Double
    @State private var progressText: String
    @State private var issuesText: String
    @State private var ideasText: String
    @State private var showProgress: Bool
    @State private var showIssues: Bool
    @State private var showIdeas: Bool
    @State private var showsIssueInput: Bool
    @State private var showsIdeaInput: Bool
    @State private var showsLivePreview = true
    @State private var editorWidth: CGFloat = 0
    @State private var references: [TimelineReference]
    @State private var inspectedReference: TimelineReference?
    @State private var saveError: String?
    @State private var focusedField: ComposeField?
    @FocusState private var titleIsFocused: Bool

    private enum ComposeField: Hashable { case title, progress, issues, ideas }

    init(project: TimelineProject, entry: TimelineEntry? = nil, additionalReferences: [TimelineReference] = [], initialDraft: EntryDraft? = nil, onDraftChange: ((EntryDraft) -> Void)? = nil, inline: Bool = false, onCancel: (() -> Void)? = nil, onSave: @escaping (EntryDraft) -> Bool) {
        self.project = project
        self.entry = entry
        self.onSave = onSave
        self.onDraftChange = onDraftChange
        self.inline = inline
        self.onCancel = onCancel
        let original = initialDraft?.references ?? entry?.references ?? []
        let knownIDs = Set(original.map(\.id))
        _references = State(initialValue: initialDraft == nil ? original + additionalReferences.filter { !knownIDs.contains($0.id) } : original)
        _title = State(initialValue: initialDraft?.title ?? entry?.title ?? "")
        _date = State(initialValue: initialDraft?.date ?? entry?.date ?? Date())
        _progress = State(initialValue: initialDraft?.progress ?? entry?.progress ?? EntryStatus.inProgress.rawValue)
        _progressPercent = State(initialValue: Double(initialDraft?.progressPercent ?? entry?.progressPercent ?? 25))
        _progressText = State(initialValue: initialDraft?.progressText ?? entry?.progressText ?? "")
        _issuesText = State(initialValue: initialDraft?.issuesText ?? entry?.issuesText ?? "")
        _ideasText = State(initialValue: initialDraft?.ideasText ?? entry?.ideasText ?? "")
        _showProgress = State(initialValue: initialDraft?.showProgress ?? entry?.showProgress ?? true)
        _showIssues = State(initialValue: initialDraft?.showIssues ?? entry?.showIssues ?? false)
        _showIdeas = State(initialValue: initialDraft?.showIdeas ?? entry?.showIdeas ?? false)
        _showsIssueInput = State(initialValue: !(initialDraft?.issuesText ?? entry?.issuesText ?? "").isEmpty)
        _showsIdeaInput = State(initialValue: !(initialDraft?.ideasText ?? entry?.ideasText ?? "").isEmpty)
    }

    private var canSave: Bool {
        !references.isEmpty || [title, progressText, issuesText, ideasText].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var resolvedTitle: String {
        if [title, progressText, issuesText, ideasText].allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }), let reference = references.first {
            return "引用：" + String(reference.sourceTitle.prefix(30))
        }
        return EntryEditorSupport.title(explicit: title, progress: progressText, issues: issuesText, ideas: ideasText)
    }

    private var previewHeadingField: ComposeField? {
        guard showsLivePreview else { return nil }
        let sections: [(field: ComposeField, visible: Bool, source: String)] = [
            (.progress, true, progressText),
            (.issues, showsIssueInput, issuesText),
            (.ideas, showsIdeaInput, ideasText)
        ]
        return sections.first {
            $0.visible && (editorWidth > 700 || !$0.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }?.field
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(entry == nil ? "新记录" : "编辑记录")
                    .font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("取消", action: closeEditor).buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(EditorColors.muted).keyboardShortcut(.cancelAction)
                    .fixedSize()
                Button(action: save) {
                    Text("保存").font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 8)
                        .background(canSave ? EditorColors.accent : EditorColors.faint, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command).disabled(!canSave)
                .fixedSize()
            }
            .foregroundStyle(EditorColors.ink).padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 17)
            if inline {
                composition
            } else {
                ScrollView { composition }
            }
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Color.red.opacity(0.04))
                    .accessibilityLabel(saveError)
            }
            Divider().overlay(EditorColors.line)
            HStack(spacing: 16) {
                Text(project.name).font(.system(size: 10)).foregroundStyle(EditorColors.muted).lineLimit(1)
                Spacer(minLength: 4)
                Button { showsLivePreview.toggle() } label: {
                    Image(systemName: showsLivePreview ? "eye" : "eye.slash")
                        .font(.system(size: 12)).foregroundStyle(EditorColors.muted)
                }
                .buttonStyle(.plain).accessibilityLabel(showsLivePreview ? "隐藏实时预览" : "显示实时预览")
            }
            .padding(.horizontal, 24).padding(.vertical, 15)
        }
        .background(.white)
        .environment(\.markdownLayoutWidth, 0)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { editorWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in editorWidth = width }
            }
        }
        .task {
            guard entry == nil else { return }
            try? await Task.sleep(for: .milliseconds(inline ? 100 : 350))
            guard !Task.isCancelled else { return }
            focusedField = .progress
        }
        .onChange(of: currentDraft, initial: true) { _, draft in onDraftChange?(draft) }
        .onChange(of: titleIsFocused) { _, focused in
            if focused { focusedField = nil }
        }
        #if os(macOS)
        .frame(minWidth: inline ? nil : 760, idealWidth: inline ? nil : 840, maxWidth: .infinity, minHeight: inline ? nil : 480, idealHeight: inline ? nil : 600)
        #endif
    }

    private var composition: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("标题（可选，留空自动生成）", text: $title, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .medium))
                .lineLimit(1...2).foregroundStyle(EditorColors.ink)
                .focused($titleIsFocused).accessibilityLabel("记录标题，可选")
            attachedReferences
            composeSection(title: "进展记录", symbol: "circle.fill", text: $progressText, field: .progress,
                           placeholder: "写下今天的进展…\n- 完成了什么\n- 下一步计划", height: 144)
            if showsIssueInput {
                composeSection(title: "待解决问题", symbol: "circle.fill", text: $issuesText, field: .issues,
                               placeholder: "每行一个问题，使用 - [ ]；\n完成后可在时间线上勾选。", height: 120)
            }
            if showsIdeaInput {
                composeSection(title: "Idea", symbol: "circle.fill", text: $ideasText, field: .ideas,
                               placeholder: "有什么值得留下的想法？", height: 120)
            }
            if !showsIssueInput || !showsIdeaInput {
                HStack(spacing: 18) {
                    if !showsIssueInput {
                        Button {
                            showsIssueInput = true
                            showIssues = true
                            focusedField = .issues
                        } label: { Label("问题", systemImage: "plus") }
                    }
                    if !showsIdeaInput {
                        Button {
                            showsIdeaInput = true
                            showIdeas = true
                            focusedField = .ideas
                        } label: { Label("Idea", systemImage: "plus") }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(EditorColors.muted)
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 22)
    }

    @ViewBuilder
    private var attachedReferences: some View {
        if !references.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("引用").font(.system(size: 11, weight: .medium)).foregroundStyle(EditorColors.muted)
                ForEach(references) { reference in
                    HStack(alignment: .top, spacing: 10) {
                        Button { inspectedReference = reference } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "quote.opening").font(.system(size: 12)).foregroundStyle(EditorColors.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(reference.sourceDate.formatted(date: .abbreviated, time: .omitted) + " · " + reference.sourceTitle)
                                        .font(.system(size: 10)).foregroundStyle(EditorColors.muted).lineLimit(1)
                                    Text(reference.excerpt).font(.system(size: 12)).foregroundStyle(EditorColors.secondaryInk).lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("查看引用：\(reference.sourceTitle)")
                        Button { references.removeAll { $0.id == reference.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(EditorColors.muted)
                        }.buttonStyle(.plain).accessibilityLabel("移除此引用")
                    }
                    .padding(10).background(EditorColors.wash, in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .popover(item: $inspectedReference) { reference in
                ReferencePreviewView(reference: reference)
            }
        }
    }

    private func composeSection(title: String, symbol: String, text: Binding<String>, field: ComposeField, placeholder: String, height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if field == .issues || field == .ideas { Divider().overlay(EditorColors.line).padding(.bottom, 8) }
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 5)).frame(width: 12)
                Text(title).font(.system(size: 14, weight: .medium))
                Spacer()
                if previewHeadingField == field {
                    Text("实时预览").font(.system(size: 10)).foregroundStyle(EditorColors.faint)
                }
            }.foregroundStyle(EditorColors.muted)
            if showsLivePreview && editorWidth > 700 {
                HStack(alignment: .top, spacing: 18) {
                    sourceEditor(text: text, field: field, placeholder: placeholder, height: height)
                        .frame(maxWidth: .infinity)
                    renderedPreview(source: text.wrappedValue, field: field, minHeight: height)
                        .frame(maxWidth: .infinity)
                }
            } else {
                sourceEditor(text: text, field: field, placeholder: placeholder, height: height)
                if showsLivePreview && !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    renderedPreview(source: text.wrappedValue, field: field, minHeight: 36)
                        .padding(.top, 5)
                }
            }
        }
    }

    private func sourceEditor(text: Binding<String>, field: ComposeField, placeholder: String, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder).font(.system(size: 13)).lineSpacing(4).foregroundStyle(EditorColors.faint)
                    .padding(.horizontal, 13).padding(.top, 12).allowsHitTesting(false)
            }
            TimelineGrowingTextEditor(text: text,
                isFocused: Binding(get: { focusedField == field }, set: { focused in
                    if focused {
                        focusedField = field
                        titleIsFocused = false
                    }
                    else if focusedField == field { focusedField = nil }
                }), minimumHeight: height, label: title(for: field))
                .frame(maxWidth: .infinity, minHeight: height)
        }
        .background(EditorColors.wash, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func renderedPreview(source: String, field: ComposeField, minHeight: CGFloat) -> some View {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Markdown 与公式会随输入显示")
                .font(.system(size: 11)).foregroundStyle(EditorColors.faint)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .padding(.top, 10)
        } else {
            MarkdownPreviewView(source: field == .progress ? IssueChecklistSupport.progressDisplaySource(source) : source)
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
                .accessibilityLabel("\(title(for: field))实时预览")
        }
    }

    private func title(for field: ComposeField) -> String {
        switch field {
        case .title: "记录标题"
        case .progress: "进展记录"
        case .issues: "待解决问题"
        case .ideas: "Idea"
        }
    }

    private var currentDraft: EntryDraft {
        EntryDraft(
            title: title,
            date: date,
            progress: progress,
            progressPercent: Int(progressPercent),
            progressText: progressText,
            issuesText: issuesText,
            ideasText: ideasText,
            showProgress: showProgress,
            showIssues: showIssues,
            showIdeas: showIdeas,
            references: references
        )
    }

    private func save() {
        guard canSave else { return }
        var draft = currentDraft
        draft.title = resolvedTitle
        let succeeded = onSave(draft)
        if succeeded {
            saveError = nil
            closeEditor()
        } else {
            saveError = "保存失败，本次输入和待用引用已保留。请检查存储空间与访问权限后重试。"
        }
    }

    private func closeEditor() {
        if let onCancel { onCancel() } else { dismiss() }
    }
}

enum EntryEditorSupport {
    static func title(explicit: String, progress: String, issues: String, ideas: String) -> String {
        let entered = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        let lines = [progress, issues, ideas].flatMap { $0.components(separatedBy: .newlines) }
        for line in lines {
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.hasPrefix("```"), !value.hasPrefix("~~~") else { continue }
            value = value.replacingOccurrences(of: #"^(?:#{1,6}\s+|>\s*|(?:[-*+]|\d+[.)])\s+(?:\[[ xX]\]\s*)?)"#, with: "", options: .regularExpression)
            for marker in ["**", "__", "`"] { value = value.replacingOccurrences(of: marker, with: "") }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return String(value.prefix(36)) }
        }
        return "新的记录"
    }
}

enum TimelineEditorLayout {
    // Keep roughly four blank lines available below the last line of text.
    static let writingSpace: CGFloat = 64
    static let inset: CGFloat = 12
}

#if os(macOS)
final class TimelineEditorTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }

    static func make() -> TimelineEditorTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        let view = TimelineEditorTextView(frame: .zero, textContainer: container)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = NSColor(EditorColors.secondaryInk)
        view.textContainerInset = NSSize(width: TimelineEditorLayout.inset, height: TimelineEditorLayout.inset)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        // NSTextView's initializer configures its container again. Apply these
        // after initialization so measuring a proposed width uses that width.
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        return view
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 0 }
        textContainer.containerSize = NSSize(width: max(1, width - 2 * textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(layoutManager.usedRect(for: textContainer).maxY,
                   layoutManager.extraLineFragmentRect.maxY,
                   layoutManager.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)))
    }

    func fittingHeight(for width: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, ceil(contentHeight(for: width) + 2 * textContainerInset.height + TimelineEditorLayout.writingSpace))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged {
            textContainer?.containerSize = NSSize(width: max(1, newSize.width - 2 * textContainerInset.width), height: CGFloat.greatestFiniteMagnitude)
        }
    }
}

struct TimelineGrowingTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var minimumHeight: CGFloat
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> TimelineEditorTextView {
        let view = TimelineEditorTextView.make()
        view.delegate = context.coordinator
        view.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.parent.isFocused = focused
        }
        view.setAccessibilityLabel(label)
        return view
    }

    func updateNSView(_ view: TimelineEditorTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text && !view.hasMarkedText() { view.string = text }
        view.setAccessibilityLabel(label)
        if isFocused && view.window?.firstResponder !== view {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, coordinator?.parent.isFocused == true else { return }
                view.window?.makeFirstResponder(view)
            }
        } else if !isFocused && view.window?.firstResponder === view {
            view.window?.makeFirstResponder(nil)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineEditorTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.fittingHeight(for: width, minimum: minimumHeight))
    }

    static func dismantleNSView(_ view: TimelineEditorTextView, coordinator: Coordinator) {
        view.delegate = nil
        view.onFocusChange = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TimelineGrowingTextEditor
        init(_ parent: TimelineGrowingTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TimelineEditorTextView else { return }
            parent.text = view.string
            view.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window?.firstResponder === view else { return }
                view.scrollRangeToVisible(view.selectedRange())
            }
        }
    }
}
#else
final class TimelineEditorTextView: UITextView {
    static func make() -> TimelineEditorTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        let view = TimelineEditorTextView(frame: .zero, textContainer: container)
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = UIColor(EditorColors.secondaryInk)
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        return view
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        textContainer.size = CGSize(width: max(1, width - textContainerInset.left - textContainerInset.right), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(layoutManager.usedRect(for: textContainer).maxY,
                   layoutManager.extraLineFragmentRect.maxY,
                   font?.lineHeight ?? 16)
    }

    func fittingHeight(for width: CGFloat, minimum: CGFloat) -> CGFloat {
        max(minimum, ceil(contentHeight(for: width) + textContainerInset.top + textContainerInset.bottom + TimelineEditorLayout.writingSpace))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textContainer.size = CGSize(width: max(1, bounds.width - textContainerInset.left - textContainerInset.right), height: CGFloat.greatestFiniteMagnitude)
    }

    func revealCaretInPage() {
        guard isFirstResponder, let selection = selectedTextRange, selection.isEmpty else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled {
                let caret = convert(caretRect(for: selection.end), to: scroll).insetBy(dx: 0, dy: -24)
                scroll.scrollRectToVisible(caret, animated: false)
                return
            }
            ancestor = view.superview
        }
    }
}

struct TimelineGrowingTextEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    var minimumHeight: CGFloat
    var label: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TimelineEditorTextView {
        let view = TimelineEditorTextView.make()
        view.delegate = context.coordinator
        view.accessibilityLabel = label
        return view
    }

    func updateUIView(_ view: TimelineEditorTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text && view.markedTextRange == nil { view.text = text }
        view.accessibilityLabel = label
        if isFocused && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
                guard let view, view.window != nil, coordinator?.parent.isFocused == true else { return }
                view.becomeFirstResponder()
            }
        } else if !isFocused && view.isFirstResponder { view.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: TimelineEditorTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 1, width.isFinite else { return nil }
        return CGSize(width: width, height: uiView.fittingHeight(for: width, minimum: minimumHeight))
    }

    static func dismantleUIView(_ view: TimelineEditorTextView, coordinator: Coordinator) { view.delegate = nil }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TimelineGrowingTextEditor
        init(_ parent: TimelineGrowingTextEditor) { self.parent = parent }
        func textViewDidBeginEditing(_ view: UITextView) { parent.isFocused = true }
        func textViewDidEndEditing(_ view: UITextView) { parent.isFocused = false }
        func textViewDidChange(_ view: UITextView) {
            parent.text = view.text
            view.invalidateIntrinsicContentSize()
            DispatchQueue.main.async { [weak view] in (view as? TimelineEditorTextView)?.revealCaretInPage() }
        }
        func textViewDidChangeSelection(_ view: UITextView) {
            guard view.markedTextRange == nil else { return }
            (view as? TimelineEditorTextView)?.revealCaretInPage()
        }
    }
}
#endif

private enum EditorColors {
    static let wash = Color(red: 0.965, green: 0.970, blue: 0.974)
    static let ink = Color(red: 0.18, green: 0.19, blue: 0.20)
    static let secondaryInk = Color(red: 0.32, green: 0.34, blue: 0.36)
    static let muted = Color(red: 0.55, green: 0.57, blue: 0.59)
    static let faint = Color(red: 0.70, green: 0.71, blue: 0.72)
    static let line = Color(red: 0.90, green: 0.91, blue: 0.92)
    static let accent = Color(red: 0.70, green: 0.38, blue: 0.30)
}
