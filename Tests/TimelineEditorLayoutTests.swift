import AppKit
import SwiftUI

@main
@MainActor
struct TimelineEditorLayoutTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let native = TimelineEditorTextView.make()
        native.string = "短记录"
        let short = native.fittingHeight(for: 340, minimum: 144)
        precondition(short >= 144)
        let longText = (1...45).map { "- 第 \($0) 行：记录实际进展、保留 Markdown **内容** 与 $x^2$。" }.joined(separator: "\n") + "\n"
        native.string = longText
        let long = native.fittingHeight(for: 340, minimum: 144)
        let wide = native.fittingHeight(for: 760, minimum: 144)
        precondition(long > 900 && wide < long, "Real native wrapping must grow at narrow widths")
        precondition(long >= native.contentHeight(for: 340) + 24 + 64, "Every long record retains blank writing space")
        native.string = "缩短后\n"
        precondition(native.fittingHeight(for: 340, minimum: 144) < long, "Deleting text must shrink the editor")
        native.string = ""
        precondition(native.fittingHeight(for: 340, minimum: 144) == 144, "Empty editor retains its comfortable minimum")
        print("PASS: native wrapping, width changes, trailing newline, growth/shrinkage and 64-point writing space")

        let project = TimelineProject(name: "Isolated layout test")
        let entry = TimelineEntry(title: "Adaptive layout", progressText: longText,
                                  issuesText: "- [ ] 待解决的问题", ideasText: "留下一些灵感", project: project)
        let root = ScrollView {
            EntryEditorView(project: project, entry: entry, inline: true, onCancel: {}, onSave: { _ in true })
                .frame(maxWidth: .infinity)
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            for _ in 0..<12 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
        }
        func editors(in view: NSView) -> [TimelineEditorTextView] {
            (view as? TimelineEditorTextView).map { [$0] } ?? view.subviews.flatMap { editors(in: $0) }
        }
        settle()
        let fields = editors(in: host)
        precondition(fields.count == 3, "All three production sections must be mounted")
        for field in fields {
            precondition(field.frame.height >= field.contentHeight(for: field.bounds.width) + 24 + 64 - 1,
                         "Production SwiftUI layout must retain all text plus blank writing space")
            var ancestor = field.superview
            var scrollingAncestors = 0
            while let view = ancestor {
                if view is NSScrollView { scrollingAncestors += 1 }
                ancestor = view.superview
            }
            precondition(scrollingAncestors == 1, "Inline editing must scroll only with the outer page")
        }
        let narrowHeight = fields[0].frame.height
        window.makeFirstResponder(fields[0])
        settle()
        precondition(window.firstResponder === fields[0], "Native focus must survive SwiftUI updates before the first edit")
        window.setContentSize(NSSize(width: 960, height: 500))
        settle()
        let widened = editors(in: host)
        precondition(widened[0].frame.height < narrowHeight, "Production layout must remeasure after resizing")
        print("PASS: production inline editor, three sections, full text height, one page scroller, stable focus and window resizing")
        window.close()
    }
}
