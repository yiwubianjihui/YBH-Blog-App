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

  /// 非已发布状态的中文标签（用于在列表中提示投稿进度）。
  String? get statusLabel => switch (status) {
        'draft' => '草稿',
        'pending' => '待审核',
        'future' => '待发布',
        'private' => '私密',
        _ => null,
      };

  /// 随机封面图（Sakurairo 图库，302 跳转到真实图片）。
  String get coverUrl => AppConfig.coverUrl(id);

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
      link: (json['link'] as String?) ?? AppConfig.blogUrl,
      terms: terms,
      status: (json['status'] as String?) ?? 'publish',
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
  static Future<PostsPage> fetchPosts({
    int? categoryId,
    String? search,
    int page = 1,
    int perPage = 20,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBase}/posts').replace(
      queryParameters: {
        'per_page': '$perPage',
        'page': '$page',
        '_embed': '1',
        'orderby': 'date',
        'order': 'desc',
        if (categoryId != null) 'categories': '$categoryId',
        if (search != null && search.isNotEmpty) 'search': search,
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
    return PostsPage(posts: posts, total: total, totalPages: totalPages);
  }

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
