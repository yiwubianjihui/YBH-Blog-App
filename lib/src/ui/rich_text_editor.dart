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

/// 查找 / 替换的状态（面板上「第 N / 共 M 处」那一行）。
///
/// 语义对齐网页端 T33：命中数来自**文本节点**匹配，与标签、属性无关。
@immutable
class EditorFindState {
  const EditorFindState({
    this.query = '',
    this.count = 0,
    this.index = 0,
    this.caseSensitive = false,
  });

  final String query;
  final int count;
  final int index;
  final bool caseSensitive;

  bool get hasQuery => query.isNotEmpty;
  bool get found => count > 0;

  /// 1 基的当前位置（无命中为 0）。
  int get position => count == 0 ? 0 : index + 1;

  static const EditorFindState empty = EditorFindState();

  static EditorFindState fromJson(Map<String, dynamic> j) => EditorFindState(
        query: (j['query'] ?? '').toString(),
        count: (j['count'] is int) ? j['count'] as int : 0,
        index: (j['index'] is int) ? j['index'] as int : 0,
        caseSensitive: j['caseSensitive'] == true,
      );

  /// 面板上显示的一行提示。
  String get label {
    if (!hasQuery) return '';
    return found ? '第 $position / 共 $count 处' : '未找到';
  }
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

