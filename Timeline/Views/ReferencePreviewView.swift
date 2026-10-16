import SwiftUI

/// A small source snapshot: surrounding text recedes while the quoted passage
/// stays readable. Both pending and attached quotes use the same presentation.
struct ReferencePreviewView: View {
    let reference: TimelineReference

    private var previewWidth: CGFloat {
        #if os(iOS)
        260
        #else
        350
        #endif
    }

    private var contextColor: Color { Color(white: 0.62) }
    private var quoteColor: Color { Color(white: 0.12) }
    private var before: String { reference.contextBefore.count > 70 ? "…" + reference.contextBefore.suffix(70) : reference.contextBefore }
    private var after: String { reference.contextAfter.count > 70 ? String(reference.contextAfter.prefix(70)) + "…" : reference.contextAfter }
    private var hasMath: Bool {
        reference.excerpt.contains("$") || reference.excerpt.contains("\\(") || reference.excerpt.contains("\\[")
            || reference.excerpt.range(of: "(?im)^\\s*```(?:math|latex|tex|katex)\\s*$", options: .regularExpression) != nil
    }

    private var contentHeight: CGFloat {
        let source = reference.contextBefore + reference.excerpt + reference.contextAfter
        let columns = Double(max(18, (previewWidth - 38) / 7))
        let lines = source.components(separatedBy: "\n").reduce(0.0) { total, paragraph in
            let widthUnits = paragraph.reduce(0.0) { units, character in
                units + (character.unicodeScalars.allSatisfy { $0.isASCII } ? 1 : 1.8)
            }
            return total + max(1, ceil(widthUnits / columns))
        }
        return min(290, max(hasMath ? 115 : 64, CGFloat(lines) * 24 + (hasMath ? 30 : 0)))
    }

    private var continuousPassage: Text {
        let quoted = (try? AttributedString(markdown: reference.excerpt,
                                           options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(reference.excerpt)
        return Text(before).foregroundColor(contextColor)
            + Text(quoted).foregroundColor(quoteColor)
            + Text(after).foregroundColor(contextColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(reference.sourceTitle.isEmpty ? "未命名记录" : reference.sourceTitle)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(quoteColor).lineLimit(2)
                    Text(reference.sourceDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute()))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(contextColor)
                }
                Spacer(minLength: 0)
                Image(systemName: "quote.opening").font(.system(size: 13)).foregroundStyle(contextColor.opacity(0.7))
                    .padding(.top, 2)
            }
            if !hasMath && reference.excerpt.count <= 240 {
                continuousPassage.font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
              ScrollView {
                Group {
                    if hasMath {
                        VStack(alignment: .leading, spacing: 5) {
                            if !reference.contextBefore.isEmpty {
                                Text(before).foregroundStyle(contextColor)
                            }
                            MarkdownText(source: reference.excerpt)
                                .foregroundStyle(quoteColor).frame(maxWidth: .infinity, alignment: .leading)
                            if !reference.contextAfter.isEmpty {
                                Text(after).foregroundStyle(contextColor)
                            }
                        }
                        .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                    } else {
                        continuousPassage.font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
              .scrollIndicators(.visible).frame(height: contentHeight)
            }
        }
        .padding(19)
        #if os(iOS)
        .frame(idealWidth: previewWidth, maxWidth: previewWidth, alignment: .leading)
        #else
        .frame(width: previewWidth, alignment: .leading)
        #endif
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("referenceContextPreview")
    }
}
