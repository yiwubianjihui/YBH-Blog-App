import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/data/web_style.dart';
import 'package:yibianhui_blog/src/ui/article_reader_view.dart';

/// **开发用取样器**（不是断言型测试）：把阅读器真实生成的 HTML 落到磁盘，
/// 供浏览器侧量算字号层级（`_probe_dir/reader_typography.js`）。
///
/// 为什么要绕这一圈：阅读器是「内联站点 CSS」的 WebView，字号最终由
/// 站点 CSS（主题选项 + content-style）与 App 的 `shellCss` 共同决定。
/// 只看 Dart 源码猜不出真实生效值 —— 必须让浏览器把 CSS 级联算完再说。
///
/// 运行：
///   flutter test test/reader_dump_test.dart
/// 产物：
///   E:\dsh\.tmp\reader.html
void main() {
  test('导出阅读器 HTML 供字号取样', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    // 抓一轮线上样式（网络失败时 WebStyle 会退回 fallbackCss，那也是一种真实情形）
    await WebStyle.instance.prepare();
    final html = ArticleWebView.buildHtml(
      content: '<h2>二级标题</h2>'
          '<p>正文一段，用来量正文字号。正文一段，用来量正文字号。正文一段，用来量正文字号。</p>'
          '<h3>三级标题</h3><p>再一段正文。</p>'
          '<blockquote><p>引用里的一段话。</p></blockquote>'
          '<pre><code class="language-dart">var x = 1;</code></pre>'
          '<ul><li>列表项一</li><li>列表项二</li></ul>',
      dark: false,
      headerHtml: '<header class="ybh-article-head">'
          '<h1 class="ybh-title">文章标题</h1>'
          '<div class="ybh-article-meta"><span>2026-09-22</span>'
          '<span class="ybh-cat">分类</span></div>'
          '</header>',
    );
    final out = File(r'E:\dsh\.tmp\reader.html');
    out.writeAsStringSync(html);
    // ignore: avoid_print
    print('DUMPED ${html.length} chars -> ${out.path} '
        '(webstyle ready=${WebStyle.instance.isReady}, '
        'sheets=${WebStyle.instance.sheetCount}, bytes=${WebStyle.instance.bytes})');
    expect(html, contains('class="entry-content"'));
  });
}
