import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

/// 打包进安装包的「网页字体」供给层（T30）。
///
/// ## 问题
///
/// 站点正文用自托管中文字体。2026-09 实测：**一次整站首页加载会拉 19.2 MB 字体**
/// —— TH-Tshyn P0+P1 13.7 MB、Klee One 2.9 MB，其余是 Sarasa 子集与 FontAwesome。
/// 网页端已做过子集化，但 `TH-Tshyn` 是字体栈里排在 `Sarasa UI SC` 之后的兜底面，
/// Android 上没有 PingFang / 雅黑，于是但凡碰到一个 Sarasa 子集没覆盖的字符，
/// 浏览器就去下载那个 5–8 MB 的兜底字体 —— 这正是 App 端「整站页又慢又费流量」的主因。
///
/// ## 方案：把字体打进 APK，用 `data:` URI 顶掉站点规则
///
/// 三步（顺序不能换）：
///
/// 1. **闸门 hold**：页面刚开始加载就注入
///    `*:not(#a):not(#b):not(#c){font-family:<占位族>!important}`。
///    `@font-face` 只在「有元素用到该族」时才下载，没有需求就没有请求。
///    ⚠️ 选择器必须是 `*:not(#id)…` 这种**带 id 的形状**：站点自定义 CSS 里有若干
///    `font-family:…!important`（`.header-info p{Klee One}`、`.center-text{Boxed}`），
///    同层 `!important` 比特指度，`body *`(0,0,2) 会输给 `.header-info p`(0,1,1) ——
///    实测漏的正是这两条。`:not(#x)` 的权重等于其参数，三个叠起来 (3,0,0) 稳压。
///
/// 2. **删掉站点的 @font-face 规则**：站点样式表与本机同源，`document.styleSheets[i].cssRules`
///    可读可写。凡是 `src` 落在 `/ybh-fonts/` 下的规则**整条删除** ——
///    打包过的稍后用我们自己的规则补回来，没打包的（TH-Tshyn、Sarasa J/K/HC/TC 全量族）
///    就此消失，渲染回退系统字体：**既不下载，也不留悬挂引用**。
///
/// 3. **插入我们的规则并放开闸门**：一条 `<style>` 里写全 `@font-face`，
///    `src` 用 `data:font/woff2;base64,…`，`font-family/weight/style/unicode-range`
///    与站点原规则逐条对应（描述符由构建期从站点 CSS 解析进 `manifest.json`）。
///    然后移除闸门，页面用本机字体重排一次。
///
/// ## 为什么不用「本机 HTTP 服务 + url(http://127.0.0.1:port/…)」
///
/// 这条路**走不通**，已实测确认（2026-09，Chromium/Edge）：
/// 页面是 https 公网源，访问回环地址属于 **Local Network Access** 管辖范围，
/// 浏览器直接拒绝并报
/// `Permission was denied for this request to access the 'loopback' address space`
/// —— 请求**根本不会发出**（服务端一个包都收不到），加任何 CORS 头都没用。
/// `data:` URI 不产生请求、不受该策略约束，是 WebView 里唯一可靠的本地字体通道。
///
/// ## 代价与取舍
///
/// · 每次导航要把约 6 MB 的 base64 CSS 交给页面（首帧解析 + 字体解码），
///   换来的是 19.2 MB → 0 的**网络**开销与断网可用；实测注入耗时见 README。
/// · 未打包字体（Klee One SemiBold 等）直接消失，回退系统字体。
class EmbeddedFonts {
  EmbeddedFonts._();

  static final EmbeddedFonts instance = EmbeddedFonts._();

  static const String _manifestAsset = 'assets/fonts/manifest.json';

  bool _loaded = false;
  bool _loading = false;

  /// 替代用 @font-face CSS（data: URI），构建期描述符 + 运行期 base64 拼成。
  String _css = '';

  /// 打包文件数（诊断用）。
  int _fileCount = 0;

  bool get isReady => _loaded && _css.isNotEmpty;
  int get fileCount => _fileCount;

