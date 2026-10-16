import Combine
import Foundation
import SwiftUI

/// All coordinates used by the shelf, drag preview and record targets are in this
/// one workspace. A custom gesture keeps the same interaction on Mac and iPhone.
enum ReferenceDropTarget: Hashable {
    case entry(UUID)
    case today
}

struct ReferenceTargetFramesKey: PreferenceKey {
    static var defaultValue: [ReferenceDropTarget: CGRect] = [:]

    static func reduce(value: inout [ReferenceDropTarget: CGRect], nextValue: () -> [ReferenceDropTarget: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newer in newer })
    }
}

@MainActor
final class ReferenceInteraction: ObservableObject {
    static let workspaceCoordinateSpace = "timelineWorkspace"

    let project: TimelineProject
    private let store: TimelineStore

    @Published var isShelfVisible = false
    @Published private(set) var draggingReference: TimelineReference?
    @Published private(set) var dragLocation = CGPoint.zero
    @Published private(set) var hoveredTarget: ReferenceDropTarget?
    @Published private(set) var revision = 0
    @Published private(set) var focusRevision = 0
    private(set) var requestedFocusTarget: ReferenceDropTarget?

    /// Opening an editor is deliberately separate from consuming the pending
    /// reference: canceling the editor must leave the reference in the shelf.
    var onDrop: ((ReferenceDropTarget, TimelineReference) -> Void)?

    private var targetFrames: [ReferenceDropTarget: CGRect] = [:]
    private var shelfFrame: CGRect?
    private var workspaceBounds: CGRect?
    private var feedViewport: CGRect?
    private var lastDiagnosticMove: TimeInterval = 0

    init(project: TimelineProject, store: TimelineStore) {
        self.project = project
        self.store = store
    }

    var references: [TimelineReference] { project.pendingReferences }

    var isDraggingOverShelf: Bool {
        draggingReference != nil && (shelfFrame?.contains(dragLocation) ?? false)
    }

    @discardableResult
    func capture(text: String, from entry: TimelineEntry, source: String? = nil) -> TimelineReference? {
        let excerpt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty, !store.isRecoveryMode else { return nil }
        let context = ReferenceContextSupport.snapshot(
            excerpt: excerpt,
            sources: source.map { [$0] } ?? [entry.progressText, entry.issuesText, entry.ideasText]
        )
        if var existing = references.first(where: {
            $0.sourceEntryID == entry.id && $0.excerpt == excerpt &&
            (($0.contextBefore == context.before && $0.contextAfter == context.after) ||
             ($0.contextBefore.isEmpty && $0.contextAfter.isEmpty))
        }) {
            // A pending quote from an older app version can acquire context on
            // recapture, without replacing its ID or creating a duplicate block.
            if existing.contextBefore.isEmpty && existing.contextAfter.isEmpty &&
                (!context.before.isEmpty || !context.after.isEmpty) {
                existing.contextBefore = context.before
                existing.contextAfter = context.after
                var pending = project.pendingReferences
                if let index = pending.firstIndex(where: { $0.id == existing.id }) {
                    pending[index] = existing
                    project.pendingReferences = pending
                    revision &+= 1
                    store.save()
                }
            }
            isShelfVisible = true
            return existing
        }
        let reference = TimelineReference(
            id: UUID(),
            sourceEntryID: entry.id,
            sourceTitle: entry.title,
            sourceDate: entry.date,
            excerpt: excerpt,
            contextBefore: context.before,
            contextAfter: context.after,
            createdAt: .now
        )
        objectWillChange.send()
        var pending = project.pendingReferences
        pending.append(reference)
        project.pendingReferences = pending
        revision &+= 1
        store.save()
        isShelfVisible = true
        return reference
    }

    func remove(_ reference: TimelineReference) {
        guard !store.isRecoveryMode else { return }
        if draggingReference?.id == reference.id { cancelDragging() }
        objectWillChange.send()
        project.pendingReferences.removeAll { $0.id == reference.id }
        revision &+= 1
        store.save()
    }

    func use(_ reference: TimelineReference, on target: ReferenceDropTarget = .today) {
        guard !store.isRecoveryMode else { return }
        requestFocus(target)
        onDrop?(target, reference)
    }

