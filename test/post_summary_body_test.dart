import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/data/blog_api.dart';

/// 「全部文章」页打不开的根因回归测试（2026-10-25）。
///
/// 事故链路：日历视图一次拉 100 篇 × **全字段**（每篇自带 `content.rendered`
/// 全文 + `_embed`），实测 52 篇就 **1,007,785 B / 12.3 秒（偶发 19.8 秒）**，
/// 而 [BlogApi] 的超时是 25 秒 —— 移动网络下必然踩穿，页面卡在加载态。
///
/// 修复靠两条约束，这个文件把它们钉住：
/// 1. 日历请求必须用 [BlogApi.fieldsForCalendar]，**不含** `content` / `_embedded`；
/// 2. 列表请求必须用 [BlogApi.fieldsForList]，**保留** `content`
///    （详情页正文直接复用列表带回来的这份，见 [PostDetailPage]）。
///
/// 只要有人往 `fieldsForCalendar` 里加回 `content`，这里就会红。
void main() {
  group('PostSummary.hasBody', () {
    test('列表响应（带 content）→ hasBody 为 true，字段正常解析', () {
      final p = PostSummary.fromJson(<String, dynamic>{
        'id': 1,
        'date': '2026-10-25T10:00:00',
        'title': <String, dynamic>{'rendered': '标题'},
        'excerpt': <String, dynamic>{'rendered': '<p>摘要</p>'},
        'content': <String, dynamic>{'rendered': '<p>正文</p>'},
        'link': 'https://www.yibianhui.cn/?p=1',
      });
      expect(p.hasBody, isTrue);
      expect(p.title, '标题');
      expect(p.id, 1);
      expect(p.date, isNotNull);
    });

    test('日历响应（只有 id/date/title/link）→ hasBody 为 false，且解析不抛异常', () {
      final p = PostSummary.fromJson(<String, dynamic>{
        'id': 2,
        'date': '2026-10-25T10:00:00',
        'title': <String, dynamic>{'rendered': '日历里的标题'},
        'link': 'https://www.yibianhui.cn/?p=2',
      });
      expect(p.hasBody, isFalse);
      expect(p.title, '日历里的标题');
      expect(p.terms, isEmpty);
      expect(p.excerpt, isEmpty);
      expect(p.content, isEmpty);
      // 日历按 date 归档，日期必须能解析出来 —— 解析失败会让整篇从格子里消失。
      expect(p.date?.day, 25);
    });

    test('正文只有空白也算没有正文（否则会拿空白去建 WebView）', () {
      final p = PostSummary.fromJson(<String, dynamic>{
        'id': 3,
        'title': <String, dynamic>{'rendered': 'x'},
        'content': <String, dynamic>{'rendered': '  \n\t '},
        'link': 'https://www.yibianhui.cn/?p=3',
      });
      expect(p.hasBody, isFalse);
    });
  });

  group('REST 字段白名单', () {
    test('日历白名单必须裁掉正文与 _embedded（这就是 984 KB 的来源）', () {
      const f = BlogApi.fieldsForCalendar;
      expect(f.contains('content'), isFalse, reason: '日历带正文会让响应回到 1 MB');
      expect(f.contains('_embedded'), isFalse, reason: '_embedded 是 56 KB 的术语/作者开销');
      expect(f.contains('date'), isTrue, reason: '日历按 date 归档');
      expect(f.contains('title'), isTrue, reason: '格子里要显示标题');
      expect(f.contains('id'), isTrue, reason: '补正文要用 id');
    });

    test('列表白名单必须保留正文与 _embedded（详情页复用 + 分类名来自 _embedded）', () {
      const f = BlogApi.fieldsForList;
      expect(f.contains('content'), isTrue, reason: '详情页不再自己请求正文');
      expect(f.contains('_embedded'), isTrue, reason: '卡片的分类名来自 wp:term');
      expect(f.contains('excerpt'), isTrue, reason: '卡片显示摘要');
    });
  });
}
