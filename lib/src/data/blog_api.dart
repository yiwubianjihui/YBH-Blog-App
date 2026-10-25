import 'dart:convert';

import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../app_config.dart';

/// 博客分类。
class BlogCategory {
  const BlogCategory({required this.id, required this.name, required this.count});

  final int id;
  final String name;
  final int count;

  factory BlogCategory.fromJson(Map<String, dynamic> json) {
    return BlogCategory(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: _decodeHtml((json['name'] as String?) ?? ''),
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 文章摘要（列表用）。
class PostSummary {
  const PostSummary({
    required this.id,
    required this.date,
    required this.title,
    required this.excerpt,
    required this.content,
    required this.link,
    required this.terms,
    this.status = 'publish',
    this.rawContent,
    this.authorId,
  });

  final int id;
  final DateTime? date;
  final String title;
  final String excerpt;
  final String content;
  final String link;
  final List<String> terms;

  /// 文章状态：publish / draft / pending / future / private。
  final String status;

  /// 未过滤的正文原文（`content.raw`，仅带认证的 `context=edit` 请求才有）。
  /// 编辑器用它回填 —— `content.rendered` 是服务端渲染后的成品，
  /// 再编辑会把渲染痕迹（脚注展开、短代码替换等）固化进正文。
  final String? rawContent;

  /// 作者 ID（`context=edit` 或标准响应里都有；「我的文章」里用于判断归属）。
  final int? authorId;

  /// 编辑回填用的正文：优先 raw，退回 rendered。
  String get editableContent => (rawContent != null && rawContent!.isNotEmpty)
      ? rawContent!
      : content;

  /// 这条摘要**是否带着正文**。
  ///
  /// 列表请求默认把 `content.rendered` 一起带回来（详情页直接复用，省一次往返），
  /// 所以从「文章」Tab 进来的文章 `hasBody == true`，不需要补拉。
  ///
  /// 但**日历视图刻意不带正文**（见 [BlogApi.fieldsForCalendar]）：100 篇全文实测
  /// 984 KB / 12.3 秒，会把 25 秒超时踩穿。这类文章 `hasBody == false`，
  /// 由详情页按 id 补拉正文 —— 见 [BlogApi.fetchPost]。
  bool get hasBody => content.trim().isNotEmpty;

  /// 非已发布状态的中文标签（用于在列表中提示投稿进度）。
  String? get statusLabel => switch (status) {
        'draft' => '草稿',
        'pending' => '待审核',
        'future' => '待发布',
        'private' => '私密',
        _ => null,
      };

  /// 随机封面图（主题图库端点 `rand-cover.php`，302 跳转到真实图片，不加载 WordPress）。
  ///
  /// 若 [CoverCache] 为这篇文章批量取过地址就优先用它 —— 批量绑定既省请求，
  /// 又保证同一篇在滚动来回时**封面不跳**。
  ///
  /// ⚠️ 封面绑定**不存在这个对象里**：`PostSummary` 是 `const` 可构造的不可变值，
  /// 加可变字段会让所有 `const PostSummary(...)` 失效。绑定表统一放在 [CoverCache]，
  /// 这里只做一次查表。
  String get coverUrl => CoverCache.lookup(id) ?? AppConfig.coverUrl(id);

  /// 封面的兜底地址：万一 `rand-cover.php` 不可用就退到主题内建 REST。
  String get coverUrlFallback => AppConfig.coverUrlFallback(id);

  factory PostSummary.fromJson(Map<String, dynamic> json) {
    final terms = <String>[];
    final embedded = json['_embedded'];
    if (embedded is Map<String, dynamic>) {
      final wpTerm = embedded['wp:term'];
      if (wpTerm is List) {
        for (final group in wpTerm) {
          if (group is List) {
            for (final term in group) {
              if (term is Map<String, dynamic>) {
                final name = _decodeHtml((term['name'] as String?) ?? '');
                if (name.isNotEmpty && !terms.contains(name)) terms.add(name);
              }
            }
          }
        }
      }
    }
    return PostSummary(
      id: (json['id'] as num?)?.toInt() ?? 0,
      date: DateTime.tryParse((json['date'] as String?) ?? ''),
      title: _decodeHtml((json['title'] as Map?)?['rendered'] as String? ?? ''),
      excerpt: _stripHtml((json['excerpt'] as Map?)?['rendered'] as String? ?? ''),
      content: (json['content'] as Map?)?['rendered'] as String? ?? '',
      rawContent: (json['content'] as Map?)?['raw'] as String?,
      link: (json['link'] as String?) ?? AppConfig.blogUrl,
      terms: terms,
      status: (json['status'] as String?) ?? 'publish',
      authorId: (json['author'] as num?)?.toInt(),
    );
  }
}

/// 文章列表的一页结果。
class PostsPage {
  const PostsPage({
    required this.posts,
    required this.total,
    required this.totalPages,
  });

  final List<PostSummary> posts;
  final int total;
  final int totalPages;

  bool get hasMore => posts.length < total;
}

/// WordPress REST 数据访问层。
abstract final class BlogApi {
  static const Duration _timeout = Duration(seconds: 25);

  /// 拉取文章列表。
  ///
  /// [categoryId] 为 null 时拉取全部；[search] 非空时按关键词搜索
  /// （匹配标题与正文）；[page] 从 1 开始。
  ///
  /// [after] / [before] 是 WordPress 的**日期区间**过滤（ISO8601，站内时间），
  /// 「全部文章」的日历视图用它一次取回一整个月的文章，再按天归档
  /// —— 比逐天请求少 30 倍的往返。
  ///
  /// [fields] 对应 REST 的 `_fields`（逗号分隔的白名单）。**默认 null = 返回全字段**，
  /// 也就是每篇都带着完整 `content.rendered`。这正是历史行为：列表把正文顺带带回来，
  /// 详情页直接复用，省掉一次往返。
  ///
  /// ⚠️ 但「一次很多篇」的调用必须显式裁剪，否则响应会大到把超时踩穿 ——
  /// 日历视图 100 篇全字段实测 **984 KB / 12.3 秒**（偶发 19.8 秒），
  /// 而裁到 `id,date,title,link` 只要 **15 KB / 2.1 秒**。见 [fieldsForCalendar]。
  ///
  /// `_fields` 不会影响 `X-WP-Total` 响应头（已实测），所以分页逻辑不受影响。
  static Future<PostsPage> fetchPosts({
    int? categoryId,
    int? tagId,
    String? search,
    int page = 1,
    int perPage = 20,
    String? after,
    String? before,
    String? fields,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBase}/posts').replace(
      queryParameters: {
        'per_page': '$perPage',
        'page': '$page',
        '_embed': '1',
        'orderby': 'date',
        'order': 'desc',
        if (categoryId != null) 'categories': '$categoryId',
        if (tagId != null) 'tags': '$tagId',
        if (search != null && search.isNotEmpty) 'search': search,
        if (after != null && after.isNotEmpty) 'after': after,
        if (before != null && before.isNotEmpty) 'before': before,
        if (fields != null && fields.isNotEmpty) '_fields': fields,
      },
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) return const PostsPage(posts: [], total: 0, totalPages: 0);
    final posts = decoded
        .whereType<Map<String, dynamic>>()
        .map(PostSummary.fromJson)
        .toList();
    final total = int.tryParse(response.headers['x-wp-total'] ?? '') ?? posts.length;
    final totalPages =
        int.tryParse(response.headers['x-wp-totalpages'] ?? '') ?? 1;
    // 顺手把这一页的封面绑定好（一次批量请求，约几毫秒，不加载 WordPress）。
    // 放在这里而不是每个调用方：全 App 的文章列表只有这一条数据入口。
    await CoverCache.bind(posts);
    return PostsPage(posts: posts, total: total, totalPages: totalPages);
  }

  /// 列表卡片要用的字段白名单。
  ///
  /// **保留 `content`** —— 详情页正文直接复用列表带回来的这份（[PostDetailPage]
  /// 不会自己再请求一遍）。去掉的是 `guid` / `slug` / `modified*` / `meta` /
  /// `class_list` / `template` / `comment_status` 等本 App 从不读的字段。
  ///
  /// 实测（20 篇）：184 KB → 171 KB。省得不多是因为正文本身占了大头，
  /// 但删掉的全是无用负载，没有理由继续传。
  static const String fieldsForList =
      'id,date,title,excerpt,content,link,_embedded,_links';

  /// 日历视图要用的字段白名单 —— **刻意不含 `content`**。
  ///
  /// 日历一格只画「几号、几篇、标题」，正文一格都用不上：
  /// * 全字段 100 篇：**1,007,785 B / 12.3–19.8 秒**（踩穿 25 秒超时的直接原因）
  /// * 本白名单（通常 50 篇上下）：**15,376 B / 2.1 秒**
  ///
  /// 代价：`terms` 为空（术语来自 `_embedded`），所以日历的当天列表不显示分类，
  /// 改成显示日期；正文在点开某篇时按 id 补拉（[fetchPost]）。
  /// 也**不要**在这里加 `_links` 想拿分类 —— 它只会把术语的 href 给你，
  /// 拿不到名字，体积却从 15 KB 涨到 71 KB。
  static const String fieldsForCalendar = 'id,date,title,link';

  /// 按 id 拉**单篇**。日历视图的文章没有正文（见 [fieldsForCalendar]），
  /// 详情页打开时用它补齐。
  ///
  /// 实测单篇约 **17 KB / 2.5 秒**，且只在该篇被打开时发生一次；
  /// 相比「进页面先花 12 秒拉 1 MB」，这是数量级的改善。
  ///
  /// 失败一律返回 null —— 调用方显示「正文没能载入 + 重试」，不抛异常打断阅读。
  static Future<PostSummary?> fetchPost(int id, {String? fields}) async {
    if (id <= 0) return null;
    try {
      final uri = Uri.parse('${AppConfig.apiBase}/posts/$id').replace(
        queryParameters: {
          if (fields != null && fields.isNotEmpty) '_fields': fields,
        },
      );
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      return PostSummary.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  /// 一次取 N 张**互不重复**的封面（`rand-cover.php?n=N`，返回 `{"urls":[...]}`）。
  ///
  /// 失败一律返回 null：调用方退回「按文章 id 现算单张地址」的老路，
  /// 不该因为省请求的优化而让列表没图。
  ///
  /// 服务器约束（对齐 `rand-cover.php` 源码）：`n<=1` 会退化成 302 单张模式、
  /// **不是 JSON**；`n` 上限 60；响应头是 `Cache-Control: no-store`。
  static Future<List<String>?> fetchCoverBatch(int n, {bool card = true}) async {
    if (n <= 1) return null;                 // n<=1 走 302，不是 JSON
    final count = n > 60 ? 60 : n;           // 服务器上限 60
    try {
      final uri = Uri.parse(AppConfig.batchCoverUrl(count, card: card));
      final response = await http.get(uri).timeout(_coverBatchTimeout);
      if (response.statusCode != 200) return null;
      if (!(response.headers['content-type'] ?? '').contains('json')) return null;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map || decoded['urls'] is! List) return null;
      final urls = (decoded['urls'] as List)
          .whereType<String>()
          .where((u) => u.startsWith('http'))
          .toList();
      return urls.isEmpty ? null : urls;
    } catch (_) {
      return null;
    }
  }

  /// 封面批量请求的超时。比列表本身短得多：它只是省请求的优化，
  /// 不该把首屏拖慢；超时就退回单张地址。
  static const Duration _coverBatchTimeout = Duration(seconds: 6);

  /// 按 slug 拉取指定文章（用于首页展台精选）。
  ///
  /// WordPress REST 一次只接受一个 slug，这里逐个请求；找不到的静默跳过。
  static Future<List<PostSummary>> fetchPostsBySlugs(List<String> slugs) async {
    final posts = <PostSummary>[];
    for (final slug in slugs) {
      if (slug.trim().isEmpty) continue;
      try {
        final uri = Uri.parse('${AppConfig.apiBase}/posts').replace(
          queryParameters: {
            'slug': slug.trim(),
            'per_page': '1',
            '_embed': '1',
          },
        );
        final response = await http.get(uri).timeout(_timeout);
        if (response.statusCode != 200) continue;
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! List || decoded.isEmpty) continue;
        posts.add(PostSummary.fromJson(decoded.first as Map<String, dynamic>));
      } catch (_) {
        // 单个失败不影响其他。
      }
    }
    return posts;
  }

  /// 拉取分类列表（按文章数降序）。
  static Future<List<BlogCategory>> fetchCategories({int perPage = 50}) async {
    final uri = Uri.parse('${AppConfig.apiBase}/categories').replace(
      queryParameters: {
        'per_page': '$perPage',
        'orderby': 'count',
        'order': 'desc',
        'hide_empty': '1',
      },
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(BlogCategory.fromJson)
        .where((c) => c.count > 0 && c.name.isNotEmpty)
        .toList();
  }

  /// 拉取标签列表（按文章数降序）。
  ///
  /// 复用 [BlogCategory] 的形状：标签与分类在 WP REST 里字段完全一致
  /// （`id` / `name` / `count`），没必要再定义一遍同构的类。
  static Future<List<BlogCategory>> fetchTags({int perPage = 100}) async {
    final uri = Uri.parse('${AppConfig.apiBase}/tags').replace(
      queryParameters: {
        'per_page': '$perPage',
        'orderby': 'count',
        'order': 'desc',
        'hide_empty': '1',
      },
    );
    final response = await http.get(uri).timeout(_timeout);
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}');
    }
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(BlogCategory.fromJson)
        .where((t) => t.count > 0 && t.name.isNotEmpty)
        .toList();
  }
}

/// 批量封面取回的签名（可注入，便于单测）。
typedef CoverBatchFetcher = Future<List<String>?> Function(int n, {bool card});

/// 封面地址的**进程级绑定表**。
///
/// ## 为什么需要它
///
/// 封面端点每次调用都随机返回一张图（`img` 的取值只决定横/竖，`seed` 参数
/// 服务端**根本不读**）。App 靠「把 seed 写进 URL」来给 `CachedNetworkImage`
/// 当缓存键，让同一篇文章的封面在 App 内保持一致。
///
/// 批量端点（`?n=20`）一次取回 20 张地址，省掉 19 次往返 —— 但它是
/// `Cache-Control: no-store`，**每次调用都是新的一批**。所以绝不能每次
/// build 都去批量取：那样滚动来回时封面会不停跳，还会重复下载。
/// 对策就是把「文章 id → 封面地址」记下来，本进程内只绑一次。
///
/// 绑定失败（端点不可用、返回不是 JSON）时**什么都不做**：卡片会退回
/// [AppConfig.coverUrl] 的单张地址，功能不受影响，只是多几次往返。
abstract final class CoverCache {
  static final Map<int, String> _byPost = <int, String>{};

