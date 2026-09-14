import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../app_config.dart';
import '../data/embedded_fonts.dart';
import '../data/web_style.dart';

/// 工具栏「当前状态」：用于按钮高亮（加粗/斜体/列表/块级格式）。
@immutable
class EditorToolbarState {
  const EditorToolbarState({
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.ul = false,
    this.ol = false,
    this.block = '',
    this.chars = 0,
    this.inFootnote = false,
  });

  final bool bold;
  final bool italic;
  final bool strike;
  final bool ul;
  final bool ol;

  /// 当前块级标签：'' / 'p' / 'h2' / 'h3' / 'h4' / 'blockquote' / 'pre'
  final String block;

  /// 正文字数（不含 HTML）。
  final int chars;

  /// 光标是否落在脚注标记里。
  final bool inFootnote;

  static const EditorToolbarState initial = EditorToolbarState();

  static EditorToolbarState fromJson(Map<String, dynamic> j) => EditorToolbarState(
        bold: j['bold'] == true,
        italic: j['italic'] == true,
        strike: j['strike'] == true,
        ul: j['ul'] == true,
        ol: j['ol'] == true,
        block: (j['block'] ?? '').toString(),
        chars: (j['chars'] is int) ? j['chars'] as int : 0,
        inFootnote: j['fn'] == true,
      );
}

/// 富文本编辑器控制器：Dart ↔ WebView 的桥。
///
/// 之所以用 `contenteditable` 的 WebView 而不是原生富文本控件：
/// **所见即所得**——编辑区用的就是站点自己的正文样式（[WebStyle]），
/// 因此"编辑器里长什么样，发布后就是什么样"，与网页端一致。
/// `document.execCommand` 虽被标记为过时，但在 WebView 109（目标机 Android 8
/// 自带版本）上工作良好，且是唯一零依赖的实现路径。
class RichTextEditorController {
  RichTextEditorController();

  final ValueNotifier<EditorToolbarState> toolbar =
      ValueNotifier<EditorToolbarState>(EditorToolbarState.initial);

  /// 正文变化回调（用于"有未保存内容"提示）。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  WebViewController? _web;
  bool _ready = false;

  bool get isReady => _ready;

  void _attach(WebViewController web) {
    _web = web;
  }

  void _onReady() {
    _ready = true;
  }

  /// 读取编辑器正文 HTML（发布用）。
  Future<String> getHtml() async {
    final r = await _evalJson('window.YbhEditor.getPayload()');
    if (r == null) return '';
    return (r['html'] ?? '').toString();
  }

  /// 纯文本（校验"正文是否为空"用）。
  Future<String> getPlainText() async {
    final r = await _evalJson('window.YbhEditor.getPayload()');
    if (r == null) return '';
    return (r['text'] ?? '').toString();
  }

  Future<void> setHtml(String html) async {
    await _js('window.YbhEditor.setHtml(${jsonEncode(html)})');
  }

  /// 执行一条 `document.execCommand` 命令（bold / italic / formatBlock …）。
  Future<void> exec(String cmd, {String? value}) async {
    await _js('window.YbhEditor.exec(${jsonEncode(cmd)}, '
        '${value == null ? 'null' : jsonEncode(value)})');
  }

  /// 把选区包进 `<code>`（行内代码）。
  Future<void> inlineCode() => _js('window.YbhEditor.inlineCode()');

  /// 插入代码块 `<pre><code>`。
  Future<void> codeBlock() => _js('window.YbhEditor.codeBlock()');

  /// 插入链接；未选中文字时把 url 当作链接文字。
  Future<void> insertLink(String url) =>
      _js('window.YbhEditor.insertLink(${jsonEncode(url)})');

  /// 插入图片（外链 URL 或已上传的媒体地址）。
  Future<void> insertImage(String url, {String alt = ''}) =>
      _js('window.YbhEditor.insertImage(${jsonEncode(url)}, ${jsonEncode(alt)})');

  /// 插入脚注标记 `[fn]…[/fn]`，光标落在中间（与网页端编辑器同一语法）。
  Future<void> insertFootnote() => _js('window.YbhEditor.insertFootnote()');

  /// 首行缩进开关（`.ybh-indent`，与网页端同一类名）。
  Future<void> toggleIndent() => _js('window.YbhEditor.toggleIndent()');

  /// 去掉行内格式。
  Future<void> clearFormat() => _js('window.YbhEditor.clearFormat()');