  /// 生成好的 CSS 文本长度（诊断用）。
  int get cssBytes => _css.length;

  /// 载入 manifest 并把所有字体读成 base64，拼出替代 CSS。幂等。
  Future<void> prepare() async {
    if (_loaded || _loading) return;
    _loading = true;
    try {
      final raw = await rootBundle.loadString(_manifestAsset);
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final files = <String, String>{};      // path → asset
      for (final item in (json['files'] as List<dynamic>)) {
        final f = item as Map<String, dynamic>;
        files[f['path'] as String] = f['asset'] as String;
      }
      final rules = (json['rules'] as List<dynamic>).cast<Map<String, dynamic>>();
      _fileCount = files.length;

      final sb = StringBuffer();
      sb.write('/* YBH · 打包字体内联（T30）。描述符逐条对应站点 CSS，'
          'src 换成 data: URI。 */\n');
      final cache = <String, String>{};      // path → base64
      for (final r in rules) {
        final path = r['path'] as String;
        final asset = files[path];
        if (asset == null) continue;
        final b64 = cache[path] ??= base64Encode(
          (await rootBundle.load(asset)).buffer.asUint8List(),
        );
        sb.write('@font-face{');
        sb.write('font-family:"${r['family']}";');
        sb.write('font-style:${r['style'] ?? 'normal'};');
        sb.write('font-weight:${r['weight'] ?? '400'};');
        sb.write('font-display:${r['display'] ?? 'swap'};');
        final ur = r['unicodeRange'] as String?;
        if (ur != null && ur.isNotEmpty) sb.write('unicode-range:$ur;');
        sb.write('src:url(data:font/woff2;base64,$b64) format("woff2");');
        sb.write('}\n');
      }
      _css = sb.toString();
      _loaded = true;
      debugPrint('[YBH fonts] 打包 ${files.length} 个字体，生成替换 CSS ${_css.length} 字符');
    } catch (e) {
      debugPrint('[YBH fonts] 准备失败，退回站点字体: $e');
    } finally {
      _loading = false;
    }
  }

