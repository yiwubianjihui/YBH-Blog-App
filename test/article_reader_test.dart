import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/data/embedded_fonts.dart';
import 'package:yibianhui_blog/src/ui/article_reader_view.dart';

/// 阅读器 HTML 的契约测试。
///
/// ⚠️ 本文件在 2026-08-29 写的第一版断言的是**旧的「自绘排版」阅读器**
/// （`class="ybh-article"`、`--bg: #121417`、内联 `ruby rt` 样式…）。
/// T34c 把阅读器改成「内联站点 CSS、正文包 `.wrapper > .entry-content`、
/// 字体由打包资源供给」之后，那两条断言就一直红着 —— 红的测试等于没有测试，
/// 所以这里按**当前设计**重写，并补上一条真正端到端的字体断言。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ArticleWebView.buildHtml', () {
    test('包含阅读器核心结构', () {
      final html = ArticleWebView.buildHtml(
        content: '<p>你好</p>',
        dark: false,
      );
      expect(html, contains('<!DOCTYPE html>'));
      // 站点 CSS 依赖 lang 选字（lang 错了 code/pre 会落到别的字体）。
      expect(html, contains('lang="zh-Hans"'));
      expect(html, contains('<p>你好</p>'));
      expect(html, contains('data-theme="light"'));
      // 正文必须包在与网页端相同的结构里，主题的 `.entry-content …` 才会命中。
      expect(html, contains('class="wrapper"'));
      expect(html, contains('class="entry-content"'));
      expect(html, contains('class="ybh-shell"'));
      // 图片自适应（外壳样式）。
      expect(html, contains('max-width: 100% !important'));
      // 代码块语言标签 + 复制按钮脚本。
      expect(html, contains('language-'));
      expect(html, contains('data-lang'));
      expect(html, contains('ybh-copy'));
      // ★ 必须恢复纵向滚动：站点 `inc/decorate.php` 会输出
      //   `html{overflow-y:hidden}`，而它靠主题的预载 JS 撤销 ——
      //   阅读器只内联 CSS 没有那份 JS，不显式恢复就会「整页纹丝不动」。
      expect(html, contains('overflow-y: auto'));
    });

    test('★ 正文与标题的字号刻度是显式写死的（不继承站点移动端的压缩）', () {
      // 实测（411×731 真机视口）：站点在移动端把 .entry-content 压到 16px，
      // 而 body 是 20px ⇒ 一屏里正文比别的都小。阅读器必须以正文为基准重建刻度。
      final html = ArticleWebView.buildHtml(content: '<p>x</p>', dark: false);
      expect(html, contains('.entry-content { font-size: 20px'));
      expect(html, contains('.entry-content h2 { font-size: 1.28em'));
      expect(html, contains('.entry-content h3 { font-size: 1.14em'));
      expect(html, contains('.entry-content h4 { font-size: 1.04em'));
      // 标题与元信息也跟着刻度走
      expect(html, contains('font-size: 1.5em'));
      expect(html, contains('font-size: .7em'));
    });

    test('深色模式走网页端机制（body.dark + data-theme）', () {
      final html = ArticleWebView.buildHtml(
        content: '',
        dark: true,
      );
      expect(html, contains('data-theme="dark"'));
      expect(html, contains('class="dark"'));
      // 深色底由外壳样式给出（与网页端 body.dark 同一套机制）。
      expect(html, contains('body.dark { background:'));
    });

    test('正文 HTML 原样注入', () {
      final html = ArticleWebView.buildHtml(
        content: '<ruby><bdo lang="ja">き</bdo><rt>ki</rt></ruby>',
        dark: false,
      );
      expect(html, contains('<ruby><bdo lang="ja">き</bdo><rt>ki</rt></ruby>'));
    });

    test('正文上方的头部 HTML 放在正文容器里（随正文滚走，不做固定条）', () {
      final html = ArticleWebView.buildHtml(
        content: '<p>正文</p>',
        dark: false,
        headerHtml: '<header class="ybh-article-head">T</header>',
      );
      final head = html.indexOf('<header class="ybh-article-head">');
      final body = html.indexOf('<p>正文</p>');
      expect(head, greaterThan(html.indexOf('class="entry-content"')));
      expect(head, lessThan(body), reason: '头部应在正文之前');
    });
  });

  group('阅读器的字体供给（端到端）', () {
    // 这条断言的价值：它同时覆盖「清单 → 资产在包里 → 生成 data: URI 规则」
    // 整条链。215161b 那次清单引用了没在 pubspec 声明的目录，`prepare()` 整体
    // 抛异常、字体全丢，而当时的测试一条都没红。
    setUpAll(() async {
      await EmbeddedFonts.instance.prepare();
    });

    test('打包字体确实被内联进阅读器文档', () {
      expect(EmbeddedFonts.instance.isReady, isTrue,
          reason: '字体未就绪：检查 assets/fonts/manifest.json 引用的资产是否都在 '
              'pubspec.yaml 的 assets: 下声明过');
      // 跳过数为 0 才是「每一个清单资产都真的进了包」。
      expect(EmbeddedFonts.instance.skippedCount, 0,
          reason: '有资产读不到 —— pubspec 漏声明目录，或清单里的文件不存在');
      expect(EmbeddedFonts.instance.ruleCount, greaterThan(10));

      final html = ArticleWebView.buildHtml(content: '<p>x</p>', dark: false);
      expect(html, contains('id="ybh-fonts"'));
      expect(html, contains('data:font/woff2;base64,'));
      // 描述符逐条来自站点 CSS，抽样核对两条有代表性的。
      expect(html, contains('"Klee One"'));
      expect(html, contains('"YBH Emoji"'));
    });

    test('站点分片前缀被保留（扩展汉字按需加载，不整包内联）', () {
      final keep = EmbeddedFonts.instance.keepPrefixes;
      expect(keep.any((k) => k.contains('/ybh-fonts/slices/')), isTrue);
      // 147 片扩展汉字面**不该**出现在内联清单里：内联会让每次导航多传 17.6 MB。
      // 规则数是最直接的判据（含分片时会从 26 跳到 173）。
      expect(EmbeddedFonts.instance.ruleCount, lessThan(40),
          reason: '内联规则数异常偏多 —— 检查 tool/font_manifest.py 的 LAZY_DIRS '
              '是否仍把 slices/ 排除在内联之外');
      expect(EmbeddedFonts.instance.css.length, lessThan(14 * 1024 * 1024));
    });
  });
}
