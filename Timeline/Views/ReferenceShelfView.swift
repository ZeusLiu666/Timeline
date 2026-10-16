import SwiftUI

/// The shelf keeps selected passages available while browsing the same project.
/// It contains snapshots, so editing or deleting the source never breaks a quote.
struct ReferenceShelfView: View {
    @ObservedObject var interaction: ReferenceInteraction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var positions: [UUID: CGPoint] = [:]
    @State private var canvasFrame = CGRect.zero
    @State private var shelfFrame = CGRect.zero
    @State private var grabOffset = CGSize.zero
    @State private var inspectedReference: TimelineReference?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "quote.opening").font(.system(size: 12, weight: .medium))
                Text("引用").font(.system(size: 12, weight: .medium))
                Text("\(interaction.references.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer(minLength: 4)
                Button {
                    interaction.cancelDragging()
                    withAnimation(.easeInOut(duration: 0.2)) { interaction.isShelfVisible = false }
                } label: {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("收起引用区").help("收起引用区")
            }
            .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 4)

            if interaction.references.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("把过去的想法，带到现在。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text("选中历史记录中的文字，选择“引用”。\n将引用拖到一条记录，即可继续编辑。")
                        .font(.system(size: 11)).foregroundStyle(.tertiary).lineSpacing(4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(20).padding(.top, 16)
            } else {
                GeometryReader { viewport in
                    let references = interaction.references
                    let sizes = sizesForReferences(references, width: viewport.size.width)
                    let contentHeight = ReferenceShelfLayout.contentHeight(sizes: sizes, viewportHeight: viewport.size.height)
                    let bounds = CGSize(width: viewport.size.width, height: contentHeight)
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            ForEach(references) { reference in
                                if let size = sizes[reference.id], let position = positions[reference.id] {
                                    shelfBlock(reference, size: size)
                                        .position(position)
                                        .zIndex(interaction.draggingReference?.id == reference.id ? 2 : 0)
                                        .highPriorityGesture(dragGesture(for: reference, sizes: sizes, bounds: bounds))
                                }
                            }
                        }
                        .frame(width: viewport.size.width, height: contentHeight, alignment: .topLeading)
                        .background {
                            GeometryReader { canvas in
                                Color.clear
                                    .onChange(of: canvas.frame(in: .named(ReferenceInteraction.workspaceCoordinateSpace)), initial: true) { _, frame in
                                        canvasFrame = frame
                                    }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: references.map(\.id), initial: true) { _, _ in
                        refreshLayout(references: references, sizes: sizes, bounds: bounds)
                    }
                    .onChange(of: bounds) { _, newBounds in
                        refreshLayout(references: references, sizes: sizes, bounds: newBounds)
                    }
                }
            }
        }
        .background(Color.primary.opacity(0.025))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onChange(of: geometry.frame(in: .named(ReferenceInteraction.workspaceCoordinateSpace)), initial: true) { _, frame in
                        shelfFrame = frame
                        interaction.updateShelfFrame(frame)
                    }
            }
        }
        .onAppear { interaction.logDragDiagnostics("shelf-mounted", includeFrames: true) }
        .onDisappear {
            interaction.updateShelfFrame(nil)
            interaction.cancelDragging()
        }
        .popover(item: $inspectedReference, attachmentAnchor: .rect(.rect(previewAnchorRect)), arrowEdge: .top) { reference in
            ReferencePreviewView(reference: reference)
        }
        .accessibilityIdentifier("referenceShelf")
    }

    private var previewAnchorRect: CGRect {
        guard let reference = inspectedReference, let center = positions[reference.id] else { return .zero }
        let size = ReferenceShelfLayout.cardSize(for: reference, canvasWidth: canvasFrame.width)
        let rect = CGRect(
            x: canvasFrame.minX - shelfFrame.minX + center.x - size.width / 2,
            y: canvasFrame.minY - shelfFrame.minY + center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        // Use the visible part when a card is partly outside the scrolling area.
        let visible = rect.intersection(CGRect(origin: .zero, size: shelfFrame.size))
        return visible.isNull || visible.isEmpty ? rect : visible
    }

    private func shelfBlock(_ reference: TimelineReference, size: CGSize) -> some View {
        let dragging = interaction.draggingReference?.id == reference.id
        return ReferenceShelfBlock(
            reference: reference,
            isDragging: dragging,
            onRemove: { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { interaction.remove(reference) } }
        )
        .frame(width: size.width, height: size.height)
        .opacity(dragging && !interaction.isDraggingOverShelf ? 0.15 : 1)
        .onTapGesture { inspectedReference = reference }
        .contextMenu {
            Button("插入今日记录", systemImage: "text.badge.plus") { interaction.use(reference) }
            Button("查看引用", systemImage: "quote.bubble") { inspectedReference = reference }
            Button("删除引用", systemImage: "trash", role: .destructive) { interaction.remove(reference) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { inspectedReference = reference }
        .accessibilityLabel("待用引用，\(reference.sourceTitle)，\(reference.excerpt)")
        .accessibilityHint("可拖到时间线记录，或使用操作菜单插入今日记录")
        .accessibilityAction(named: Text("插入今日记录")) { interaction.use(reference) }
        .accessibilityAction(named: Text("查看引用")) { inspectedReference = reference }
        .accessibilityAction(named: Text("删除引用")) { interaction.remove(reference) }
    }

    private func dragGesture(
        for reference: TimelineReference,
        sizes: [UUID: CGSize],
        bounds: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named(ReferenceInteraction.workspaceCoordinateSpace))
            .onChanged { value in
                if interaction.draggingReference?.id != reference.id {
                    interaction.logDragDiagnostics("shelf-gesture-first-change", at: value.location, details: "start=\(value.startLocation) canvas=\(canvasFrame)", includeFrames: true)
                    if let center = positions[reference.id] {
                        grabOffset = CGSize(
                            width: center.x + canvasFrame.minX - value.startLocation.x,
                            height: center.y + canvasFrame.minY - value.startLocation.y
                        )
                    } else { grabOffset = .zero }
                    interaction.beginDragging(reference, at: value.location)
                } else {
                    interaction.updateDragging(to: value.location)
                }
                // Keep the block in its lane until the pointer leaves the shelf;
                // neighboring blocks move out of its way using a spring.
                guard canvasFrame.contains(value.location) else { return }
                var proposed = positions
                proposed[reference.id] = CGPoint(
                    x: value.location.x - canvasFrame.minX + grabOffset.width,
                    y: value.location.y - canvasFrame.minY + grabOffset.height
                )
                let separated = ReferenceShelfLayout.separatedPositions(proposed, sizes: sizes, bounds: bounds, movingID: reference.id)
                withAnimation(reduceMotion ? nil : .interactiveSpring(response: 0.22, dampingFraction: 0.85)) {
                    positions = separated
                }
            }
            .onEnded { value in
                interaction.logDragDiagnostics("shelf-gesture-ended", at: value.location, details: "start=\(value.startLocation) canvas=\(canvasFrame)", includeFrames: true)
                // Some synthesized short drags deliver a terminal value without
                // an onChanged callback. Resolve that complete gesture as well.
                if interaction.draggingReference?.id != reference.id {
                    let finalGrabOffset: CGSize
                    if let center = positions[reference.id] {
                        finalGrabOffset = CGSize(
                            width: center.x + canvasFrame.minX - value.startLocation.x,
                            height: center.y + canvasFrame.minY - value.startLocation.y
                        )
                    } else { finalGrabOffset = .zero }
                    interaction.beginDragging(reference, at: value.startLocation)
                    if canvasFrame.contains(value.location) {
                        var proposed = positions
                        proposed[reference.id] = CGPoint(
                            x: value.location.x - canvasFrame.minX + finalGrabOffset.width,
                            y: value.location.y - canvasFrame.minY + finalGrabOffset.height
                        )
                        let separated = ReferenceShelfLayout.separatedPositions(proposed, sizes: sizes, bounds: bounds, movingID: reference.id)
                        withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) { positions = separated }
                    }
                }
                interaction.endDragging(at: value.location)
                let separated = ReferenceShelfLayout.separatedPositions(positions, sizes: sizes, bounds: bounds)
                withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.85)) { positions = separated }
            }
    }

    private func sizesForReferences(_ references: [TimelineReference], width: CGFloat) -> [UUID: CGSize] {
        Dictionary(uniqueKeysWithValues: references.map { ($0.id, ReferenceShelfLayout.cardSize(for: $0, canvasWidth: width)) })
    }

    private func refreshLayout(references: [TimelineReference], sizes: [UUID: CGSize], bounds: CGSize) {
        let ids = Set(references.map(\.id))
        var proposed = positions.filter { ids.contains($0.key) }
        var bottom = proposed.map { id, center in center.y + (sizes[id]?.height ?? 0) / 2 }.max() ?? 0
        for reference in references where proposed[reference.id] == nil {
            let height = sizes[reference.id]?.height ?? 120
            let top = bottom == 0 ? ReferenceShelfLayout.padding : bottom + ReferenceShelfLayout.gap
            proposed[reference.id] = CGPoint(x: bounds.width / 2, y: top + height / 2)
            bottom = top + height
        }
        positions = ReferenceShelfLayout.separatedPositions(proposed, sizes: sizes, bounds: bounds)
    }
}

