import Foundation
import SwiftUI
import WebKit
#if os(iOS)
import UIKit
#endif

private struct MarkdownLayoutWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var markdownLayoutWidth: CGFloat {
        get { self[MarkdownLayoutWidthKey.self] }
        set { self[MarkdownLayoutWidthKey.self] = newValue }
    }
}

enum MarkdownPreviewSupport {
    static func containsMath(_ source: String) -> Bool {
        source.contains("$") || source.contains("\\(") || source.contains("\\[")
            || source.range(of: "(?im)^\\s*```(?:math|latex|tex|katex)\\s*$", options: .regularExpression) != nil
    }

    static func needsRichRendering(_ source: String) -> Bool {
        containsMath(source) || source.contains("```") || source.contains("~~~")
            || source.range(of: "(?m)^\\s*\\|?.+\\|.+\\n\\s*\\|?\\s*:?-{3,}", options: .regularExpression) != nil
    }
}

/// Bundled Markdown + KaTeX, without network dependencies or nested vertical scroll.
struct MarkdownPreviewView: View {
    let source: String
    var onDoubleClick: (() -> Void)?
    var onQuote: ((String) -> Void)?

    @State private var measuredHeight: CGFloat?
    @State private var renderingError: String?
    @State private var quoteCandidate: MarkdownQuoteCandidate?
    @Environment(\.openURL) private var openURL
    @Environment(\.markdownLayoutWidth) private var layoutWidth

    init(source: String, onDoubleClick: (() -> Void)? = nil, onQuote: ((String) -> Void)? = nil) {
        self.source = source
        self.onDoubleClick = onDoubleClick
        self.onQuote = onQuote
    }

    var body: some View {
        Group {
            if let indexURL = MarkdownPreviewResources.indexURL, renderingError == nil {
                MarkdownWebView(source: source, indexURL: indexURL, widthHint: layoutWidth,
                                height: Binding(get: { resolvedHeight }, set: { measuredHeight = $0 }),
                                renderingError: $renderingError, quoteCandidate: $quoteCandidate, onDoubleClick: onDoubleClick, onQuote: onQuote,
                                onOpenURL: { openURL($0) })
                    .frame(height: resolvedHeight)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(renderingError ?? "Markdown 预览资源缺失，暂时显示原文。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(verbatim: source).font(.system(size: 14)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(item: $quoteCandidate, attachmentAnchor: .rect(.rect(quoteCandidate?.rect ?? .zero)), arrowEdge: .bottom) { candidate in
            Button {
                onQuote?(candidate.text)
                quoteCandidate = nil
            } label: {
                Label("引用到右侧", systemImage: "quote.bubble")
                    .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 9)
            }
            .buttonStyle(.plain)
            #if os(iOS)
            .presentationCompactAdaptation(.popover)
            #endif
        }
    }

    private var resolvedHeight: CGFloat {
        measuredHeight ?? MarkdownRenderCache.height(for: source, width: layoutWidth) ?? 32
    }
}

fileprivate struct MarkdownQuoteCandidate: Identifiable {
    let id = UUID()
    let text: String
    let rect: CGRect
}

enum MarkdownPreviewResources {
    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Markdown")
    }
}

#if os(macOS)
private struct MarkdownWebView: NSViewRepresentable {
    let source: String
    let indexURL: URL
    let widthHint: CGFloat
    @Binding var height: CGFloat
    @Binding var renderingError: String?
    @Binding var quoteCandidate: MarkdownQuoteCandidate?
    var onDoubleClick: (() -> Void)?
    var onQuote: ((String) -> Void)?
    var onOpenURL: (URL) -> Void

    func makeCoordinator() -> MarkdownWebCoordinator {
        MarkdownRenderCache.acquire(source: source, height: $height, renderingError: $renderingError, quoteCandidate: $quoteCandidate)
    }
    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(indexURL: indexURL, widthHint: widthHint)
    }
    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(source: source, onDoubleClick: onDoubleClick, onQuote: onQuote, onOpenURL: onOpenURL)
    }
    static func dismantleNSView(_ webView: WKWebView, coordinator: MarkdownWebCoordinator) {
        MarkdownRenderCache.release(coordinator)
    }
}

