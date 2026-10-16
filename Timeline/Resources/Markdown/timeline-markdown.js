/* Timeline's local-only renderer. Third-party dependencies are pinned in VENDOR.md. */
(function () {
  "use strict";
  const content = document.getElementById("content");
  const quoteToolbar = document.getElementById("quote-toolbar");
  const quoteButton = document.getElementById("quote-button");
  let doubleClickEnabled = false;
  let quoteEnabled = false;
  let selectedQuote = "";
  let heightFrame = null;
  let selectingPointer = false;
  let pendingNativeCandidate = null;

  function post(message) {
    const bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.timelineMarkdown;
    if (bridge) bridge.postMessage(message);
  }
  function measureHeight() {
      const contentBottom = content.offsetTop + Math.max(content.getBoundingClientRect().height, content.scrollHeight);
      const toolbarBottom = quoteToolbar && !quoteToolbar.hidden ? quoteToolbar.offsetTop + quoteToolbar.offsetHeight + 2 : 0;
      const height = Math.ceil(Math.max(contentBottom, toolbarBottom)) + 1;
      post({ type: "height", height: Math.max(24, height), width: window.innerWidth });
  }
  function reportHeight() {
    if (heightFrame !== null) return;
    heightFrame = requestAnimationFrame(function () {
      heightFrame = null;
      measureHeight();
    });
  }
  function isEscaped(source, index) {
    let slashes = 0;
    while (index > 0 && source[--index] === "\\") slashes++;
    return slashes % 2 === 1;
  }
  function closingIndex(source, delimiter, start, singleDollar) {
    let index = start;
    while ((index = source.indexOf(delimiter, index)) !== -1) {
      if (!isEscaped(source, index) && (!singleDollar || (!/\s/.test(source[index - 1] || " ") && !/[0-9]/.test(source[index + 1] || "")))) return index;
      index += delimiter.length;
    }
    return -1;
  }

  try {
    if (!window.markdownit || !window.DOMPurify || !window.katex) throw new Error("离线 Markdown 组件未能加载。");
    const md = window.markdownit({ html: false, linkify: true, typographer: false, breaks: true });
    if (window.markdownitTaskLists) md.use(window.markdownitTaskLists, { enabled: false, label: false });

    function mathPlaceholder(tex, display) {
      const tag = display ? "div" : "span";
      const cls = display ? "timeline-math math-display" : "timeline-math";
      return "<" + tag + " class=\"" + cls + "\" data-display=\"" + display + "\" data-tex=\"" + md.utils.escapeHtml(tex) + "\">" + md.utils.escapeHtml(tex) + "</" + tag + ">";
    }

    // Before Markdown escape processing: LaTeX backslashes and underscores survive.
    md.inline.ruler.before("escape", "timeline_math", function (state, silent) {
      const start = state.pos;
      let open, close, display = false;
      if (state.src.startsWith("\\(", start)) { open = "\\("; close = "\\)"; }
      else if (state.src.startsWith("\\[", start)) { open = "\\["; close = "\\]"; display = true; }
      else if (state.src.startsWith("$$", start)) { open = "$$"; close = "$$"; display = true; }
      else if (state.src[start] === "$" && !/\s/.test(state.src[start + 1] || " ")) { open = "$"; close = "$"; }
      else return false;
      const end = closingIndex(state.src, close, start + open.length, open === "$");
      if (end < 0 || end === start + open.length) {
        if (!silent) state.pending += open;
        state.pos += open.length;
        return true;
      }
      if (!silent) {
        const token = state.push("timeline_math", "", 0);
        token.content = state.src.slice(start + open.length, end);
        token.meta = { display: display };
      }
      state.pos = end + close.length;
      return true;
    });
    md.renderer.rules.timeline_math = function (tokens, index) {
      return mathPlaceholder(tokens[index].content, tokens[index].meta.display);
    };

    md.block.ruler.before("fence", "timeline_math_block", function (state, startLine, endLine, silent) {
      if (state.sCount[startLine] - state.blkIndent >= 4) return false;
      const lineStart = state.bMarks[startLine] + state.tShift[startLine];
      const first = state.src.slice(lineStart, state.eMarks[startLine]);
      let open, close;
      if (first.startsWith("$$")) { open = "$$"; close = "$$"; }
      else if (first.startsWith("\\[")) { open = "\\["; close = "\\]"; }
      else return false;
      let math = first.slice(open.length);
      let closing = closingIndex(math, close, 0, false);
      let nextLine = startLine;
      while (closing < 0 && ++nextLine < endLine) {
        const next = state.src.slice(state.bMarks[nextLine] + state.tShift[nextLine], state.eMarks[nextLine]);
        const offset = math.length + 1;
        math += "\n" + next;
        const found = closingIndex(next, close, 0, false);
        if (found >= 0) closing = offset + found;
      }
      if (closing < 0 || math.slice(closing + close.length).trim() !== "") return false;
      if (silent) return true;
      const token = state.push("timeline_math_block", "", 0);
      token.block = true;
      token.content = math.slice(0, closing).trim();
      token.map = [startLine, nextLine + 1];
      state.line = nextLine + 1;
      return true;
    }, { alt: ["paragraph", "reference", "blockquote", "list"] });
    md.renderer.rules.timeline_math_block = function (tokens, index) { return mathPlaceholder(tokens[index].content, true) + "\n"; };

    const defaultFence = md.renderer.rules.fence;
    md.renderer.rules.fence = function (tokens, index, options, env, renderer) {
      if (/^(math|latex|tex|katex)$/i.test(tokens[index].info.trim())) return mathPlaceholder(tokens[index].content, true);
      return defaultFence(tokens, index, options, env, renderer);
    };
    md.renderer.rules.image = function (tokens, index) {
      return "<span class=\"blocked-image\">图片：" + md.utils.escapeHtml(tokens[index].content || "外部图片") + "（离线预览不加载图片）</span>";
    };
    const defaultLinkOpen = md.renderer.rules.link_open || function (tokens, index, options, env, renderer) { return renderer.renderToken(tokens, index, options); };
    md.renderer.rules.link_open = function (tokens, index, options, env, renderer) {
      tokens[index].attrSet("rel", "noopener noreferrer");
      return defaultLinkOpen(tokens, index, options, env, renderer);
    };

    function render(source, enableDoubleClick, enableQuote) {
      doubleClickEnabled = enableDoubleClick === true;
      quoteEnabled = enableQuote === true;
      selectedQuote = "";
      if (quoteToolbar) quoteToolbar.hidden = true;
      const html = md.render(String(source || ""));
      content.innerHTML = window.DOMPurify.sanitize(html, {
        USE_PROFILES: { html: true },
        FORBID_TAGS: ["script", "style", "iframe", "frame", "object", "embed", "form", "video", "audio", "img", "svg", "math", "link", "meta", "base"],
        FORBID_ATTR: ["style", "src", "srcset", "action", "formaction", "autofocus"],
        ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|#)/i
      });
      // Restore the generated task control after sanitizing attributes. It is
      // intentionally read-only here; editable issue checkboxes are native.
      content.querySelectorAll("input.task-list-item-checkbox").forEach(function (element) {
        element.type = "checkbox";
        element.disabled = true;
      });
      content.querySelectorAll(".timeline-math").forEach(function (element) {
        const tex = element.getAttribute("data-tex") || "";
        const display = element.getAttribute("data-display") === "true";
        element.removeAttribute("data-tex");
        element.removeAttribute("data-display");
        try {
          window.katex.render(tex, element, { displayMode: display, throwOnError: true, trust: false, strict: "ignore", maxExpand: 1000, maxSize: 20, output: "htmlAndMathml" });
        } catch (error) {
          element.classList.add("math-error");
          element.textContent = (display ? "$$ " : "$ ") + tex + (display ? " $$" : " $");
          element.title = "公式暂未识别：" + String(error.message || error);
        }
      });
      // A prepared offscreen document may not receive animation frames. Measure
      // immediately so its first visible layout can use the correct height.
      measureHeight();
      if (document.fonts && document.fonts.ready) document.fonts.ready.then(measureHeight);
      return { mathCount: content.querySelectorAll(".katex").length, errorCount: content.querySelectorAll(".math-error").length };
    }

    content.addEventListener("dblclick", function (event) {
      if (!doubleClickEnabled || event.target.closest("a,input,button")) return;
      post({ type: "doubleClick" });
    });
    content.addEventListener("click", function (event) {
      const link = event.target.closest("a");
      if (!link) return;
      if (!/^(https?:|mailto:)/i.test(link.getAttribute("href") || "")) event.preventDefault();
    });
    function showQuote(text, label, anchor) {
      if (!quoteEnabled || !quoteToolbar || !quoteButton || !text.trim()) return;
      selectedQuote = text;
      quoteButton.textContent = label;
      if (window.TimelineMarkdown && window.TimelineMarkdown.nativeQuotePopup) {
        quoteToolbar.hidden = true;
        const candidate = { type: "quoteCandidate", text: text,
          x: anchor && Number.isFinite(anchor.left) ? anchor.left : 0,
          y: anchor && Number.isFinite(anchor.top) ? anchor.top : (anchor ? anchor.bottom : 0),
          width: anchor && anchor.width ? anchor.width : content.clientWidth,
          height: anchor && anchor.height ? anchor.height : 20 };
        if (selectingPointer) pendingNativeCandidate = candidate;
        else post(candidate);
        return;
      }
      // Leave room for iOS's native selection menu while keeping handles usable.
      const quoteGap = window.matchMedia && window.matchMedia("(pointer: coarse)").matches ? 70 : 7;
      if (anchor) quoteToolbar.style.top = Math.max(0, anchor.bottom + window.scrollY + quoteGap) + "px";
      quoteToolbar.hidden = false;
      reportHeight();
    }
    function quoteText(fragment, fallback) {
      if (!fragment.querySelector || !fragment.querySelector(".katex")) return fallback;
      const holder = document.createElement("div");
      holder.appendChild(fragment);
      holder.querySelectorAll(".timeline-math,.katex").forEach(function (formula) {
        if (!holder.contains(formula)) return;
        const tex = formula.querySelector('annotation[encoding="application/x-tex"]');
        if (!tex) return;
        const delimiter = formula.classList.contains("math-display") ? "$$" : "$";
        formula.replaceWith(document.createTextNode(delimiter + tex.textContent + delimiter));
      });
      holder.querySelectorAll("br").forEach(function (lineBreak) { lineBreak.replaceWith(document.createTextNode("\n")); });
      holder.querySelectorAll("p,li,h1,h2,h3,h4,h5,h6,blockquote,pre").forEach(function (block) { block.appendChild(document.createTextNode("\n")); });
      return holder.textContent.trim();
    }
    function showSelectedQuote() {
      if (!quoteEnabled || !quoteToolbar) return false;
      const selection = window.getSelection();
      if (selection && selection.rangeCount && !selection.isCollapsed && content.contains(selection.getRangeAt(0).commonAncestorContainer)) {
        const range = selection.getRangeAt(0);
        const anchor = typeof range.getBoundingClientRect === "function" ? range.getBoundingClientRect() : null;
        showQuote(quoteText(range.cloneContents(), selection.toString()), "引用选中内容", anchor);
        return true;
      }
      // iOS may temporarily collapse its DOM selection while showing handles or
      // the native edit menu. Keep the explicit pending quote until confirmed,
      // cancelled, replaced by another selection, or the source is re-rendered.
      return false;
    }
    content.addEventListener("pointerdown", function () { selectingPointer = true; });
    document.addEventListener("pointerup", function () {
      selectingPointer = false;
      if (pendingNativeCandidate) { post(pendingNativeCandidate); pendingNativeCandidate = null; }
    });
    document.addEventListener("selectionchange", showSelectedQuote);
    function prepareQuoteAtPoint(x, y, preservePending) {
      if (!quoteEnabled) return false;
      if (showSelectedQuote()) return true;
      if (preservePending && selectedQuote) return true;
      const element = document.elementFromPoint(Number(x), Number(y));
      if (!element || !content.contains(element) || element.closest("a,input,button")) return false;
      const paragraph = element.closest("p,li,blockquote,pre,h1,h2,h3,h4,h5,h6,td,th,.math-display");
      if (!paragraph || !content.contains(paragraph)) return false;
      showQuote(quoteText(paragraph.cloneNode(true), paragraph.innerText || paragraph.textContent || ""),
                "引用这段内容", { bottom: Number(y) });
      return true;
    }
    content.addEventListener("touchend", function () {
      window.setTimeout(showSelectedQuote, 70);
      window.setTimeout(showSelectedQuote, 220);
    }, { passive: true });
    content.addEventListener("contextmenu", function (event) {
      if (!quoteEnabled || event.target.closest("a,input,button")) return;
      const selection = window.getSelection();
      if (selection && !selection.isCollapsed) return;
      const paragraph = event.target.closest("p,li,blockquote,pre,h1,h2,h3,h4,h5,h6,td,th,.math-display");
      if (paragraph) showQuote(quoteText(paragraph.cloneNode(true), paragraph.innerText || paragraph.textContent || ""), "引用这段内容", { bottom: event.clientY });
    });
    function clearPendingQuote() {
      pendingNativeCandidate = null;
      selectedQuote = "";
      quoteToolbar.hidden = true;
      const selection = window.getSelection();
      if (selection) selection.removeAllRanges();
      reportHeight();
    }
    if (quoteButton) {
      quoteButton.addEventListener("pointerdown", function (event) { event.preventDefault(); });
      function confirmQuote(event) {
        if (event) event.preventDefault();
        if (!quoteEnabled || !selectedQuote.trim()) return;
        post({ type: "quote", text: selectedQuote });
        clearPendingQuote();
      }
      quoteButton.addEventListener("click", confirmQuote);
      // A native iOS edit menu can otherwise consume the first synthetic click.
      quoteButton.addEventListener("touchend", confirmQuote, { passive: false });
      const dismissButton = document.createElement("button");
      dismissButton.type = "button";
      dismissButton.className = "quote-dismiss";
      dismissButton.textContent = "×";
      dismissButton.setAttribute("aria-label", "取消引用");
      dismissButton.addEventListener("pointerdown", function (event) { event.preventDefault(); });
      function dismissQuote(event) { event.preventDefault(); clearPendingQuote(); }
      dismissButton.addEventListener("click", dismissQuote);
      dismissButton.addEventListener("touchend", dismissQuote, { passive: false });
      quoteToolbar.appendChild(dismissButton);
    }
    new ResizeObserver(reportHeight).observe(content);
    window.addEventListener("resize", reportHeight);
    window.TimelineMarkdown = { render: render, measureHeight: measureHeight, prepareQuoteAtPoint: prepareQuoteAtPoint, dismissQuote: clearPendingQuote, markdownHTML: function (source) { return md.render(String(source || "")); }, versions: { markdownIt: "15.0.2", DOMPurify: "3.4.16", KaTeX: "0.19.0", taskLists: "2.1.1" } };
    window.timelineRender = function (source) { return render(source, false, false); };
    post({ type: "ready" });
    reportHeight();
  } catch (error) {
    content.textContent = "Markdown 预览暂不可用。";
    post({ type: "error", message: String(error.message || error) });
  }
}());
