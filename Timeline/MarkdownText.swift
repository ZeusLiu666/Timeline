import SwiftUI

/// Saved records use the same offline renderer as the live editor preview.
struct MarkdownText: View {
    let source: String
    var onDoubleClick: (() -> Void)?
    var onQuote: ((String) -> Void)?

    init(source: String, onDoubleClick: (() -> Void)? = nil, onQuote: ((String) -> Void)? = nil) {
        self.source = source
        self.onDoubleClick = onDoubleClick
        self.onQuote = onQuote
    }

    init(_ source: String, onDoubleClick: (() -> Void)? = nil, onQuote: ((String) -> Void)? = nil) {
        self.init(source: source, onDoubleClick: onDoubleClick, onQuote: onQuote)
    }

    var body: some View {
        MarkdownPreviewView(source: source, onDoubleClick: onDoubleClick, onQuote: onQuote)
    }
}