private final class TimelineMarkdownWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}
#else
private struct MarkdownWebView: UIViewRepresentable {
    let source: String
    let indexURL: URL
    let widthHint: CGFloat
    @Binding var height: CGFloat
    @Binding var renderingError: String?
    @Binding var quoteCandidate: MarkdownQuoteCandidate?
    var onDoubleClick: (() -> Void)?
    var onQuote: ((String) -> Void)?
    var onOpenURL: (URL) -> Void

    func makeCoordinator() -> MarkdownWebCoordinator {
        MarkdownRenderCache.acquire(source: source, height: $height, renderingError: $renderingError, quoteCandidate: $quoteCandidate)
    }
    func makeUIView(context: Context) -> WKWebView {
        context.coordinator.makeWebView(indexURL: indexURL, widthHint: widthHint)
    }
    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(source: source, onDoubleClick: onDoubleClick, onQuote: onQuote, onOpenURL: onOpenURL)
    }
    static func dismantleUIView(_ webView: WKWebView, coordinator: MarkdownWebCoordinator) {
        MarkdownRenderCache.release(coordinator)
    }
}
#endif

/// Keep a small number of fully loaded documents, rather than rebuilding WebKit
/// and parsing KaTeX whenever a timestamp is expanded. Only idle views are reused.
@MainActor
enum MarkdownRenderCache {
    private static let capacity = 8
    private static var idle: [MarkdownWebCoordinator] = []
    private static var ruleTask: Task<WKContentRuleList, Error>?
    fileprivate static let dataStore = WKWebsiteDataStore.nonPersistent()
    #if os(iOS)
    private static var memoryObserver: NSObjectProtocol?
    #endif

    static func height(for source: String, width: CGFloat) -> CGFloat? {
        guard width > 40 else { return nil }
        return idle.last { $0.matches(source) && abs($0.measuredWidth - width) < 1 }?.cachedHeight
    }

    fileprivate static func acquire(source: String, height: Binding<CGFloat>, renderingError: Binding<String?>,
                                    quoteCandidate: Binding<MarkdownQuoteCandidate?>) -> MarkdownWebCoordinator {
        let coordinator: MarkdownWebCoordinator
        if let index = idle.lastIndex(where: { $0.matches(source) }) {
            coordinator = idle.remove(at: index)
        } else {
            coordinator = MarkdownWebCoordinator(height: height, renderingError: renderingError, quoteCandidate: quoteCandidate)
        }
        coordinator.attach(height: height, renderingError: renderingError, quoteCandidate: quoteCandidate)
        return coordinator
    }

    fileprivate static func release(_ coordinator: MarkdownWebCoordinator) {
        coordinator.detach()
        guard coordinator.isReusable else { coordinator.tearDown(); return }
        idle.append(coordinator)
        trim()
    }

    /// Prepare just the nearby records after the active card has appeared.
    /// Cancellation stops work immediately when focus or the project changes.
    struct Document: Equatable, Hashable {
        let source: String
        let width: Int
    }

    static func preload(sources: [String], width: CGFloat) async {
        await preload(documents: sources.map { Document(source: $0, width: Int(width)) })
    }