private struct ReferenceShelfBlock: View {
    let reference: TimelineReference
    var isDragging = false
    let onRemove: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var wiggles = false

    private var wiggleDuration: Double { 0.12 + Double(reference.id.uuid.0 % 4) * 0.01 }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) {
                Text(reference.sourceDate.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                    .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Image(systemName: "quote.opening").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(reference.sourceTitle.isEmpty ? "未命名记录" : reference.sourceTitle)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(reference.excerpt)
                .font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.8))
                .lineSpacing(3).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(ReferenceShelfColors.block)
                .shadow(color: .black.opacity(isDragging ? 0.08 : 0.035), radius: isDragging ? 10 : 4, y: 2)
        }
        .overlay(alignment: .topLeading) {
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 21, height: 21)
                    .background(ReferenceShelfColors.deleteButton, in: Circle())
            }
            .buttonStyle(.plain).offset(x: -7, y: -7)
            .accessibilityLabel("删除待用引用").help("删除引用")
        }
        .rotationEffect(.degrees(reduceMotion || isDragging ? 0 : (wiggles ? 1.4 : -1.4)))
        .offset(y: reduceMotion || isDragging ? 0 : (wiggles ? 0.35 : -0.35))
        .animation(reduceMotion || isDragging ? nil : .easeInOut(duration: wiggleDuration).repeatForever(autoreverses: true), value: wiggles)
        .onAppear { wiggles = true }
    }
}