  /// 聚焦编辑区（工具栏点完后让键盘保持弹出）。
  Future<void> focus() => _js('window.YbhEditor.focusEditor()');

  Future<void> _js(String code) async {
    final web = _web;
    if (web == null) return;
    try {
      await web.runJavaScript(code);
    } catch (e) {
      debugPrint('[YBH editor] js 失败: $e');
    }
  }

  Future<Map<String, dynamic>?> _evalJson(String expr) async {
    final web = _web;
    if (web == null) return null;
    try {
      final raw = await web.runJavaScriptReturningResult(expr);
      final text = _unwrap(raw);
      if (text.isEmpty) return null;
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      // 少数平台会把结果再 JSON 编码一层。
      if (decoded is String) {
        final again = jsonDecode(decoded);
        if (again is Map<String, dynamic>) return again;
      }
    } catch (e) {
      debugPrint('[YBH editor] eval 失败: $e');
    }
    return null;
  }

  /// `runJavaScriptReturningResult` 各平台包装不一致：Android 返回原始字符串，
  /// 有时返回带引号的 JSON 字符串。统一剥一层。
  static String _unwrap(Object? raw) {
    if (raw == null) return '';
    var s = raw.toString();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      try {
        final v = jsonDecode(s);
        if (v is String) s = v;
      } catch (_) {}
    }
    return s;
  }

  void _onStateMessage(String message) {
    try {
      final decoded = jsonDecode(message);
      if (decoded is Map<String, dynamic>) {
        toolbar.value = EditorToolbarState.fromJson(decoded);
        revision.value++;
      }
    } catch (_) {}
  }

  void dispose() {
    toolbar.dispose();
    revision.dispose();
  }
}

/// 富文本编辑区（WebView contenteditable）。
class RichTextEditor extends StatefulWidget {
  const RichTextEditor({
    super.key,
    required this.controller,
    required this.dark,
    this.placeholder = '在这里写正文…',
  });

  final RichTextEditorController controller;
  final bool dark;
  final String placeholder;

  /// 编辑器的空文档脚手架（`setHtml('')` 时恢复到这个状态）。
  static const String emptyDoc = '<p><br></p>';