    static func preload(documents: [Document]) async {
        guard let indexURL = MarkdownPreviewResources.indexURL else { return }
        #if os(iOS)
        if memoryObserver == nil {
            memoryObserver = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in
                    idle.forEach { $0.tearDown() }
                    idle.removeAll()
                }
            }
        }
        #endif
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        var seen = Set<Document>()
        for document in documents where !document.source.isEmpty && document.width > 40 && seen.insert(document).inserted {
            guard !Task.isCancelled else { return }
            if seen.count > 6 { return }
            if let cached = idle.last(where: { $0.matches(document.source) }) {
                cached.resizeForPreload(width: CGFloat(document.width))
                continue
            }
            let coordinator = MarkdownWebCoordinator(height: .constant(32), renderingError: .constant(nil), quoteCandidate: .constant(nil))
            coordinator.prepare(source: document.source, width: CGFloat(document.width), indexURL: indexURL)
            idle.append(coordinator)
            trim()
            // Avoid starting all WebKit documents in the same display frame.
            do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            if seen.count >= 6 { break }
        }
    }

    private static func trim() {
        while idle.count > capacity { idle.removeFirst().tearDown() }
    }

    fileprivate static func offlineRules() async throws -> WKContentRuleList {
        if let ruleTask { return try await ruleTask.value }
        let task = Task<WKContentRuleList, Error> { @MainActor in
            try await withCheckedThrowingContinuation { continuation in
                let rules = """
                [{"trigger":{"url-filter":"^https?:"},"action":{"type":"block"}},
                 {"trigger":{"url-filter":"^wss?:"},"action":{"type":"block"}},
                 {"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]
                """
                WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "TimelineMarkdownOffline.v2", encodedContentRuleList: rules) { list, error in
                    if let list { continuation.resume(returning: list) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                }
            }
        }
        ruleTask = task
        do { return try await task.value }
        catch { ruleTask = nil; throw error }
    }
}

