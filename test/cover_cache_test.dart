import 'package:flutter_test/flutter_test.dart';
import 'package:yibianhui_blog/src/app_config.dart';
import 'package:yibianhui_blog/src/data/blog_api.dart';

PostSummary _post(int id) => PostSummary(
      id: id,
      date: DateTime(2026, 9, 22),
      title: '文章 $id',
      excerpt: '',
      content: '',
      link: 'https://www.yibianhui.cn/?p=$id',
      terms: const [],
    );

void main() {
  setUp(CoverCache.clear);
  tearDown(CoverCache.clear);

  group('封面端点地址', () {
    test('单张封面默认请求卡片小图变体', () {
      final url = AppConfig.coverUrl(42);
      expect(url, contains('rand-cover.php'));
      expect(url, contains('img=w'));
      // ★ 站点为每张图备了 -card 小图；卡片只有 112×112，取大图纯属浪费。
      expect(url, contains('size=card'));
      // seed 仍要保留：它给 CachedNetworkImage 当缓存键。
      expect(url, contains('&42'));
    });

    test('可以显式关掉小图变体（首屏大图场景）', () {
      expect(AppConfig.coverUrl(7, card: false), isNot(contains('size=card')));
    });

    test('批量地址带 n 与 size', () {
      final url = AppConfig.batchCoverUrl(20);
      expect(url, contains('n=20'));
      expect(url, contains('size=card'));
      expect(url, contains('img=w'));
    });
  });

  group('CoverCache', () {
    test('一页 20 篇只发一次批量请求，并按序绑定', () async {
      CoverCache.clear();
      var calls = 0;
      final asked = <int>[];
      Future<List<String>?> fake(int n, {bool card = true}) async {
        calls++;
        asked.add(n);
        return List.generate(n, (i) => 'https://img.example/$i.webp');
      }

      final posts = [for (var i = 1; i <= 20; i++) _post(i)];
      await CoverCache.bind(posts, fetch: fake);

      expect(calls, 1, reason: '20 张封面应当合并成 1 次批量请求');
      expect(asked, [20]);
      expect(CoverCache.lookup(1), 'https://img.example/0.webp');
      expect(posts.first.coverUrl, 'https://img.example/0.webp');
      expect(posts.last.coverUrl, 'https://img.example/19.webp');
      expect(CoverCache.batchRequests, 1);
      expect(CoverCache.boundPosts, 20);
    });

    test('再次遇到同一批文章不再发请求，且封面地址不变（滚动来回不跳图）', () async {
      CoverCache.clear();
      var calls = 0;
      Future<List<String>?> fake(int n, {bool card = true}) async {
        calls++;
        return List.generate(n, (i) => 'https://img.example/r$calls-$i.webp');
      }

      final first = [for (var i = 1; i <= 5; i++) _post(i)];
      await CoverCache.bind(first, fetch: fake);
      final bound = [for (final p in first) p.coverUrl];

      // 模拟列表重建：同一批 id 重新构造的 PostSummary（绑定表按 id 命中）。
      final again = [for (var i = 1; i <= 5; i++) _post(i)];
      await CoverCache.bind(again, fetch: fake);

      expect(calls, 1, reason: '已绑定的文章不该重复请求');
      expect([for (final p in again) p.coverUrl], bound);
    });

    test('只有没见过的文章才计入缺口数', () async {
      CoverCache.clear();
      final asked = <int>[];
      Future<List<String>?> fake(int n, {bool card = true}) async {
        asked.add(n);
        return List.generate(n, (i) => 'https://img.example/b$i.webp');
      }

      await CoverCache.bind([for (var i = 1; i <= 20; i++) _post(i)], fetch: fake);
      // 第二页：后 10 篇是老朋友，新增 10 篇。
      final page2 = [
        for (var i = 11; i <= 20; i++) _post(i),
        for (var i = 21; i <= 30; i++) _post(i),
      ];
      await CoverCache.bind(page2, fetch: fake);

      expect(asked, [20, 10], reason: '老文章应当命中缓存，只为新文章发请求');
    });

    test('批量失败时保持未绑定 —— 回退到单张地址，而不是没图', () async {
      CoverCache.clear();
      final posts = [_post(1), _post(2)];
      await CoverCache.bind(posts, fetch: (n, {bool card = true}) async => null);

      expect(CoverCache.lookup(1), isNull);
      // 未绑定时仍给出可用的单张地址（含卡片小图参数）。
      expect(posts.first.coverUrl, contains('rand-cover.php'));
      expect(posts.first.coverUrl, contains('size=card'));
      expect(posts.first.coverUrl, contains('&1'));
      expect(CoverCache.boundPosts, 0);
    });

    test('空列表不发请求', () async {
      CoverCache.clear();
      var calls = 0;
      await CoverCache.bind(const <PostSummary>[],
          fetch: (n, {bool card = true}) async {
        calls++;
        return const <String>[];
      });
      expect(calls, 0);
    });
  });
}