  static String buildHtml({required bool dark, required String placeholder}) {
    final theme = dark ? 'dark' : 'light';
    final ph = jsonEncode(placeholder);
    return '''
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>YBH Editor</title>
${WebStyle.instance.headHtml()}
<style>
/* 编辑区外壳：与阅读器同款排版，只去掉外边距、补上占位符与脚注可视化 */
html, body { height: 100%; }
body { background: #fff; }
body.dark { background: var(--dark-bg-primary, rgba(51,51,51,1)); }
.ybh-shell { padding: 14px 18px 140px; }
#editor { outline: none; min-height: 60vh; }
#editor:empty::before,
#editor > p:only-child:empty::before {
  content: $ph;
  color: #9aa0a6;
  pointer-events: none;
}
/* 脚注：编辑期显示为编号徽章（与网页端 T33 的预览观感一致），
   数据库里始终只存 [fn]…[/fn]，不外泄标记。 */
#editor .ybh-fn {
  display: inline-block;
  min-width: 1.1em;
  padding: 0 .28em;
  margin: 0 .1em;
  font-size: .78em;
  line-height: 1.5;
  text-align: center;
  vertical-align: super;
  color: #fff;
  background: var(--theme-skin, #505050);
  border-radius: .6em;
  white-space: nowrap;
}
#editor .ybh-fn.is-open { vertical-align: baseline; }
#editor [data-ybh-fn-text] { color: inherit; }
</style>
</head>
<body class="$theme">
<div class="wrapper">
<div class="ybh-shell">
<div class="entry-content">
<div id="editor" contenteditable="true" spellcheck="false"></div>
</div>
</div>
</div>
<script>
(function () {
  var ed = document.getElementById('editor');
  var savedRange = null;
  var fnSeq = 0;

  function post() {
    var block = '';
    try {
      var n = ed;
      var sel = window.getSelection();
      if (sel && sel.anchorNode) {
        n = sel.anchorNode.nodeType === 3 ? sel.anchorNode.parentNode : sel.anchorNode;
      }
      while (n && n !== ed) {
        var t = (n.tagName || '').toLowerCase();
        if (['p','h1','h2','h3','h4','h5','h6','blockquote','pre','li'].indexOf(t) >= 0) {
          block = (t === 'li') ? 'li' : t; break;
        }
        n = n.parentNode;
      }
    } catch (e) {}
    var text = '';
    try { text = (ed.innerText || '').replace(/\\s+/g, ' ').trim(); } catch (e) {}
    var inFn = false;
    try {
      var s = window.getSelection();
      var a = s && s.anchorNode ? (s.anchorNode.nodeType === 3 ? s.anchorNode.parentNode : s.anchorNode) : null;
      inFn = !!(a && a.closest && a.closest('.ybh-fn'));
    } catch (e) {}
    var st = {
      bold: q('bold'), italic: q('italic'), strike: q('strikeThrough'),
      ul: q('insertUnorderedList'), ol: q('insertOrderedList'),
      block: block, chars: text.length, fn: inFn
    };
    try { YbhEditorState.postMessage(JSON.stringify(st)); } catch (e) {}
  }
  function q(c) { try { return document.queryCommandState(c); } catch (e) { return false; } }
  function sel() { try { return window.getSelection(); } catch (e) { return null; } }

  // 工具栏在 WebView 之外，点按钮会让编辑区失焦、选区丢失 —— 所以持续保存
  // 最后一次选区，执行命令前恢复。这是富文本编辑器最经典的坑。
  document.addEventListener('selectionchange', function () {
    var s = sel();
    if (s && s.rangeCount > 0 && ed.contains(s.anchorNode)) {
      savedRange = s.getRangeAt(0).cloneRange();
    }
    clearTimeout(post._t); post._t = setTimeout(post, 120);
  });

  function restore() {
    ed.focus();
    if (savedRange) {
      var s = sel();
      if (s) { s.removeAllRanges(); s.addRange(savedRange); }
    }
  }
  function insertHtml(html) {
    restore();
    document.execCommand('insertHTML', false, html);
    saveRange();
  }
  function saveRange() {
    var s = sel();
    if (s && s.rangeCount > 0) savedRange = s.getRangeAt(0).cloneRange();
  }
  function stripTags(s) { return (s || '').replace(/<[^>]*>/g, ''); }
  function esc(s) {
    return (s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  // ---- 脚注：编辑期显示徽章，导出时还原成 [fn]…[/fn] ----
  function makeFn(text) {
    fnSeq++;
    var outer = document.createElement('span');
    outer.className = 'ybh-fn';
    outer.setAttribute('data-ybh-fn-text', text || '');
    outer.textContent = '[fn]' + (text || '') + '[/fn]';
    return outer;
  }
  function refreshFnNumbers() {
    var i = 0;
    document.querySelectorAll('#editor .ybh-fn').forEach(function (el) {
      i++;
      el.textContent = String(i);
      if (el.getAttribute('data-ybh-fn-text')) el.setAttribute('title', el.getAttribute('data-ybh-fn-text'));
    });
  }

  function exportHtml() {
    var clone = ed.cloneNode(true);
    clone.querySelectorAll('.ybh-fn').forEach(function (el) {
      var t = document.createTextNode('[fn]' + (el.getAttribute('data-ybh-fn-text') || '') + '[/fn]');
      el.parentNode.replaceChild(t, el);
    });
    normalize(clone);
    return clone.innerHTML;
  }

  // 导出前把 contenteditable 容易产生的**非法结构**清掉，否则提交给 WordPress
  // 会被 wp_kses_post 处理成意想不到的样子：
  //   · <p><ul><li>…</li></ul></p>  —— 块级元素被包在 <p> 里（HTML 不允许）
  //   · <p><p><br></p></p>          —— 嵌套空段落
  var BLOCK_SEL = 'ul,ol,blockquote,pre,h1,h2,h3,h4,h5,h6,figure,table,hr,div';
  function normalize(root) {
    // 1) 解掉"包住块级元素"的 <p>（可能多层，循环到稳定）
    for (var pass = 0; pass < 20; pass++) {
      var changed = false;
      var ps = root.querySelectorAll('p');
      for (var i = 0; i < ps.length; i++) {
        var p = ps[i];
        if (!p.parentNode) continue;
        if (!p.querySelector(BLOCK_SEL)) continue;
        var frag = document.createDocumentFragment();
        while (p.firstChild) frag.appendChild(p.firstChild);
        p.parentNode.replaceChild(frag, p);
        changed = true;
      }
      if (!changed) break;
    }
    // 2) 拆掉嵌套的空 <p>
    for (var pass2 = 0; pass2 < 10; pass2++) {
      var inner = root.querySelector('p > p');
      if (!inner) break;
      var outer = inner.parentNode;
      if (outer.children.length === 1 && !(outer.textContent || '').trim()) {
        outer.parentNode.replaceChild(inner, outer);
      } else {
        break;
      }
    }
    // 3) 去掉纯空白文本节点（避免导出里夹一堆空行）
    return root;
  }
  function importHtml(html) {
    ed.innerHTML = html || '';
    // 把文本里的 [fn]…[/fn] 换成徽章（发布后的正文再次编辑时用）
    var walker = document.createTreeWalker(ed, NodeFilter.SHOW_TEXT, null);
    var jobs = [];
    var re = /\\[fn\\]([\\s\\S]*?)\\[\\/fn\\]/g;
    while (walker.nextNode()) {
      var node = walker.currentNode;
      if (!re.test(node.nodeValue || '')) continue;
      jobs.push(node); re.lastIndex = 0;
    }
    jobs.forEach(function (node) {
      var frag = document.createDocumentFragment();
      var text = node.nodeValue, last = 0, m;
      re.lastIndex = 0;
      while ((m = re.exec(text)) !== null) {
        if (m.index > last) frag.appendChild(document.createTextNode(text.slice(last, m.index)));
        frag.appendChild(makeFn(m[1]));
        last = m.index + m[0].length;
      }
      if (last < text.length) frag.appendChild(document.createTextNode(text.slice(last)));
      node.parentNode.replaceChild(frag, node);
    });
    refreshFnNumbers();
    if (!ed.innerHTML.trim()) ed.innerHTML = '<p><br></p>';
  }

  window.YbhEditor = {
    getPayload: function () {
      refreshFnNumbers();
      var html = exportHtml().trim();
      if (html === '<p><br></p>') html = '';
      return JSON.stringify({ html: html, text: (ed.innerText || '').trim() });
    },
    setHtml: function (html) { importHtml(html); post(); },
    exec: function (cmd, value) {
      restore();
      try { document.execCommand(cmd, false, value === undefined ? null : value); } catch (e) {}
      if (cmd === 'formatBlock' || cmd === 'insertOrderedList' || cmd === 'insertUnorderedList') {
        setTimeout(refreshFnNumbers, 0);
      }
      saveRange(); post();
    },
    inlineCode: function () {
      restore();
      var s = sel();
      var chosen = s && s.rangeCount > 0 ? s.getRangeAt(0).toString() : '';
      document.execCommand('insertHTML', false, '<code>' + esc(chosen) + '</code>&nbsp;');
      saveRange(); post();
    },
    codeBlock: function () {
      insertHtml('<pre><code class="language-text">' + esc('') + '</code></pre><p><br></p>');
      post();
    },
    insertLink: function (url) {
      restore();
      var s = sel();
      var chosen = s && s.rangeCount > 0 ? s.getRangeAt(0).toString() : '';
      var label = chosen && chosen.trim() ? esc(chosen) : esc(url);
      document.execCommand('insertHTML', false,
        '<a href="' + esc(url) + '" target="_blank" rel="noopener">' + label + '</a>');
      saveRange(); post();
    },
    insertImage: function (url, alt) {
      insertHtml('<figure class="wp-block-image"><img src="' + esc(url) + '" alt="' + esc(alt || '') +
        '" loading="lazy"/></figure><p><br></p>');
      post();
    },
    insertFootnote: function () {
      restore();
      var s = sel();
      var chosen = s && s.rangeCount > 0 ? s.getRangeAt(0).toString().trim() : '';
      var wrap = document.createElement('span');
      wrap.className = 'ybh-fn';
      wrap.setAttribute('data-ybh-fn-text', chosen);
      wrap.textContent = chosen || '[fn][/fn]';
      var end = document.createTextNode('\\u00a0');
      var s2 = sel();
      if (s2 && s2.rangeCount > 0 && ed.contains(s2.anchorNode)) {
        var r = s2.getRangeAt(0);
        r.deleteContents();
        r.insertNode(wrap);
        wrap.parentNode.insertBefore(end, wrap.nextSibling);
        r.setStart(end, 1); r.collapse(true);
        s2.removeAllRanges(); s2.addRange(r);
      } else {
        ed.appendChild(wrap); ed.appendChild(end);
      }
      refreshFnNumbers(); saveRange(); post();
      // 立刻把光标放到徽章里，便于直接输入注释文字
      var s3 = sel();
      if (s3) {
        var r3 = document.createRange();
        r3.selectNodeContents(wrap);
        s3.removeAllRanges(); s3.addRange(r3);
      }
      saveRange();
    },
    toggleIndent: function () {
      restore();
      var s = sel();
      if (!s || s.rangeCount === 0) return;
      var node = s.anchorNode;
      node = node && node.nodeType === 3 ? node.parentNode : node;
      var block = node;
      while (block && block !== ed && ['p','h1','h2','h3','h4','h5','h6','blockquote'].indexOf((block.tagName || '').toLowerCase()) < 0) {
        block = block.parentNode;
      }
      if (!block || block === ed) block = node;
      if (block && block.classList) {
        if (block.classList.contains('ybh-indent')) block.classList.remove('ybh-indent');
        else block.classList.add('ybh-indent');
      }
      saveRange(); post();
    },
    clearFormat: function () {
      restore();
      try { document.execCommand('removeFormat', false, null); } catch (e) {}
      try { document.execCommand('formatBlock', false, '<p>'); } catch (e) {}
      saveRange(); post();
    },
    focusEditor: function () { restore(); },
    onPaste: function () {}
  };

  // 粘贴：只保留纯文本（避免把网页样式带进来；与网页端"粘贴为文本"一致）
  ed.addEventListener('paste', function (e) {
    try {
      var t = (e.clipboardData || window.clipboardData).getData('text/plain');
      if (t == null) return;
      e.preventDefault();
      document.execCommand('insertText', false, t);
    } catch (err) {}
  });
  ed.addEventListener('input', function () { clearTimeout(post._t); post._t = setTimeout(post, 120); });
  ed.addEventListener('click', function (e) {
    var el = e.target && e.target.closest ? e.target.closest('.ybh-fn') : null;
    document.querySelectorAll('#editor .ybh-fn.is-open').forEach(function (o) { if (o !== el) o.classList.remove('is-open'); });
    if (el) {
      el.classList.add('is-open');
      var t = el.getAttribute('data-ybh-fn-text') || '';
      el.textContent = '[fn]' + t + '[/fn]';
      el.classList.remove('ybh-fn');
      el.setAttribute('data-was-fn', '1');
      saveRange();
    }
  });
  ed.addEventListener('blur', function () {
    document.querySelectorAll('#editor [data-was-fn]').forEach(function (el) {
      var t = el.textContent.replace(/^\\[fn\\]/, '').replace(/\\[\\/fn\\]\$/, '');
      el.setAttribute('data-ybh-fn-text', t);
      el.classList.add('ybh-fn');
      el.removeAttribute('data-was-fn');
    });
    refreshFnNumbers();
  });

  ed.innerHTML = '<p><br></p>';
  setTimeout(post, 60);
  try { if (window.YbhDiag) window.YbhDiag.postMessage('编辑器就绪'); } catch (e) {}
})();
</script>
</body>
</html>
''';
  }