@MainActor
fileprivate final class MarkdownWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Binding private var height: CGFloat
    @Binding private var renderingError: String?
    @Binding private var quoteCandidate: MarkdownQuoteCandidate?
    private var pendingQuotePopup: Task<Void, Never>?
    private var quoteWasPresented = false
    private var webView: WKWebView?
    private var pendingRender: Task<Void, Never>?
    private var pendingHeightSync: Task<Void, Never>?
    private var source = ""
    private var loaded = false
    private var lastRenderedSource: String?
    private var lastDoubleClickEnabled: Bool?
    private var lastQuoteEnabled: Bool?
    private var onDoubleClick: (() -> Void)?
    private var onQuote: ((String) -> Void)?
    private var onOpenURL: ((URL) -> Void)?
    private var isAttached = true
    private var isDisposed = false
    private var hasFailed = false
    private(set) var cachedHeight: CGFloat = 32
    private(set) var measuredWidth: CGFloat = 0
    var isReusable: Bool { !isDisposed && !hasFailed && webView != nil }
    #if os(iOS)
    private var quoteLongPressRecognizer: UILongPressGestureRecognizer?
    private var pendingNativeQuote: Task<Void, Never>?
    #endif

    init(height: Binding<CGFloat>, renderingError: Binding<String?>, quoteCandidate: Binding<MarkdownQuoteCandidate?>) {
        self._height = height
        self._renderingError = renderingError
        self._quoteCandidate = quoteCandidate
    }

    func makeWebView(indexURL: URL, widthHint: CGFloat = 0) -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = MarkdownRenderCache.dataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(WeakMarkdownMessageHandler(self), name: "timelineMarkdown")
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        #if os(macOS)
        let view = TimelineMarkdownWebView(frame: .zero, configuration: configuration)
        #else
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.showsHorizontalScrollIndicator = false
        let quotePress = UILongPressGestureRecognizer(target: self, action: #selector(prepareNativeQuote(_:)))
        quotePress.minimumPressDuration = 0.5
        quotePress.cancelsTouchesInView = false
        quotePress.delaysTouchesBegan = false
        quotePress.delaysTouchesEnded = false
        quotePress.delegate = self
        view.addGestureRecognizer(quotePress)
        quoteLongPressRecognizer = quotePress
        #endif
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = false
        self.webView = view
        if widthHint > 40 { view.frame.size.width = widthHint }

        // Compile once; concurrent documents await the same local rule list.
        Task { @MainActor [weak self, weak view] in
            do {
                let list = try await MarkdownRenderCache.offlineRules()
                guard let self, !self.isDisposed, let view else { return }
                view.configuration.userContentController.add(list)
                view.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
            } catch {
                self?.fail("无法初始化离线预览：\(error.localizedDescription)")
            }
        }
        return view
    }

    func matches(_ source: String) -> Bool { self.source == source && isReusable }

    func attach(height: Binding<CGFloat>, renderingError: Binding<String?>, quoteCandidate: Binding<MarkdownQuoteCandidate?>) {
        self._height = height
        self._renderingError = renderingError
        self._quoteCandidate = quoteCandidate
        isAttached = true
    }

    func prepare(source: String, width: CGFloat, indexURL: URL) {
        isAttached = false
        self.source = source
        // The timeline enables both actions. Using the same flags keeps a
        // prepared document intact when it is attached to the visible card.
        onDoubleClick = {}
        onQuote = { _ in }
        makeWebView(indexURL: indexURL, widthHint: width).frame = CGRect(x: 0, y: 0, width: width, height: 32)
    }

    func resizeForPreload(width: CGFloat) {
        guard !isAttached, let webView, abs(webView.frame.width - width) > 0.5 else { return }
        webView.frame.size.width = width
        if loaded { webView.evaluateJavaScript("window.TimelineMarkdown.measureHeight();", completionHandler: nil) }
    }

    func detach() {
        isAttached = false
        pendingRender?.cancel()
        pendingHeightSync?.cancel()
        pendingQuotePopup?.cancel()
        #if os(iOS)
        pendingNativeQuote?.cancel()
        #endif
        quoteWasPresented = false
        onDoubleClick = nil
        onQuote = nil
        onOpenURL = nil
        _height = .constant(cachedHeight)
        _renderingError = .constant(nil)
        _quoteCandidate = .constant(nil)
        if loaded {
            webView?.evaluateJavaScript("window.TimelineMarkdown.dismissQuote(); window.getSelection()?.removeAllRanges();", completionHandler: nil)
        }
    }

    func update(source: String, onDoubleClick: (() -> Void)?, onQuote: ((String) -> Void)?, onOpenURL: @escaping (URL) -> Void) {
        if quoteWasPresented && quoteCandidate == nil {
            quoteWasPresented = false
            webView?.evaluateJavaScript("window.TimelineMarkdown.dismissQuote();", completionHandler: nil)
        }
        self.source = source
        self.onDoubleClick = onDoubleClick
        self.onQuote = onQuote
        self.onOpenURL = onOpenURL
        if loaded {
            scheduleRender()
            pendingHeightSync?.cancel()
            pendingHeightSync = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled, let self, self.isAttached, let view = self.webView else { return }
                if abs(self.measuredWidth - view.frame.width) < 1 {
                    if abs(self.height - self.cachedHeight) > 0.5 { self.height = self.cachedHeight }
                } else {
                    view.evaluateJavaScript("window.TimelineMarkdown.measureHeight();", completionHandler: nil)
                }
            }
        }
    }

    #if os(iOS)
    @objc private func prepareNativeQuote(_ recognizer: UILongPressGestureRecognizer) {
        guard onQuote != nil, loaded, let webView else { return }
        guard recognizer.state == .began || recognizer.state == .ended else { return }
        let point = recognizer.location(in: webView)
        let preservePending = recognizer.state == .ended
        pendingNativeQuote?.cancel()
        pendingNativeQuote = Task { @MainActor [weak self, weak webView] in
            // Let WebKit's simultaneous selection gesture create or update its
            // range first. This bridge only opens an explicit quote action.
            do { try await Task.sleep(for: .milliseconds(preservePending ? 90 : 170)) }
            catch { return }
            guard let self, let webView, self.onQuote != nil, self.loaded else { return }
            webView.callAsyncJavaScript(
                "window.TimelineMarkdown.prepareQuoteAtPoint(x, y, preservePending);",
                arguments: ["x": Double(point.x), "y": Double(point.y), "preservePending": preservePending],
                in: nil, in: .page
            ) { _ in }
        }
    }
    #endif

    private func scheduleRender() {
        guard source != lastRenderedSource || (onDoubleClick != nil) != lastDoubleClickEnabled || (onQuote != nil) != lastQuoteEnabled else { return }
        pendingRender?.cancel()
        pendingRender = Task { @MainActor [weak self] in
            guard let self else { return }
            // Read-only cards render immediately. Debounce only subsequent
            // editor keystrokes, so typing does not rebuild the DOM per key.
            if self.onQuote == nil && self.lastRenderedSource != nil {
                do { try await Task.sleep(for: .milliseconds(75)) } catch { return }
            }
            guard !Task.isCancelled, !self.isDisposed, let webView = self.webView else { return }
            let text = self.source
            let doubleClickEnabled = self.onDoubleClick != nil
            let quoteEnabled = self.onQuote != nil
            webView.callAsyncJavaScript("window.TimelineMarkdown.nativeQuotePopup = true; window.TimelineMarkdown.render(source, doubleClickEnabled, quoteEnabled);",
                                       arguments: ["source": text, "doubleClickEnabled": doubleClickEnabled, "quoteEnabled": quoteEnabled],
                                       in: nil, in: .page) { [weak self] result in
                if case let .failure(error) = result {
                    self?.fail("预览未能完成：\(error.localizedDescription)")
                }
            }
            self.lastRenderedSource = text
            self.lastDoubleClickEnabled = doubleClickEnabled
            self.lastQuoteEnabled = quoteEnabled
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isDisposed else { return }
        loaded = true
        lastRenderedSource = nil
        scheduleRender()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("无法加载预览：\(error.localizedDescription)")
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("无法加载预览：\(error.localizedDescription)")
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        lastRenderedSource = nil
        if !isDisposed { webView.reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .linkActivated {
            if let scheme = url.scheme?.lowercased(), ["https", "http", "mailto"].contains(scheme) { onOpenURL?(url) }
            decisionHandler(.cancel)
        } else if url.isFileURL && navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "quoteCandidate":
            guard isAttached, let text = body["text"] as? String, !text.isEmpty, onQuote != nil else { return }
            let rect = CGRect(x: body["x"] as? Double ?? 0, y: body["y"] as? Double ?? 0,
                              width: max(1, body["width"] as? Double ?? 1), height: max(1, body["height"] as? Double ?? 1))
            pendingQuotePopup?.cancel()
            pendingQuotePopup = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(130))
                guard !Task.isCancelled, let self, self.isAttached else { return }
                #if os(iOS)
                if let view = self.webView { self.dismissEditMenus(in: view) }
                #endif
                self.quoteWasPresented = true
                self.quoteCandidate = MarkdownQuoteCandidate(text: text, rect: rect)
            }
        case "height":
            guard let value = body["height"] as? Double, value.isFinite else { return }
            let nextHeight = CGFloat(max(24, min(1_000_000, value)))
            cachedHeight = nextHeight
            measuredWidth = CGFloat(body["width"] as? Double ?? 0)
            if isAttached && abs(height - nextHeight) > 0.5 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { height = nextHeight }
            }
        case "doubleClick": if isAttached { onDoubleClick?() }
        case "quote":
            if isAttached, let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onQuote?(text) }
        case "error": fail(body["message"] as? String ?? "Markdown 预览暂不可用。")
        default: break
        }
    }

    func tearDown() {
        isDisposed = true
        detach()
        pendingRender?.cancel()
        pendingQuotePopup?.cancel()
        #if os(iOS)
        pendingNativeQuote?.cancel()
        if let quoteLongPressRecognizer { webView?.removeGestureRecognizer(quoteLongPressRecognizer) }
        quoteLongPressRecognizer = nil
        #endif
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "timelineMarkdown")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
    }

    private func fail(_ message: String) {
        hasFailed = true
        if isAttached { renderingError = message }
    }

    #if os(iOS)
    private func dismissEditMenus(in view: UIView) {
        view.interactions.compactMap { $0 as? UIEditMenuInteraction }.forEach { $0.dismissMenu() }
        view.subviews.forEach { dismissEditMenus(in: $0) }
    }
    #endif
}

#if os(iOS)
extension MarkdownWebCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        onQuote != nil && loaded
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif

private final class WeakMarkdownMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var receiver: WKScriptMessageHandler?
    init(_ receiver: WKScriptMessageHandler) { self.receiver = receiver }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        receiver?.userContentController(userContentController, didReceive: message)
    }
}
