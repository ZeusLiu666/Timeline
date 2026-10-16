const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM, VirtualConsole } = require(process.env.TIMELINE_JSDOM_PATH || 'jsdom');

(async () => {
  const messages = [];
  const resourceRoot = path.resolve(__dirname, '../Timeline/Resources/Markdown');
  const dom = await JSDOM.fromFile(path.join(resourceRoot, 'index.html'), {
    runScripts: 'dangerously', resources: 'usable', pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
    beforeParse(window) {
      window.webkit = { messageHandlers: { timelineMarkdown: { postMessage: value => messages.push(value) } } };
      window.ResizeObserver = class { observe() {} disconnect() {} };
    }
  });
  const window = dom.window;
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('Offline renderer did not load')), 10000);
    window.addEventListener('load', () => { clearTimeout(timer); resolve(); }, { once: true });
  });
  const document = window.document;
  assert.ok(window.TimelineMarkdown, 'Bundled engine initialized');
  const fixture = fs.readFileSync(path.join(__dirname, 'fixtures/rich-note.md'), 'utf8');
  const result = window.TimelineMarkdown.render(fixture, true, true);
  assert.equal(result.mathCount, 5, 'All five formula syntaxes render');
  assert.equal(result.errorCount, 0, 'Valid LaTeX has no rendering errors');
  assert.equal(document.querySelectorAll('table').length, 1);
  assert.equal(document.querySelectorAll('input[type=checkbox]').length, 2);
  assert.equal(document.querySelector('pre code').textContent.trim(), 'cost = "$100"', 'Code keeps literal dollar signs');
  const bold = document.querySelector('#content strong');
  const range = document.createRange(); range.selectNodeContents(bold);
  window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event('selectionchange'));
  assert.equal(document.querySelector('#quote-toolbar').hidden, false, 'Selection exposes explicit quote action');
  document.querySelector('#quote-button').click();
  assert.ok(messages.some(value => value.type === 'quote' && value.text === '实时渲染'), 'Exact selected excerpt is sent to native shelf');
  range.selectNodeContents(document.querySelector('#content p'));
  window.getSelection().removeAllRanges(); window.getSelection().addRange(range);
  document.dispatchEvent(new window.Event('selectionchange'));
  document.querySelector('#quote-button').click();
  assert.ok(messages.some(value => value.type === 'quote' && value.text.includes('$E=mc^2$')), 'Quoted equations preserve their LaTeX source');
  document.querySelector('#content p').dispatchEvent(new window.MouseEvent('dblclick', { bubbles: true }));
  assert.ok(messages.some(value => value.type === 'doubleClick'), 'Rendered body supports double-click editing');
  window.TimelineMarkdown.render('前半段 **精确片段** 后半段', false, true);
  const exactRange = document.createRange();
  exactRange.selectNodeContents(document.querySelector('#content strong'));
  const quoteCountBefore = messages.filter(value => value.type === 'quote').length;
  window.getSelection().removeAllRanges(); window.getSelection().addRange(exactRange);
  document.dispatchEvent(new window.Event('selectionchange'));
  window.getSelection().removeAllRanges();
  document.dispatchEvent(new window.Event('selectionchange'));
  assert.equal(document.querySelector('#quote-toolbar').hidden, false, 'iOS transient collapsed selection keeps explicit quote action');
  document.elementFromPoint = () => document.querySelector('#content p');
  window.TimelineMarkdown.prepareQuoteAtPoint(10, 10, true);
  assert.equal(messages.filter(value => value.type === 'quote').length, quoteCountBefore, 'Selection and native long press never auto-save a quote');
  document.querySelector('#quote-button').click();
  assert.equal(messages.filter(value => value.type === 'quote').at(-1).text, '精确片段', 'Native release preserves exact selected excerpt rather than replacing with paragraph');
  window.TimelineMarkdown.prepareQuoteAtPoint(10, 10, false);
  assert.equal(document.querySelector('#quote-button').textContent, '引用这段内容', 'Long press without selection clearly labels paragraph fallback');
  document.querySelector('.quote-dismiss').click();
  assert.equal(document.querySelector('#quote-toolbar').hidden, true, 'User can explicitly dismiss pending quote');
  assert.equal(messages.filter(value => value.type === 'quote').length, quoteCountBefore + 1, 'Dismissing never saves a quote');
  window.TimelineMarkdown.nativeQuotePopup = true;
  window.TimelineMarkdown.render('上下文 **引用部分** 后文', false, true);
  const nativeRange = document.createRange();
  nativeRange.selectNodeContents(document.querySelector('#content strong'));
  window.getSelection().removeAllRanges(); window.getSelection().addRange(nativeRange);
  document.dispatchEvent(new window.Event('selectionchange'));
  assert.equal(messages.filter(value => value.type === 'quoteCandidate').at(-1).text, '引用部分', 'Native popup receives exact selection');
  assert.equal(document.querySelector('#quote-toolbar').hidden, true, 'Native selection popup does not insert an HTML action into the note');
  window.TimelineMarkdown.dismissQuote();
  window.TimelineMarkdown.nativeQuotePopup = false;
  window.timelineRender('新版公式 $x^3$');
  assert.equal(document.querySelectorAll('.katex').length, 1, 'Repeated source updates replace preview');
  assert.ok(document.querySelector('#content').textContent.includes('新版公式'));
  window.timelineRender('<script>window.ATTACKED = true</script>\n\n![image](https://invalid.example/private)');
  assert.equal(window.ATTACKED, undefined);
  assert.equal(document.querySelectorAll('#content script,#content img').length, 0, 'Notes cannot execute scripts or load remote images');
  const invalid = window.timelineRender(String.raw`错误 $\notARealMacro{x}$`);
  assert.equal(invalid.errorCount, 1, 'Invalid LaTeX has a readable fallback');
  window.timelineRender('未完成公式 $x+');
  assert.ok(document.querySelector('#content').textContent.includes('$x+'), 'Incomplete typing stays readable');
  const previousRAF = window.requestAnimationFrame;
  window.requestAnimationFrame = () => 0;
  const heightsBeforePreload = messages.filter(value => value.type === 'height').length;
  window.timelineRender('离屏预加载 $x^2$');
  assert.ok(messages.filter(value => value.type === 'height').length > heightsBeforePreload,
    'Preloaded documents report their initial height even when offscreen animation frames are suspended');
  window.requestAnimationFrame = previousRAF;
  dom.window.close();
  console.log('PASS: offline Markdown, tables/tasks/code, five math syntaxes, live update, selection quote, double-click, invalid input');
})().catch(error => { console.error(error); process.exitCode = 1; });
