import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as htmlparser;
import 'package:http/http.dart' as http;

import '../app_config.dart';
import 'embedded_fonts.dart';

/// 「网页同款样式壳」：把站点文章页真实用到的 CSS 抓下来缓存，
/// 供阅读器 / 编辑器在本地 HTML 里内联，从而与网页端排版逐条一致。
///
/// 为什么这么做（而不是自己写一份阅读器样式）：
/// - 本站正文字体是 `'Sarasa UI SC'`、基准字号 **20px**（由 `inc/decorate.php`
///   的 `body{font-family…!important;font-size:20px}` 决定），
///   正文排版来自主题的 `css/content-style/<风格>.css`；
///   任何"自绘"样式都必然与网页端有肉眼可见的差异（旧阅读器就是 16px + Noto Sans SC）。
/// - CSS 变量（`--theme-skin` / `--theme-skin-matching` / `--inline_code_background_color`
///   / `--theme-skin-dark` …）与站点「额外 CSS」都由 PHP 内联在 `<head>` 里，
///   只能从真实页面取。
///
/// 实现要点：
/// 1. 抓站点首页（与文章页的样式表集合完全一致，实测核对过）→ 解析
///    `<head>` 里的 `<link rel=stylesheet>` 与内联 `<style>`；
/// 2. 只保留主题 / block-library / ruby 插件 / 站点字体目录这几类样式表，
///    跳过 QSM 等与本任务无关的插件 CSS；
/// 3. 抓这些样式表的文本，**剔除其中的 `@font-face`**（站点的字体 URL 在
///    WebView 里跨域取不到），改由 [EmbeddedFonts] 的 data: URI 面孔供给
///    —— 与「整站」页（T30）同一套字体来源，保证观感一致；
/// 4. 全部结果在内存里缓存一次，同一进程内只抓一轮。
///
/// 失败时 [isReady] 为 false，调用方退回 [fallbackCss]（见 [headHtml]）。
class WebStyle {
  WebStyle._();

  static final WebStyle instance = WebStyle._();

  /// 只保留这些路径下的样式表（其余视为与本任务无关，如 QSM 插件样式）。
  static const List<String> _keepPaths = <String>[
    '/themes/SakurairoYBH/', // 主题合并端点 + ybh.css
    '/wp-includes/css/', // block-library / dashicons
    '/uploads/ybh-fonts/', // FontAwesome（正文里可能用到图标）
    '/plugins/ruby-markup-converter/', // 振假名
  ];

  static const Duration _timeout = Duration(seconds: 20);

  bool _ready = false;
  bool _loading = false;

  /// `<head>` 里与正文相关的样式，**严格按页面里的文档顺序**拼接。
  ///
  /// 顺序不能乱：主题 `style.css` 里 `body{font-size:15px}`，而站点
  /// `inc/decorate.php` 输出的内联样式在**后面**用 `body{font-size:20px}` 覆盖它。
  /// 一旦把内联样式提到样式表之前，正文就会缩成 15px —— 这正是首版实现
  /// 与网页端不一致（比值 0.75）的原因。
  String _headCss = '';

  int _sheetCount = 0;
  int _inlineCount = 0;
  int _bytes = 0;
  String? _error;

  bool get isReady => _ready;
  bool get isLoading => _loading;
  String? get error => _error;

  /// 抓到的样式表数量（诊断用）。
  int get sheetCount => _sheetCount;

  /// 内联后的总字节数（诊断用）。
  int get bytes => _bytes;

  /// 抓取并缓存。幂等；并发调用只会真正跑一次。
  Future<void> prepare() async {
    if (_ready || _loading) return;
    _loading = true;
    try {
      final base = Uri.parse(AppConfig.blogUrl);
      final pageUri = Uri.parse('${AppConfig.blogUrl}/');
      final pageHtml = await _getText(pageUri);
      if (pageHtml == null) {
        _error = '抓取站点页面失败';
        return;
      }

      final doc = htmlparser.parse(pageHtml);
      final head = doc.head ?? doc.documentElement;
      final buf = StringBuffer();
      final fetched = <String>{};
      if (head != null) {
        // querySelectorAll 返回文档顺序，这正是我们要的。
        for (final el in head.querySelectorAll('link, style')) {
          final tag = el.localName;
          if (tag == 'link') {
            final rel = (el.attributes['rel'] ?? '').toLowerCase();
            if (!rel.split(' ').contains('stylesheet')) continue;
            final raw = el.attributes['href'];
            if (raw == null || raw.trim().isEmpty) continue;
            final abs = _resolve(base, raw.trim());
            if (abs == null) continue;
            if (!_keepPaths.any(abs.path.contains)) continue;
            final url = abs.toString();
            if (!fetched.add(url)) continue; // 页面里同一个 URL 出现两次
            final css = await _getText(abs);
            if (css == null || css.isEmpty) continue;
            buf
              ..writeln('/* === $url === */')
              ..writeln(_stripFontFaces(css));
            _sheetCount++;
          } else {
            final id = (el.attributes['id'] ?? '').toLowerCase();
            if (id.contains('qsm')) continue; // 问卷插件，与本任务无关
            final text = el.text;
            if (text.trim().isEmpty) continue;
            buf
              ..writeln('/* === inline ${id.isEmpty ? '(anon)' : id} === */')
              ..writeln(text);
            _inlineCount++;
          }
        }
      }
      _headCss = buf.toString();
      _bytes = _headCss.length;
      _ready = _headCss.isNotEmpty;
      if (!_ready) _error = '没有取到任何样式';
      debugPrint('[YBH webstyle] 样式表 $_sheetCount 个 / 内联 $_inlineCount 段 '
          '→ 共 $_bytes 字符');
    } catch (e) {
      _error = '$e';
      debugPrint('[YBH webstyle] 失败，退回内置兜底样式: $e');
    } finally {
      _loading = false;
    }
  }