    func updateTargets(_ frames: [ReferenceDropTarget: CGRect]) {
        targetFrames = frames.filter { !$0.value.isEmpty && !$0.value.isInfinite && !$0.value.isNull }
        if draggingReference != nil { updateHoveredTarget() }
    }

    func updateWorkspaceBounds(_ bounds: CGRect) {
        workspaceBounds = bounds
        if draggingReference != nil { updateHoveredTarget() }
    }

    func updateFeedViewport(_ frame: CGRect) {
        feedViewport = frame
        if draggingReference != nil {
            updateHoveredTarget()
            logDragDiagnostics("viewport-updated")
        }
    }

    func updateShelfFrame(_ frame: CGRect?) {
        shelfFrame = frame
        if draggingReference != nil { updateHoveredTarget() }
    }

    func beginDragging(_ reference: TimelineReference, at location: CGPoint) {
        guard !store.isRecoveryMode else { return }
        draggingReference = reference
        dragLocation = location
        updateHoveredTarget()
        lastDiagnosticMove = 0
        logDragDiagnostics("begin", includeFrames: true)
    }

    func updateDragging(to location: CGPoint) {
        guard draggingReference != nil else { return }
        dragLocation = location
        updateHoveredTarget()
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastDiagnosticMove > 0.15 {
            lastDiagnosticMove = now
            logDragDiagnostics("move")
        }
    }

    func endDragging(at location: CGPoint) {
        guard let reference = draggingReference else { return }
        dragLocation = location
        updateHoveredTarget()
        let destination = hoveredTarget
        logDragDiagnostics("end", includeFrames: true)
        cancelDragging()
        if let destination {
            requestFocus(destination)
            onDrop?(destination, reference)
        }
    }

    func cancelDragging() {
        if draggingReference != nil { logDragDiagnostics("reset") }
        draggingReference = nil
        hoveredTarget = nil
    }

    /// Temporary diagnostics are silent in normal use and never log excerpt text.
    /// They distinguish a canceled ScrollView gesture from an incorrect target frame.
    func logDragDiagnostics(_ event: String, at point: CGPoint? = nil, details: String = "", includeFrames: Bool = false) {
        guard ProcessInfo.processInfo.arguments.contains("--timeline-ui-testing") else { return }
        let location = point ?? dragLocation
        let rejection: String
        if let workspaceBounds, !workspaceBounds.contains(location) { rejection = "outside-workspace" }
        else if let feedViewport, !feedViewport.contains(location) { rejection = "outside-feed-viewport" }
        else if let shelfFrame, shelfFrame.contains(location) { rejection = "over-shelf" }
        else { rejection = hoveredTarget == nil ? "no-record-at-point" : "accepted" }
        var message = "[TimelineReferenceDrag] \(event) point=\(location) ref=\(draggingReference?.id.uuidString ?? "nil") hover=\(String(describing: hoveredTarget)) reason=\(rejection) \(details)"
        if includeFrames {
            let frames = targetFrames.map { "\($0.key):\($0.value)" }.sorted().joined(separator: "; ")
            message += " workspace=\(String(describing: workspaceBounds)) viewport=\(String(describing: feedViewport)) shelf=\(String(describing: shelfFrame)) targets=[\(frames)]"
        }
        NSLog("%@", message)
    }

    private func requestFocus(_ target: ReferenceDropTarget) {
        requestedFocusTarget = target
        focusRevision &+= 1
    }

    private func updateHoveredTarget() {
        if let workspaceBounds, !workspaceBounds.contains(dragLocation) {
            hoveredTarget = nil
            return
        }
        // Lazy rows may retain frames outside the scroll view's clipped area.
        // Never accept those hidden portions beneath the header or toolbar.
        if let feedViewport, !feedViewport.contains(dragLocation) {
            hoveredTarget = nil
            return
        }
        if let shelfFrame, shelfFrame.contains(dragLocation) {
            hoveredTarget = nil
            return
        }
        // Prefer the smaller target if layouts briefly overlap during a focus
        // animation. This also avoids a large stale row stealing a precise drop.
        hoveredTarget = targetFrames
            .filter { $0.value.contains(dragLocation) }
            .min { $0.value.width * $0.value.height < $1.value.width * $1.value.height }?
            .key
    }
}

