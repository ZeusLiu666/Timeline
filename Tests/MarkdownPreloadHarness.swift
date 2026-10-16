import AppKit

// Test-only identity accessor. This extension shares the compiled source file
// with the cache; it is never added to the product.
@MainActor
private extension MarkdownRenderCache {
    static func benchmarkIdleIdentity(source: String, indexURL: URL) -> (ObjectIdentifier, ObjectIdentifier)? {
        guard let owner = idle.last(where: { $0.matches(source) }) else { return nil }
        return (ObjectIdentifier(owner), ObjectIdentifier(owner.makeWebView(indexURL: indexURL)))
    }
    static func benchmarkIdleWebView(source: String, indexURL: URL) -> WKWebView? {
        idle.last(where: { $0.matches(source) })?.makeWebView(indexURL: indexURL)
    }
}

@MainActor
private final class WKPreloadBenchmark {
    private var height: CGFloat = 32
    private var renderError: String?
    private var candidate: MarkdownQuoteCandidate?
    private var doubleClickCount = 0
    private var quoteText: String?

    func start() {
        Task { @MainActor in
            let sentinel = "TIMELINE_PRELOAD_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let source = """
            # \(sentinel)

            这是独特的预加载记录。它在没有 AppKit 窗口的情况下完成离线预渲染。

            行内公式 $E=mc^2$ 和 $a^2+b^2=c^2$。

            $$
            \\int_0^1 x^2 dx = \\frac{1}{3}
            $$

            $$
            P(y|x)=\\frac{e^{z_y}}{\\sum_j e^{z_j}}
            $$

            - 预加载高度需要在领取前回传
            - 领取后的动作需要重新绑定
            """
            guard let indexURL = MarkdownPreviewResources.indexURL else { fail("Bundle Markdown resource missing") }
            guard MarkdownRenderCache.height(for: source, width: 640) == nil else { fail("Unique source unexpectedly already cached") }
            let started = ProcessInfo.processInfo.systemUptime
            await MarkdownRenderCache.preload(sources: [source], width: 640)
            let apiReturnMS = elapsedMS(since: started)
            while (MarkdownRenderCache.height(for: source, width: 640) ?? 32) <= 100 {
                if elapsedMS(since: started) > 15_000 { fail("Offscreen preloaded height did not arrive") }
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let idleView = MarkdownRenderCache.benchmarkIdleWebView(source: source, indexURL: indexURL) else { fail("Preloaded WebKit view absent") }
            while true {
                let status = try? await idleView.evaluateJavaScript("document.fonts.status")
                if status as? String == "loaded" { break }
                if elapsedMS(since: started) > 15_000 { fail("Preloaded fonts did not finish loading") }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let offlineReadyMS = elapsedMS(since: started)
            let wideHeight = MarkdownRenderCache.height(for: source, width: 640)!
            guard MarkdownRenderCache.height(for: source, width: 320) == nil else { fail("640-point measurement was returned for 320-point lookup") }
            guard let before = MarkdownRenderCache.benchmarkIdleIdentity(source: source, indexURL: indexURL) else { fail("Preloaded owner not idle") }
            let resizeStarted = ProcessInfo.processInfo.systemUptime
            await MarkdownRenderCache.preload(documents: [.init(source: source, width: 320)])
            while (MarkdownRenderCache.height(for: source, width: 320) ?? 32) <= 100 {
                if elapsedMS(since: resizeStarted) > 15_000 { fail("Resized offscreen 320-point measurement did not arrive") }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let resizeReadyMS = elapsedMS(since: resizeStarted)
            let preloadedHeight = MarkdownRenderCache.height(for: source, width: 320)!
            guard MarkdownRenderCache.height(for: source, width: 640) == nil else { fail("320-point measurement remained available under old 640-point width") }
            guard preloadedHeight > wideHeight else { fail("Narrow content did not become taller: wide=\(wideHeight), narrow=\(preloadedHeight)") }
            // Deliberately start the new owner at the ordinary 32-point default.
            // Final coordinator.update must restore its width-correct cached
            // height through pendingHeightSync after the update turn.
            height = 32
            let acquiredAt = ProcessInfo.processInfo.systemUptime
            let owner = MarkdownRenderCache.acquire(source: source,
                height: Binding(get: { self.height }, set: { self.height = $0 }),
                renderingError: Binding(get: { self.renderError }, set: { self.renderError = $0 }),
                quoteCandidate: Binding(get: { self.candidate }, set: { self.candidate = $0 }))
            let webView = owner.makeWebView(indexURL: indexURL, widthHint: 320)
            let sameOwner = before.0 == ObjectIdentifier(owner)
            let sameView = before.1 == ObjectIdentifier(webView)
            guard sameOwner && sameView else { fail("Acquire did not reuse preloaded coordinator and WKWebView") }
            owner.update(source: source, onDoubleClick: { self.doubleClickCount += 1 },
                         onQuote: { self.quoteText = $0 }, onOpenURL: { _ in })
            do {
                try await Task.sleep(for: .milliseconds(10))
                guard abs(height - preloadedHeight) < 1 else { fail("Deferred height sync did not restore 320-point measurement: native=\(height), expected=\(preloadedHeight)") }
                let value = try await webView.evaluateJavaScript("""
                (() => {
                  const c=document.getElementById('content');
                  return {sentinel:c.textContent.includes('\(sentinel)'),
                          formulas:c.querySelectorAll('.katex').length,
                          fonts:document.fonts.status,domHeight:c.getBoundingClientRect().height,width:innerWidth};
                })()
                """) as? [String: Any]
                guard let value, value["sentinel"] as? Bool == true,
                      (value["formulas"] as? Int ?? 0) >= 4, value["fonts"] as? String == "loaded",
                      (value["width"] as? Int ?? 0) == 320 else {
                    fail("Preloaded DOM content/formulas/fonts invalid: \(String(describing: value))")
                }
                let acquiredReadyMS = elapsedMS(since: acquiredAt)
                _ = try await webView.evaluateJavaScript("""
                document.getElementById('content').dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));
                window.webkit.messageHandlers.timelineMarkdown.postMessage({type:'quote',text:'\(sentinel)'});
                window.webkit.messageHandlers.timelineMarkdown.postMessage({type:'quoteCandidate',text:'\(sentinel)',x:2,y:2,width:30,height:20});
                true;
                """)
                try await Task.sleep(for: .milliseconds(200))
                guard doubleClickCount == 1, quoteText == sentinel, candidate?.text == sentinel else {
                    fail("Rebound actions or quote binding invalid: clicks=\(doubleClickCount), quote=\(String(describing: quoteText)), candidate=\(String(describing: candidate?.text))")
                }
                guard renderError == nil else { fail(renderError!) }
                emit(["event":"preload_pass", "api_return_ms":apiReturnMS,
                      "offscreen_ready_ms":offlineReadyMS, "acquire_to_verified_ms":acquiredReadyMS,
                      "preloaded_height":Double(preloadedHeight), "native_height":Double(height),
                      "wide_640_height":Double(wideHeight),"narrow_320_height":Double(preloadedHeight),
                      "resize_ready_ms":resizeReadyMS,"width_320_lookup_before_resize_nil":true,
                      "width_640_lookup_after_resize_nil":true,"deferred_height_sync":true,
                      "new_wkwebview":false,"same_preloaded_coordinator":sameOwner,"same_preloaded_webview":sameView,
                      "double_click_callback":true,"quote_callback":true,"quote_candidate_binding":true,"dom":value,
                      "window_visible_during_preload":false])
                MarkdownRenderCache.release(owner)
                NSApp.terminate(nil)
            } catch { fail(error.localizedDescription) }
        }
    }

    private func elapsedMS(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }
    private func emit(_ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
    private func fail(_ message: String) -> Never {
        emit(["event":"failure","message":message])
        exit(1)
    }
}

@main
private enum WKPreloadBenchmarkMain {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let benchmark = WKPreloadBenchmark()
        benchmark.start()
        application.run()
        withExtendedLifetime(benchmark) {}
    }
}