  /// 实际发出过的批量请求次数（诊断 / 单测断言用）。
  static int batchRequests = 0;

  /// 已绑定成功的文章数（诊断用）。
  static int boundPosts = 0;

  /// 绑定表的容量上限：超过就整体清空重建，避免长时间浏览后无限增长。
  static const int _capacity = 2000;

  static int get size => _byPost.length;

  /// 查一篇已绑定的封面地址（未绑定返回 null）。
  static String? lookup(int postId) => _byPost[postId];

  /// 把 [posts] 里还没有封面的那些**一次批量取回**并记入绑定表。
  ///
  /// 已经在表里的直接命中（不发请求）；表里没有的合并成一次 `?n=<缺口数>` 请求。
  /// 只读 `post.id`，不修改任何 `PostSummary`（它是不可变值）。
  /// [fetch] 仅供测试注入，默认走 [BlogApi.fetchCoverBatch]。
  static Future<void> bind(
    List<PostSummary> posts, {
    bool card = true,
    CoverBatchFetcher? fetch,
  }) async {
    if (posts.isEmpty) return;
    if (_byPost.length > _capacity) _byPost.clear();

    final missing = <PostSummary>[];
    for (final p in posts) {
      if (!_byPost.containsKey(p.id)) missing.add(p);
    }
    if (missing.isEmpty) return;

    batchRequests++;
    final urls = await (fetch ?? BlogApi.fetchCoverBatch)(missing.length, card: card);
    if (urls == null || urls.isEmpty) return;
    final n = missing.length < urls.length ? missing.length : urls.length;
    for (var i = 0; i < n; i++) {
      _byPost[missing[i].id] = urls[i];
    }
    boundPosts += n;
  }

  /// 清空绑定表（测试 / 需要强制换一批封面时用）。
  static void clear() {
    _byPost.clear();
    batchRequests = 0;
    boundPosts = 0;
  }
}

/// 去掉 HTML 标签并解码实体（&hellip; 等）。
String _stripHtml(String html) {
  if (html.isEmpty) return '';
  final fragment = html_parser.parseFragment(html);
  final text = fragment.text ?? '';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// 仅解码 HTML 实体（标题里可能出现 &quot; 等）。
String _decodeHtml(String html) {
  if (html.isEmpty) return '';
  final fragment = html_parser.parseFragment(html);
  return (fragment.text ?? '').trim();
}