  /// 供 WebView 注入的脚本：闸门 → 删站点规则 → 插我们的规则 → 放开。
  ///
  /// 重复注入安全（状态挂在 `window.__ybhFonts` 上）；
  /// 未准备好时返回空串，调用方跳过即可。
  String get webviewScript {
    if (!isReady) return '';
    return '''
(function () {
  var CSS = ${jsonEncode(_css)};
  var REPORT = function (t) {
    try { if (window.YbhDiag) { window.YbhDiag.postMessage('字体 | ' + t); } } catch (e) {}
  };
  if (window.__ybhFonts) { window.__ybhFonts.kick(); return; }

  var HOLD_ID = 'ybh-font-hold';
  var STYLE_ID = 'ybh-font-local';
  var PREFIX = '/ybh-fonts/';
  var st = { removed: 0, inserted: 0, lifted: false, t0: Date.now(), liftAt: 0, done: false,
             stable: 0, lastSheets: -1 };

  // ---- 1) 闸门 ----
  function hold() {
    if (st.lifted) return;
    try {
      if (document.getElementById(HOLD_ID)) return;
      var s = document.createElement('style');
      s.id = HOLD_ID;
      s.appendChild(document.createTextNode(
        '*:not(#ybh-fh-a):not(#ybh-fh-b):not(#ybh-fh-c){font-family:"YBH Font Hold",' +
        'system-ui,-apple-system,"Noto Sans CJK SC","Source Han Sans SC",sans-serif!important}'));
      (document.head || document.documentElement).appendChild(s);
    } catch (e) {}
  }

  function lift() {
    if (st.lifted) return;
    st.lifted = true;
    st.liftAt = Date.now() - st.t0;
    try {
      var el = document.getElementById(HOLD_ID);
      while (el && el.parentNode) { el.parentNode.removeChild(el); el = document.getElementById(HOLD_ID); }
    } catch (e) {}
    REPORT('本地化完成：删除 ' + st.removed + ' 条站点 @font-face，插入 ' + st.inserted +
           ' 条内联规则，闸门 ' + st.liftAt + 'ms');
  }

  // ---- 2) 删掉站点里所有引用 ybh-fonts 的 @font-face ----
  //
  // 必须先把 url 解析成绝对地址：FontAwesome 的 all.min.css 写的是
  // `url(../webfonts/fa-solid-900.woff2)`，字符串里根本没有 "ybh-fonts"。
  function isBundleFont(u, sheetHref) {
    var abs;
    try { abs = new URL(u, sheetHref || location.href).href; } catch (e) { return false; }
    return abs.indexOf(PREFIX) !== -1;
  }

  function stripSiteFaces() {
    var n = 0, sheets;
    try { sheets = document.styleSheets; } catch (e) { return 0; }
    for (var i = 0; i < sheets.length; i++) {
      if (sheets[i].ownerNode && sheets[i].ownerNode.id === STYLE_ID) continue;
      var rules, href;
      try { rules = sheets[i].cssRules; href = sheets[i].href; } catch (e) { continue; }
      if (!rules) continue;
      var kill = [];
      for (var j = 0; j < rules.length; j++) {
        var r = rules[j];
        if (r.type !== 5) continue;
        var src;
        try { src = r.style.getPropertyValue('src'); } catch (e) { continue; }
        if (!src) continue;
        var us = src.match(/url\\(\\s*(['"]?)([^'")]+)\\1\\s*\\)/g) || [];
        for (var k = 0; k < us.length; k++) {
          var u = us[k].replace(/^url\\(\\s*['"]?/, '').replace(/['"]?\\s*\\)\$/, '');
          if (isBundleFont(u, href)) { kill.push(j); break; }
        }
      }
      // 从后往前删，避免索引前移
      for (var m = kill.length - 1; m >= 0; m--) {
        try { sheets[i].deleteRule(kill[m]); n++; } catch (e) {}
      }
    }
    return n;
  }

  // ---- 3) 插入我们的内联规则 ----
  function insertLocal() {
    if (document.getElementById(STYLE_ID)) return 1;
    try {
      var s = document.createElement('style');
      s.id = STYLE_ID;
      s.appendChild(document.createTextNode(CSS));
      (document.head || document.documentElement).appendChild(s);
      return 1;
    } catch (e) { return 0; }
  }

  function kick() {
    hold();
    if (!st.done) {
      var removed = stripSiteFaces();
      st.removed += removed;
      st.inserted = insertLocal();

      // 何时可以放开闸门：站点样式表都在 <head> 里，等「样式表数量连续几拍不变」
      // 就说明 CSSOM 已经齐了。**不要等 DOMContentLoaded** —— 本站同步脚本很多，
      // 实测 DOMContentLoaded 要 3 秒后才到，那样用户会盯着系统字体看 3 秒。
      var sheets = 0;
      try { sheets = document.styleSheets.length; } catch (e) {}
      if (sheets === st.lastSheets) { st.stable++; } else { st.stable = 0; st.lastSheets = sheets; }

      var settled = st.removed > 0 && st.inserted > 0 && st.stable >= 8;   // ≈80ms 无新样式表
      var ready = document.readyState !== 'loading';
      if (settled || (st.removed > 0 && ready) || Date.now() - st.t0 > 2000) {
        st.done = true;
        lift();
      }
    } else if (!st.lifted) {
      lift();
    }
  }

  window.__ybhFonts = { kick: kick, state: st, strip: stripSiteFaces, insert: insertLocal, lift: lift };
  hold();
  kick();

  var ticks = 0;
  var timer = setInterval(function () {
    ticks++;
    kick();
    if (st.lifted || ticks > 600) { clearInterval(timer); }
  }, 10);
  document.addEventListener('DOMContentLoaded', kick);
  window.addEventListener('load', kick);
})();
''';
  }
}
