import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../app_config.dart';
import '../data/embedded_fonts.dart';
import '../data/web_style.dart';

/// 文章正文阅读器（Android / iOS / macOS）。
///
/// ## 为什么是「网页同款」而不是自绘样式
///
/// 旧版阅读器自己写了一套排版（16px + Noto Sans SC），与网页端差异明显：
/// 网页端正文是 `'Sarasa UI SC'` + **20px** 基准字号，正文排版来自主题的
/// `css/content-style/sakura.css`，还有站点「额外 CSS」与主题皮肤变量参与。
/// 自绘永远追不上，所以现在改成：
///
/// 1. 从站点抓取真实用到的 CSS（见 [WebStyle]），**原样内联**进阅读器文档；
/// 2. 正文包在与网页端相同的结构里（`.wrapper > .entry-content`），
///    让主题的 `.entry-content …` 规则逐条命中；
/// 3. 字体改由打包资源供给（[EmbeddedFonts]，data: URI）—— 站点 CSS 里的
///    `@font-face` 已被 [WebStyle] 剔除，避免跨域取不到字体；
/// 4. 深色模式沿用网页端机制：给 `<body>` 加 `dark` 类，主题 `body.dark` 生效。
///
/// 仍然是 WebView 而不是 flutter_html：正文里有 `srcset/sizes` 图片、
/// `<ruby><rt>` 振假名、`<pre><code class="language-*">` 代码块与 iframe 视频，
/// 浏览器原生排版比任何 Dart 侧渲染器都准。
class ArticleWebView extends StatefulWidget {
  const ArticleWebView({
    super.key,
    required this.content,
    required this.dark,
  });

  /// 文章正文 HTML（WordPress REST API rendered 内容）。
  final String content;

  /// 是否深色（跟随 App 内手动夜间模式）。
  final bool dark;

  /// 构造阅读器 HTML 文档。
  static String buildHtml({required String content, required bool dark}) {
    final theme = dark ? 'dark' : 'light';
    return '''
<!DOCTYPE html>
<html lang="zh-Hans">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
<title>YBH</title>
${WebStyle.instance.headHtml()}
</head>
<body class="$theme" data-theme="$theme">
<div class="wrapper">
<div class="ybh-shell">
<div class="entry-content">
$content
</div>
</div>
</div>
<script>
(function () {
  // 代码块：提取 language-* 语言标签 + 添加复制按钮（阅读器增强）。
  function fallbackCopy(text) {
    var ta = document.createElement('textarea');
    ta.value = text;
    ta.style.cssText = 'position:fixed;opacity:0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); } catch (e) {}
    document.body.removeChild(ta);
  }
  document.querySelectorAll('pre').forEach(function (pre) {
    var code = pre.querySelector('code');
    if (!code) return;
    var m = (code.className || '').match(/language-([A-Za-z0-9_+#-]+)/);
    if (m && m[1]) pre.setAttribute('data-lang', m[1]);
    var btn = document.createElement('button');
    btn.className = 'ybh-copy';
    btn.textContent = '复制';
    btn.addEventListener('click', function () {
      var text = code.innerText;
      var done = function () {
        btn.textContent = '已复制';
        setTimeout(function () { btn.textContent = '复制'; }, 1400);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () {
          fallbackCopy(text); done();
        });
      } else {
        fallbackCopy(text); done();
      }
    });
    pre.appendChild(btn);
  });

  // 懒加载图片未带宽高时高度跳动，用 width/height 属性预占位。
  document.querySelectorAll('img[loading="lazy"]').forEach(function (img) {
    if (img.getAttribute('width') && img.getAttribute('height')) {
      var w = parseInt(img.getAttribute('width'), 10);
      var h = parseInt(img.getAttribute('height'), 10);
      if (w > 0 && h > 0 && !img.style.aspectRatio) {
        img.style.aspectRatio = String(w) + ' / ' + String(h);
        img.style.height = 'auto';
      }
    }
  });

  try { if (window.YbhDiag) {
    window.YbhDiag.postMessage('阅读器 | 样式 ' + document.styleSheets.length +
      ' 表 / 正文 ' + document.querySelector('.entry-content').innerHTML.length + ' 字符');
  } } catch (e) {}
})();
</script>
</body>
</html>
''';
  }

  @override
  State<ArticleWebView> createState() => _ArticleWebViewState();
}

class _ArticleWebViewState extends State<ArticleWebView> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(widget.dark ? const Color(0xFF333333) : Colors.white)
      ..addJavaScriptChannel(
        'YbhDiag',
        onMessageReceived: (JavaScriptMessage message) {
          debugPrint('[YBH Reader] ${message.message}');
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (String url) {
            if (mounted) setState(() => _loading = false);
          },
          onNavigationRequest: (NavigationRequest request) {
            // 站内链接留在阅读器里（如文内互链），外部链接交给系统浏览器。
            if (AppConfig.isInAppUrl(request.url)) {
              return NavigationDecision.navigate;
            }
            launchUrl(
              Uri.parse(request.url),
              mode: LaunchMode.externalApplication,
            );
            return NavigationDecision.prevent;
          },
        ),
      );
    _load();
  }

  Future<void> _load() async {
    // 仅调试构建开启 WebView 远程调试（CDP），便于真机验证渲染；发布版不受影响。
    if (kDebugMode) {
      await AndroidWebViewController.enableDebugging(true);
    }
    // 站点样式只抓一轮（进程内缓存）；字体读打包资源。两者都在首屏前备好，
    // 这样第一次渲染就是网页同款排版，不会先闪一下系统字体。
    await Future.wait([
      EmbeddedFonts.instance.prepare(),
      WebStyle.instance.prepare(),
    ]);
    if (!mounted) return;
    await _controller.loadHtmlString(
      ArticleWebView.buildHtml(
        content: widget.content,
        dark: widget.dark,
      ),
      baseUrl: '${AppConfig.blogUrl}/',
    );
  }

  @override
  void didUpdateWidget(covariant ArticleWebView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content || oldWidget.dark != widget.dark) {
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        // 顶部加载进度条（文章 HTML 本地注入，仅资源加载期间短暂显示）。
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: _loading ? 1 : 0,
              duration: const Duration(milliseconds: 250),
              child: const LinearProgressIndicator(
                minHeight: 2,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