  /// 站点样式表里的 `@font-face` 一律剔除：字体改由打包资源（data: URI）供给。
  ///
  /// 注意压缩过的 CSS 里没有换行，所以用 `[^}]*` 匹配规则体（@font-face 体里
  /// 不会出现 `}`）。
  static String _stripFontFaces(String css) {
    return css.replaceAllMapped(
      RegExp(r'@font-face\s*\{[^}]*\}', caseSensitive: false),
      (m) {
        final body = m.group(0)!;
        return body.contains('ybh-fonts') ? '/* @font-face 由打包字体供给 */' : body;
      },
    );
  }

  static Uri? _resolve(Uri base, String raw) {
    try {
      return base.resolve(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _getText(Uri uri) async {
    try {
      final r = await http.get(uri).timeout(_timeout);
      if (r.statusCode != 200) return null;
      // CSS/HTML 都是 UTF-8；用 bodyBytes 解码，避免 http 包按 latin1 猜。
      return utf8.decode(r.bodyBytes, allowMalformed: true);
    } catch (e) {
      debugPrint('[YBH webstyle] GET $uri 失败: $e');
      return null;
    }
  }

  /// 兜底样式：站点 CSS 没抓到（离线 / 站点异常）时，至少保证
  /// 字体族、基准字号、行高与网页端一致，而不是退回系统默认。
  static const String fallbackCss = '''
/* 兜底：与网页端同族的字体栈与基准字号（站点 CSS 未取到时使用） */
body {
  font-family: 'Sarasa UI SC', 'PingFang SC', 'Microsoft YaHei', sans-serif;
  font-size: 20px;
  line-height: 1.8;
}
''';

  /// 阅读器 / 编辑器的「外壳」样式：只放我们自己需要的那几件事
  /// （页边距、滚动、图片自适应、代码块复制按钮、深色底），排版交给站点 CSS。
  static const String shellCss = r'''
html, body { margin: 0; padding: 0; }
/* ===== 恢复纵向滚动（真机验收抓出的 bug）=====
   站点 `inc/decorate.php` 在开启「预加载动画」时会随内联样式输出
       html { overflow-y: hidden; }
   它依赖主题的预载 JS 在加载结束把这条规则撤掉。而阅读器/编辑器**只内联了 CSS、
   没有那份 JS** ⇒ 文档被永久锁死，正文完全不能滚动（真机上表现为「页面纹丝不动」）。
   本站 `iro_opt('preload_animation')` 为开，所以线上页面里确实带着这条规则。
   这里显式恢复：shell 样式排在站点 CSS **之后**，同特指度后声明者胜。 */
html { overflow-y: auto; }
html { -webkit-text-size-adjust: 100%; -webkit-font-smoothing: antialiased; }
body {
  background: #fff;
  overflow-wrap: break-word;
}
body.dark { background: var(--dark-bg-primary, rgba(51,51,51,1)); }
.ybh-shell { padding: 14px 18px 48px; }
/* 图片：随容器宽度缩放（网页端同样受容器约束，这里只是把上限写死防止溢出） */
img { max-width: 100% !important; height: auto !important; }
figure { max-width: 100%; }
iframe, video { max-width: 100%; }
/* 表格允许横向滚动，避免窄屏溢出（与网页端 .entry-content 行为一致） */
table { max-width: 100%; }
/* 代码块复制按钮（阅读器增强，不影响排版） */
pre { position: relative; }
.ybh-copy {
  position: absolute; top: 6px; right: 8px;
  padding: 3px 10px; font-size: 11px; line-height: 1.6;
  color: #667085; background: rgba(127,127,127,.12);
  border: 1px solid rgba(127,127,127,.25); border-radius: 6px;
}
.ybh-copy:active { opacity: .7; }
''';

  /// 组装 `<head>` 片段：站点样式（**按文档顺序**）→ 打包字体 → 外壳样式。
  ///
  /// 站点样式必须在最前（顺序由 [prepare] 保证），外壳只做补充不做覆盖。
  /// 深色模式不靠这里切换，而是由调用方给 `<body>` 加 `dark` 类
  /// （与网页端 `body.dark` 同一套机制）。
  String headHtml() {
    final sb = StringBuffer();
    if (_headCss.isEmpty) {
      sb.writeln('<style id="ybh-fallback">$fallbackCss</style>');
    } else {
      sb.writeln('<style id="ybh-site">$_headCss</style>');
    }
    final fonts = EmbeddedFonts.instance.css;
    if (fonts.isNotEmpty) {
      sb.writeln('<style id="ybh-fonts">$fonts</style>');
    }
    sb.writeln('<style id="ybh-shell">$shellCss</style>');
    return sb.toString();
  }
}