/// Place this over the complete workspace. It never receives touches, so the
/// gesture continues to track its original block after leaving the right pane.
struct ReferenceDragOverlay: View {
    @ObservedObject var interaction: ReferenceInteraction

    var body: some View {
        GeometryReader { geometry in
            if let reference = interaction.draggingReference, !interaction.isDraggingOverShelf {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "quote.opening")
                        Text(reference.sourceTitle.isEmpty ? "引用" : reference.sourceTitle).lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Text(reference.excerpt).font(.system(size: 12)).lineLimit(3).lineSpacing(3)
                    if interaction.hoveredTarget != nil {
                        Label("松开以插入引用", systemImage: "arrow.down.to.line")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .padding(14).frame(width: 214, alignment: .leading)
                .background(ReferenceShelfColors.block, in: RoundedRectangle(cornerRadius: 11))
                .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                .scaleEffect(1.025)
                .position(
                    x: min(max(113, interaction.dragLocation.x), max(113, geometry.size.width - 113)),
                    y: min(max(70, interaction.dragLocation.y - 28), max(70, geometry.size.height - 70))
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum ReferenceShelfColors {
    #if os(macOS)
    static let block = Color(nsColor: .controlBackgroundColor)
    static let deleteButton = Color(nsColor: .windowBackgroundColor)
    #else
    static let block = Color(uiColor: .secondarySystemGroupedBackground)
    static let deleteButton = Color(uiColor: .tertiarySystemFill)
    #endif
}
