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

  /// 实际生成的内联规则数（诊断用）。
  int _ruleCount = 0;

  /// 因为资产缺失而**跳过**的规则数（诊断用）。
  ///
  /// 非零就说明 `pubspec.yaml` 的 `assets:` 与清单对不上 —— 这正是 215161b
  /// 那次「清单引用了 slices/ 与 emoji/、而 pubspec 没声明」的故障特征。
  /// 旧实现遇到缺失资产会**整体抛异常**，于是全部字体静默退回站点下载。
  int _skippedCount = 0;

  /// 站点 CSS 里**不删**的 @font-face（按 URL 前缀匹配），交给浏览器按
  /// unicode-range 懒加载。取自清单的 `keepOnSitePrefixes`。
  List<String> _keepPrefixes = const [];

  /// 组装好的整段注入脚本（含 jsonEncode 过的 CSS）。
  ///
  /// 必须在 [prepare] 里**只拼一次**：`_css` 是十几 MB 的字符串，而
  /// [webviewScript] 每次导航都会被取用 —— 放在 getter 里现拼就等于每次
  /// 都给这十几 MB 做一遍转义扫描与分配。
  String _script = '';

  bool get isReady => _loaded && _css.isNotEmpty;
  int get fileCount => _fileCount;
  int get ruleCount => _ruleCount;
  int get skippedCount => _skippedCount;
  List<String> get keepPrefixes => List.unmodifiable(_keepPrefixes);

  /// 替代用 @font-face CSS（data: URI）。阅读器 / 编辑器把这段直接内联进
  /// 本地 HTML 的 `<head>`（站点 CSS 里的 @font-face 已被 WebStyle 剔除）。
  String get css => _css;

  /// 生成好的 CSS 文本长度（诊断用）。
  int get cssBytes => _css.length;

  /// 载入 manifest 并把所有字体读成 base64，拼出替代 CSS。幂等。
  ///
  /// **单条规则失败不影响其余**：某个资产没打进包（pubspec 漏声明目录）时
  /// 只跳过那一条并计数，其余字体照常内联。宁可少几条面，也不要整站退回
  /// 十几 MB 的网络字体。
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
      final keep = <String>[];
      for (final k in (json['keepOnSitePrefixes'] as List<dynamic>? ?? const [])) {
        keep.add(k as String);
      }
      _keepPrefixes = keep;

      final sb = StringBuffer();
      sb.write('/* YBH · 打包字体内联（T30）。描述符逐条对应站点 CSS，'
          'src 换成 data: URI。 */\n');
      final cache = <String, String>{};      // path → base64
      var skipped = 0;
      var emitted = 0;
      for (final r in rules) {
        final path = r['path'] as String;
        final asset = files[path];
        if (asset == null) {
          skipped++;
          continue;
        }
        String b64;
        try {
          b64 = cache[path] ??= base64Encode(
            (await rootBundle.load(asset)).buffer.asUint8List(),
          );
        } catch (e) {
          // 资产没打进包（pubspec 漏了目录）或读失败：跳过这一条，不拖垮整体。
          skipped++;
          debugPrint('[YBH fonts] 跳过 $path（$asset 读不到）：$e');
          continue;
        }
        sb.write('@font-face{');
        sb.write('font-family:"${r['family']}";');
        sb.write('font-style:${r['style'] ?? 'normal'};');
        sb.write('font-weight:${r['weight'] ?? '400'};');
        sb.write('font-display:${r['display'] ?? 'swap'};');
        final ur = r['unicodeRange'] as String?;
        if (ur != null && ur.isNotEmpty) sb.write('unicode-range:$ur;');
        sb.write('src:url(data:font/woff2;base64,$b64) format("woff2");');
        sb.write('}\n');
        emitted++;
      }
      _css = sb.toString();
      _ruleCount = emitted;
      _skippedCount = skipped;
      // 只要还有一条规则成立就算就绪：缺几条面总好过整站退回下载。
      _loaded = emitted > 0;
      _script = _loaded ? _buildScript() : '';
      debugPrint('[YBH fonts] 打包 ${files.length} 个字体 → 内联 $emitted 条规则'
          '（跳过 $skipped），替换 CSS ${_css.length} 字符，'
          '注入脚本 ${_script.length} 字符，'
          '留在站点懒加载前缀 ${_keepPrefixes.length} 条');
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
  ///
  /// ⚠️ 这段脚本里带着整个替换 CSS（十几 MB），**每次注入都要跨平台通道
  /// 传一遍**。所以：① 同一个文档里只应注入一次，后续补注用 [kickScript]；
  /// ② 脚本在 [prepare] 里就拼好缓存（见 `_script`），不在 getter 里现拼。
  String get webviewScript => _script;

  /// 实际拼装注入脚本（只在 [prepare] 里调用一次）。
  String _buildScript() {
    return '''
(function () {
  var CSS = ${jsonEncode(_css)};
  var KEEP = ${jsonEncode(_keepPrefixes)};
  var REPORT = function (t) {
    try { if (window.YbhDiag) { window.YbhDiag.postMessage('字体 | ' + t); } } catch (e) {}
  };
  if (window.__ybhFonts) { window.__ybhFonts.kick(); return; }

  var HOLD_ID = 'ybh-font-hold';
  var STYLE_ID = 'ybh-font-local';
  var PREFIX = '/ybh-fonts/';
  var st = { removed: 0, inserted: 0, lifted: false, t0: Date.now(), liftAt: 0, done: false,
             stable: 0, lastSheets: -1, kept: 0 };

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
    // 闸门只清一次：下面那个 while 是为了吃掉重复插入的闸门节点。
    try {
      var el = document.getElementById(HOLD_ID);
      while (el && el.parentNode) { el.parentNode.removeChild(el); el = document.getElementById(HOLD_ID); }
    } catch (e) {}
    REPORT('本地化完成：删除 ' + st.removed + ' 条站点 @font-face，保留 ' + st.kept +
           ' 条懒加载，插入 ' + st.inserted + ' 条内联规则，闸门 ' + st.liftAt + 'ms');
  }

  // ---- 2) 删掉站点里所有引用 ybh-fonts 的 @font-face（清单标了 keep 的除外）----
  //
  // 必须先把 url 解析成绝对地址：FontAwesome 的 all.min.css 写的是
  // `url(../webfonts/fa-solid-900.woff2)`，字符串里根本没有 "ybh-fonts"。
  //
  // 位置很关键：本样式插在 `<head>` 靠前处，站点样式在后 —— 所以站点保留下来的
  // 分片规则会在“同族同码位后声明者胜”里赢过我们的面，正好实现「基础字体本地、
  // 罕用字按需下载」。**不要为了抢优先级把本样式挪到 head 末尾。**
  function isBundleFont(u, sheetHref) {
    var abs;
    try { abs = new URL(u, sheetHref || location.href).href; } catch (e) { return false; }
    if (abs.indexOf(PREFIX) === -1) return false;
    for (var i = 0; i < KEEP.length; i++) {
      if (abs.indexOf(KEEP[i]) !== -1) return false;
    }
    return true;
  }

  function stripSiteFaces() {
    var n = 0, kept = 0, sheets;
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
        var isKeep = false, isBundle = false;
        for (var k = 0; k < us.length; k++) {
          var u = us[k].replace(/^url\\(\\s*['"]?/, '').replace(/['"]?\\s*\\)\$/, '');
          if (isBundleFont(u, href)) { isBundle = true; break; }
          for (var q = 0; q < KEEP.length; q++) {
            try {
              if (new URL(u, href || location.href).href.indexOf(KEEP[q]) !== -1) isKeep = true;
            } catch (e) {}
          }
        }
        if (isBundle) kill.push(j); else if (isKeep) kept++;
      }
      // 从后往前删，避免索引前移
      for (var m = kill.length - 1; m >= 0; m--) {
        try { sheets[i].deleteRule(kill[m]); n++; } catch (e) {}
      }
    }
    st.kept = kept;   // 覆盖而不是累加：这个函数在放开闸门前会被反复调用
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

  /// 同文档内的「补注」脚本：只有几十字节，用来替代重复注入整段 [webviewScript]。
  ///
  /// 背景：`WebViewScreen` 在 `onProgress`(10/35/65) 与 `onPageFinished` 都会补注，
  /// 早先每次都把整段 11.7 MB 的脚本重新送一遍（一页最多 5 次）⇒ 几十 MB 的无谓
  /// 跨通道传输。现在只在 `onPageStarted` / `onPageFinished` 送整段，其余送这个。
  ///
  /// 若整段从未注入成功（例如它落在了导航前的旧文档上），这里是**空操作**，
  /// 不会有副作用；`onPageFinished` 那次整段注入会兜住。
  static const String kickScript =
      '(function(){try{var f=window.__ybhFonts;if(f&&f.kick)f.kick();}catch(e){}})();';
}