/// A deterministic separation solver. The narrow shelf forms one vertical lane;
/// a dragged block pushes its neighbors with a fixed gap instead of overlapping
/// them. Horizontal positions remain independently movable within the shelf.
enum ReferenceShelfLayout {
    static let padding: CGFloat = 18
    static let gap: CGFloat = 18

    static func cardSize(for reference: TimelineReference, canvasWidth: CGFloat) -> CGSize {
        let width = min(216, max(130, canvasWidth - 64))
        let approximateCharactersPerLine = max(12, Int((width - 30) / 7))
        let lines = min(4, max(2, Int(ceil(Double(reference.excerpt.count) / Double(approximateCharactersPerLine)))))
        return CGSize(width: width, height: CGFloat(76 + lines * 17))
    }

    static func contentHeight(sizes: [UUID: CGSize], viewportHeight: CGFloat) -> CGFloat {
        max(viewportHeight, padding * 2 + sizes.values.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * gap + gap * 4)
    }

    static func initialPositions(references: [TimelineReference], sizes: [UUID: CGSize], width: CGFloat) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        var top = padding
        for reference in references {
            guard let size = sizes[reference.id] else { continue }
            positions[reference.id] = CGPoint(x: width / 2, y: top + size.height / 2)
            top += size.height + gap
        }
        return positions
    }

    static func separatedPositions(
        _ proposed: [UUID: CGPoint],
        sizes: [UUID: CGSize],
        bounds: CGSize,
        movingID: UUID? = nil
    ) -> [UUID: CGPoint] {
        let ordered = sizes.keys.sorted {
            let left = proposed[$0]?.y ?? 0
            let right = proposed[$1]?.y ?? 0
            if abs(left - right) > 0.01 { return left < right }
            return $0.uuidString < $1.uuidString
        }
        guard !ordered.isEmpty else { return [:] }
        let anchor = movingID.flatMap { ordered.firstIndex(of: $0) } ?? 0
        let heights = ordered.map { sizes[$0]!.height }
        let requiredHeight = padding * 2 + heights.reduce(0, +) + CGFloat(max(0, ordered.count - 1)) * gap
        let height = max(bounds.height, requiredHeight)
        var result: [UUID: CGPoint] = [:]

        func minimumCenter(_ index: Int) -> CGFloat {
            padding + heights.prefix(index).reduce(0, +) + CGFloat(index) * gap + heights[index] / 2
        }
        func maximumCenter(_ index: Int) -> CGFloat {
            let after = ordered.count - index - 1
            return height - padding - heights.suffix(after).reduce(0, +) - CGFloat(after) * gap - heights[index] / 2
        }
        func position(_ index: Int, y: CGFloat) -> CGPoint {
            let id = ordered[index]
            let width = sizes[id]!.width
            let minX = padding + width / 2
            let maxX = max(minX, bounds.width - padding - width / 2)
            return CGPoint(x: min(maxX, max(minX, proposed[id]?.x ?? bounds.width / 2)), y: y)
        }

        let anchorY = min(maximumCenter(anchor), max(minimumCenter(anchor), proposed[ordered[anchor]]?.y ?? minimumCenter(anchor)))
        result[ordered[anchor]] = position(anchor, y: anchorY)
        if anchor > 0 {
            for index in stride(from: anchor - 1, through: 0, by: -1) {
                let nextY = result[ordered[index + 1]]!.y
                let upper = nextY - heights[index + 1] / 2 - gap - heights[index] / 2
                let desired = proposed[ordered[index]]?.y ?? minimumCenter(index)
                let y = min(upper, max(minimumCenter(index), desired))
                result[ordered[index]] = position(index, y: y)
            }
        }
        if anchor + 1 < ordered.count {
            for index in (anchor + 1)..<ordered.count {
                let previousY = result[ordered[index - 1]]!.y
                let lower = previousY + heights[index - 1] / 2 + gap + heights[index] / 2
                let desired = proposed[ordered[index]]?.y ?? minimumCenter(index)
                let y = max(lower, min(maximumCenter(index), desired))
                result[ordered[index]] = position(index, y: y)
            }
        }
        return result
    }
}