  /// 当前选中的纯文本（打开查找面板时预填，网页端同样这么做）。
  Future<String> selectionText() async {
    final raw = await _evalString('window.YbhEditor.selectionText()');
    return raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// 设定查找词并跳到第一处。
  Future<EditorFindState> find(String query, {bool caseSensitive = false}) async {
    final r = await _evalJson(
        'window.YbhEditor.find(${jsonEncode(query)}, $caseSensitive)');
    return r == null ? EditorFindState.empty : EditorFindState.fromJson(r);
  }

  /// 上一个（-1）/ 下一个（1），循环。
  Future<EditorFindState> findStep(int delta) async {
    final r = await _evalJson('window.YbhEditor.findStep($delta)');
    return r == null ? EditorFindState.empty : EditorFindState.fromJson(r);
  }

  /// 替换当前命中（[all] 为 true 时全部替换；替换为空串表示删除）。
  Future<EditorFindState> findReplace(String replace, {bool all = false}) async {
    final r = await _evalJson(
        'window.YbhEditor.findReplace(${jsonEncode(replace)}, $all)');
    return r == null ? EditorFindState.empty : EditorFindState.fromJson(r);
  }

  /// 关闭查找面板时清掉查询与高亮。
  Future<void> findClear() => _js('window.YbhEditor.findClear()');

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

  /// 求一个返回**字符串**的表达式（如 `selectionText()`）。
  Future<String> _evalString(String expr) async {
    final web = _web;
    if (web == null) return '';
    try {
      return _unwrap(await web.runJavaScriptReturningResult(expr));
    } catch (e) {
      debugPrint('[YBH editor] eval 失败: $e');
      return '';
    }
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
        // 编辑器里的诊断信息（例如「折叠光标下发样式有没有落成 DOM」）
        final dbg = decoded['dbg'];
        if (dbg is String && dbg.isNotEmpty) {
          debugPrint('[YBH EditorDbg] $dbg');
        }
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
#editor { outline: none; min-height: 60vh; position: relative; }
/* 占位提示：由 JS 按内容有无挂 .is-empty 类来控制（见 refreshEmpty 的注释） */
#editor.is-empty::before {
  content: $ph;
  position: absolute;
  top: 0;
  left: 0;
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

  // 空文档时给 #editor 挂 .is-empty，用于显示占位提示。
  // 为什么不用 CSS 的 :empty —— 初始文档是 `<p><br></p>`，`<br>` 也算子节点，
  // `p:empty` / `#editor:empty` 都不成立，占位提示就永远不会出现（真机验收发现）。
  function refreshEmpty() {
    var hasText = (ed.innerText || '').trim().length > 0;
    var hasBlock = !!ed.querySelector('img,figure,pre,iframe,video,table,hr,.ybh-fn');
    ed.classList.toggle('is-empty', !hasText && !hasBlock);
  }

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
    try {
      // 去掉「先点按钮再打字」用的零宽空格，否则空文档也会显示 1 字
      text = (ed.innerText || '').replace(/\\s+/g, ' ')
          .split(String.fromCharCode(0x200b)).join('').trim();
    } catch (e) {}
    var inFn = false;
    try {
      var s = window.getSelection();
      var a = s && s.anchorNode ? (s.anchorNode.nodeType === 3 ? s.anchorNode.parentNode : s.anchorNode) : null;
      inFn = !!(a && a.closest && a.closest('.ybh-fn'));
    } catch (e) {}
    var st = {
      bold: q('bold'), italic: q('italic'), strike: q('strikeThrough'),
      ul: q('insertUnorderedList'), ol: q('insertOrderedList'),
      block: block, chars: text.length, fn: inFn,
      dbg: dbgMsg
    };
    dbgMsg = '';
    try { YbhEditorState.postMessage(JSON.stringify(st)); } catch (e) {}
    try { refreshEmpty(); } catch (e) {}
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

  // ---- 让「先点按钮、再打字」真的生效（Android WebView 专项补丁）----
  // 桌面 Chromium 里，光标折叠时执行 execCommand('bold') 会设置一个"待生效样式"，
  // 之后输入的文字继承它。**Android WebView 不会**（真机实测：点 B 后按钮不高亮、
  // 打出来的字也不粗；同一份 JS 在桌面 Edge 上却是好的，见 T34c 交接文档 §六）。
  // 对策：把样式落成真实 DOM —— 在光标处插一个 `<b>零宽空格</b>` 并把光标移进元素内部，
  // 之后输入的文字就天然继承该样式。零宽空格在导出时会被 normalize() 清掉，不会进正文。
  var ZWSP = String.fromCharCode(0x200b);
  var INLINE_CMD = { bold: 'b', italic: 'i', strikeThrough: 's' };

  // 诊断信息：随 post() 一起回传 Dart，由 debugPrint 落到 logcat。
  // （WebView 的 console.log 在 release 包里不会进 logcat，所以走这条通道。）
  var dbgMsg = '';
  function dbg(s) { dbgMsg = s; }

  // 取当前光标；拿不到（或选区不在编辑器里）就把光标放到编辑器末尾再返回。
  // Android WebView 在按钮夺焦后经常出现「有选区对象但 rangeCount=0」，此时
  // 直接用 getSelection() 会静默失败——这是上一版补丁没生效的原因。
  function ensureCaret() {
    try {
      var s = sel();
      if (s && s.rangeCount > 0) {
        var cur = s.getRangeAt(0);
        if (ed.contains(cur.startContainer)) return cur;
      }
    } catch (e) {}
    try {
      ed.focus();
      var r = document.createRange();
      r.selectNodeContents(ed);
      r.collapse(false);
      var s2 = sel();
      if (s2) { s2.removeAllRanges(); s2.addRange(r); }
      return r;
    } catch (e) {
      console.log('[YbhDbg] ensureCaret failed: ' + e);
      return null;
    }
  }

  function materializeInline(tag) {
    var r = ensureCaret();
    if (!r) { dbg('materialize:' + tag + ' 无光标'); return; }
    try {
      var el = document.createElement(tag);
      var t = document.createTextNode(ZWSP);
      el.appendChild(t);
      r.deleteContents();
      r.insertNode(el);
      var nr = document.createRange();
      nr.setStart(t, t.length);
      nr.collapse(true);
      var s = sel();
      if (s) { s.removeAllRanges(); s.addRange(nr); }
      saveRange();
      dbg('materialize:' + tag + ' 成功 -> ' + ed.innerHTML.slice(0, 70));
    } catch (e) {
      // Range API 失败时退回 execCommand('insertHTML')
      try {
        document.execCommand('insertHTML', false,
            '<' + tag + '>' + ZWSP + '</' + tag + '>');
        dbg('materialize:' + tag + ' Range失败改用insertHTML -> ' + ed.innerHTML.slice(0, 70));
      } catch (e2) {
        dbg('materialize:' + tag + ' 彻底失败 ' + e + ' / ' + e2);
      }
    }
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
    // 4) 清掉「先点按钮再打字」用的零宽空格；若因此留下空的格式元素，一并删掉
    var zw = String.fromCharCode(0x200b);
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var hit = [];
    while (walker.nextNode()) {
      if (walker.currentNode.nodeValue.indexOf(zw) >= 0) hit.push(walker.currentNode);
    }
    for (var k = 0; k < hit.length; k++) {
      hit[k].nodeValue = hit[k].nodeValue.split(zw).join('');
    }
    var INLINE_TAGS = 'b,strong,i,em,s,strike,u';
    var empties = root.querySelectorAll(INLINE_TAGS);
    for (var e2 = empties.length - 1; e2 >= 0; e2--) {
      var el2 = empties[e2];
      if (el2.parentNode && !el2.textContent && !el2.querySelector('img,br')) {
        el2.parentNode.removeChild(el2);
      }
    }
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

  /* ===== 查找 / 替换（对齐网页端 T33 的 js/ybh-post-editor.js）=====
     要点：**只改文本节点**，从不碰标签与属性 —— 所以不会把 <a href="…"> 的地址
     或 <strong> 的嵌套改坏（网页端那条的注释也是这么写的）。
     匹配不重叠、向右推进；上限 5000 处，避免病态查询把 UI 卡死。
     命中定位走 Range/Selection（**不改 DOM**），所以反复「下一个」不会留下残留。 */
  var fr = { query: '', caseSensitive: false, matches: [], index: 0 };

  function frTextNodes() {
    var out = [];
    var walker = document.createTreeWalker(ed, NodeFilter.SHOW_TEXT, {
      acceptNode: function (n) {
        var p = n.parentNode;
        if (!p) return NodeFilter.FILTER_REJECT;
        var tag = (p.nodeName || '').toLowerCase();
        if (tag === 'script' || tag === 'style') return NodeFilter.FILTER_REJECT;
        if (!n.nodeValue) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var n;
    while ((n = walker.nextNode())) out.push(n);
    return out;
  }

  function frRecollect() {
    fr.matches = [];
    if (!fr.query) return;
    var needle = fr.caseSensitive ? fr.query : fr.query.toLowerCase();
    var nodes = frTextNodes();
    for (var i = 0; i < nodes.length; i++) {
      var data = nodes[i].nodeValue || '';
      var probe = fr.caseSensitive ? data : data.toLowerCase();
      var from = 0, at;
      while ((at = probe.indexOf(needle, from)) !== -1) {
        fr.matches.push({ node: nodes[i], start: at, end: at + fr.query.length });
        from = at + fr.query.length;
        if (fr.matches.length > 5000) return;
      }
    }
  }

  function frState() {
    return JSON.stringify({
      query: fr.query, count: fr.matches.length, index: fr.index,
      caseSensitive: fr.caseSensitive
    });
  }

  function frFocus() {
    if (!fr.matches.length) { saveRange(); return; }
    var m = fr.matches[fr.index];
    if (!m || !m.node || !m.node.parentNode) return;
    // 替换过之后节点文本可能变短，越界就直接放弃这一处（下次会重算）。
    if (m.end > (m.node.nodeValue || '').length) return;
    try {
      var r = document.createRange();
      r.setStart(m.node, m.start);
      r.setEnd(m.node, m.end);
      var s = sel();
      if (s) { s.removeAllRanges(); s.addRange(r); }
      var p = m.node.parentNode;
      if (p && p.scrollIntoView) p.scrollIntoView({ block: 'center' });
    } catch (e) {}
    // 把当前选区存成"待应用格式"的目标：找到之后点加粗，作用于这一处。
    saveRange();
  }

  function frSetIndex(i) {
    if (!fr.matches.length) { fr.index = 0; return; }
    var n = fr.matches.length;
    fr.index = ((i % n) + n) % n;
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
      var wasCollapsed = true;
      try {
        var s0 = sel();
        wasCollapsed = !(s0 && s0.rangeCount > 0 && !s0.getRangeAt(0).collapsed);
      } catch (e) {}
      try { document.execCommand(cmd, false, value === undefined ? null : value); } catch (e) {}
      // 折叠光标下的行内命令：若引擎没把样式"挂上"（Android WebView 即是如此），
      // 就用真实 DOM 补一个空格式元素，让后续输入继承。桌面已生效则跳过，行为不变。
      if (wasCollapsed && INLINE_CMD[cmd]) {
        var took = false;
        try { took = !!document.queryCommandState(cmd); } catch (e) {}
        // ⚠️ **不能用 took 决定要不要补 DOM**：真机实测 Android WebView
        // 在这里返回 took=true（它认为命令成功了），但随后由输入法提交的文字
        // **并不会**继承这个"待生效样式"，打出来照样不是粗体。
        // 只有把样式落成真实 DOM（光标落进 <b> 里面）才真正管用，所以一律执行。
        // 桌面 Chromium 上这条也是安全的：光标已在 <b> 内，浏览器不会重复嵌套同种内联样式。
        dbg('exec ' + cmd + ' collapsed=' + wasCollapsed + ' took=' + took + ' -> 补DOM');
        materializeInline(INLINE_CMD[cmd]);
      }
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
    onPaste: function () {},

    /* ---- 查找 / 替换（T34 遗留项，对齐网页端 T33）---- */

    /** 当前选中的纯文本（打开面板时预填查找框，网页端也是这么做的）。 */
    selectionText: function () {
      try {
        var s = sel();
        if (!s || !s.rangeCount) return '';
        return String(s.toString() || '').replace(/\\s+/g, ' ').trim().slice(0, 60);
      } catch (e) { return ''; }
    },

    /** 设定查询词并跳到第一处；返回 {query,count,index,caseSensitive}。 */
    find: function (query, caseSensitive) {
      fr.query = String(query == null ? '' : query);
      fr.caseSensitive = !!caseSensitive;
      fr.index = 0;
      frRecollect();
      frFocus();
      return frState();
    },

    /** 上一个 / 下一个（delta = -1 / 1），循环。 */
    findStep: function (delta) {
      if (!fr.matches.length) frRecollect();
      if (!fr.matches.length) return frState();
      frSetIndex(fr.index + (delta || 1));
      frFocus();
      return frState();
    },

    /**
     * 替换。all=false 只替换当前命中；all=true 全部替换。
     * 全部替换按节点分组、每节点内**从后往前**改，避免偏移失效。
     * 替换为空串表示删除（网页端亦然）。
     */
    findReplace: function (replace, all) {
      if (!fr.matches.length) frRecollect();
      if (!fr.matches.length) return frState();
      var rep = String(replace == null ? '' : replace);
      if (all) {
        var byNode = [];
        for (var i = 0; i < fr.matches.length; i++) {
          var m = fr.matches[i];
          var last = byNode[byNode.length - 1];
          if (last && last.node === m.node) { last.items.push(m); }
          else { byNode.push({ node: m.node, items: [m] }); }
        }
        for (var j = 0; j < byNode.length; j++) {
          var g = byNode[j];
          if (!g.node || !g.node.parentNode) continue;
          var data = g.node.nodeValue || '';
          for (var k = g.items.length - 1; k >= 0; k--) {
            var it = g.items[k];
            if (it.end > data.length) continue;
            data = data.slice(0, it.start) + rep + data.slice(it.end);
          }
          g.node.nodeValue = data;
        }
        fr.index = 0;
      } else {
        var c = fr.matches[fr.index];
        if (c && c.node && c.node.parentNode) {
          var d = c.node.nodeValue || '';
          if (c.end <= d.length) {
            c.node.nodeValue = d.slice(0, c.start) + rep + d.slice(c.end);
          }
        }
        frRecollect();
        if (fr.index >= fr.matches.length) fr.index = 0;
      }
      frRecollect();
      frFocus();
      post();
      return frState();
    },

    /** 关闭面板时清掉查询与选区高亮。 */
    findClear: function () {
      fr.query = '';
      fr.matches = [];
      fr.index = 0;
      try { var s = sel(); if (s) s.removeAllRanges(); } catch (e) {}
      return frState();
    },
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