  @override
  State<RichTextEditor> createState() => _RichTextEditorState();
}

class _RichTextEditorState extends State<RichTextEditor> {
  late final WebViewController _web;
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.dark ? const Color(0xFF333333) : Colors.white)
      ..addJavaScriptChannel(
        'YbhEditorState',
        onMessageReceived: (JavaScriptMessage m) =>
            widget.controller._onStateMessage(m.message),
      )
      ..addJavaScriptChannel(
        'YbhDiag',
        onMessageReceived: (JavaScriptMessage m) =>
            debugPrint('[YBH Editor] ${m.message}'),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            widget.controller._onReady();
          },
          onNavigationRequest: (req) => NavigationDecision.prevent,
        ),
      );
    widget.controller._attach(_web);
    _load();
  }

  Future<void> _load() async {
    if (_loadStarted) return;
    _loadStarted = true;
    final base = '${AppConfig.blogUrl}/';
    // 站点样式 + 打包字体都在首屏之前备好：编辑区一打开就是网页同款观感。
    await Future.wait([
      EmbeddedFonts.instance.prepare(),
      WebStyle.instance.prepare(),
    ]);
    if (!mounted) return;
    await _web.loadHtmlString(
      RichTextEditor.buildHtml(
        dark: widget.dark,
        placeholder: widget.placeholder,
      ),
      baseUrl: base,
    );
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _web);
  }
}