/// Context is captured once, rather than reconstructed from a future edited or
/// deleted source. Matching uses a readable projection so Markdown and KaTeX's
/// ordinary text selection can still be located without guessing unrelated text.
enum ReferenceContextSupport {
    struct Snapshot: Equatable {
        var before: String = ""
        var after: String = ""
    }

    static func snapshot(excerpt: String, sources: [String], limit: Int = 110) -> Snapshot {
        let selected = readableMarkdown(excerpt).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return Snapshot() }
        let readableSources = sources.map(readableMarkdown)
        for source in readableSources {
            if let range = source.range(of: selected) { return surrounding(range, in: source, limit: limit) }
        }
        let needle = projection(selected).text
        guard !needle.isEmpty else { return Snapshot() }
        for source in readableSources {
            let normalized = projection(source)
            guard let match = normalized.text.range(of: needle) else { continue }
            let first = normalized.text.distance(from: normalized.text.startIndex, to: match.lowerBound)
            let last = normalized.text.distance(from: normalized.text.startIndex, to: match.upperBound) - 1
            guard normalized.indices.indices.contains(first), normalized.indices.indices.contains(last) else { continue }
            let range = normalized.indices[first]..<source.index(after: normalized.indices[last])
            return surrounding(range, in: source, limit: limit)
        }
        // An excerpt may contain layout text copied from a complex equation.
        // Keep it intact, but do not attach context from an uncertain location.
        return Snapshot()
    }

    private static func surrounding(_ range: Range<String.Index>, in source: String, limit: Int) -> Snapshot {
        let count = max(0, limit)
        let before = source[..<range.lowerBound]
        let after = source[range.upperBound...]
        return Snapshot(
            before: (before.count > count ? "…" : "") + String(before.suffix(count)),
            after: String(after.prefix(count)) + (after.count > count ? "…" : "")
        )
    }

    static func readableMarkdown(_ source: String) -> String {
        var value = source
        value = replacing(#"(?m)^[ \t]*(?:```|~~~).*$"#, in: value, with: "")
        value = replacing(#"!?\[([^\]]*)\]\([^\)]+\)"#, in: value, with: "$1")
        value = replacing(#"(?m)^[ \t]*(?:#{1,6}[ \t]+|>[ \t]*|[-*+][ \t]+(?:\[[ xX]\][ \t]*)?|[0-9]+[.)][ \t]+)"#, in: value, with: "")
        value = replacing(#"</?[A-Za-z][^>]*>"#, in: value, with: "")
        for marker in ["**", "__", "~~", "`", "\\(", "\\)", "\\[", "\\]", "$$", "$"] {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = replacing(#"(?<!\w)\*([^*\n]+)\*(?!\w)"#, in: value, with: "$1")
        value = replacing(#"(?<!\w)_([^_\n]+)_(?!\w)"#, in: value, with: "$1")
        let mathCommands = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "theta": "θ",
            "lambda": "λ", "mu": "μ", "pi": "π", "rho": "ρ", "sigma": "σ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Sigma": "Σ", "Omega": "Ω",
            "times": "×", "cdot": "·", "pm": "±", "leq": "≤", "geq": "≥", "neq": "≠", "infty": "∞",
            "sqrt": "√", "frac": "", "dfrac": "", "tfrac": "", "mathrm": "", "mathbf": "",
            "mathit": "", "mathsf": "", "text": "", "operatorname": "", "left": "", "right": ""
        ]
        for (command, replacement) in mathCommands {
            value = replacing("\\\\" + command + #"\b"#, in: value, with: replacement)
        }
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "), ("&quot;", "\"")] {
            value = value.replacingOccurrences(of: entity, with: character)
        }
        return value
    }

    private static func projection(_ source: String) -> (text: String, indices: [String.Index]) {
        var text = ""
        var indices: [String.Index] = []
        let ignored = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\\^_{}$`*"))
        for index in source.indices {
            let folded = String(source[index]).precomposedStringWithCompatibilityMapping.lowercased()
            for character in folded {
                guard !character.unicodeScalars.allSatisfy({ ignored.contains($0) }) else { continue }
                text.append(character)
                indices.append(index)
            }
        }
        return (text, indices)
    }

    private static func replacing(_ pattern: String, in source: String, with template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return source }
        return expression.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: template)
    }
}
