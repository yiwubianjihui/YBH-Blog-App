import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import 'blog_api.dart';

/// 一条「消息」（T30 · 应用内通知中心）。
class NoticeItem {
  const NoticeItem({
    required this.id,
    required this.title,
    required this.kind,
    this.date,
    this.link,
    this.summary,
    this.unread = false,
  });

  /// 文章 id（同一篇文章在不同来源下 id 相同，用于去重）。
  final int id;

  final String title;

  /// `new` 新文章 / `approved` 我的投稿已发布 / `pending` 我的投稿待审核。
  final String kind;

  final DateTime? date;
  final String? link;
  final String? summary;
  final bool unread;

  NoticeItem copyWith({bool? unread}) => NoticeItem(
        id: id,
        title: title,
        kind: kind,
        date: date,
        link: link,
        summary: summary,
        unread: unread ?? this.unread,
      );
}

/// 消息中心的数据来源（全部走站点 REST，不引入新的后端）。
///
/// 复用通知检查器已有的「上次看到的最新文章 id」游标
/// （`ybh_notify_last_seen_post_id`）来判断哪些是**未读** ——
/// 这样系统通知与 App 内的未读状态天然一致，不会出现「推了通知但列表没红点」。
abstract final class NotificationFeed {
  static const Duration _timeout = Duration(seconds: 20);

  /// 与 NotificationChecker 共用的游标键。
  static const String lastSeenKey = 'ybh_notify_last_seen_post_id';

  static Future<int> lastSeenId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(lastSeenKey) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// 把游标推进到最新（进入消息中心即视为已读）。
  static Future<void> markAllSeen(int newestId) async {
    if (newestId <= 0) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final cur = prefs.getInt(lastSeenKey) ?? 0;
      if (newestId > cur) await prefs.setInt(lastSeenKey, newestId);
    } catch (_) {
      // 静默。
    }
  }

  /// 拉取消息列表：站点最新文章 + （已登录时）我的投稿状态。
  static Future<List<NoticeItem>> load({int perPage = 20}) async {
    final seen = await lastSeenId();
    final items = <NoticeItem>[];

    // ---- 1) 站点最新文章（公开接口，未登录也能看）----
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts').replace(queryParameters: {
            'per_page': '$perPage',
            '_fields': 'id,date,link,title,excerpt',
          }))
          .timeout(_timeout);
      if (resp.statusCode == 200) {
        final list = jsonDecode(utf8.decode(resp.bodyBytes));
        if (list is List) {
          for (final raw in list.whereType<Map<String, dynamic>>()) {
            final id = (raw['id'] as num?)?.toInt() ?? 0;
            if (id == 0) continue;
            items.add(NoticeItem(
              id: id,
              title: _text(raw['title']) ?? '（无标题）',
              kind: 'new',
              date: DateTime.tryParse(raw['date'] as String? ?? ''),
              link: raw['link'] as String?,
              summary: _stripTags(_text(raw['excerpt']) ?? ''),
              unread: seen > 0 && id > seen,
            ));
          }
        }
      }
    } catch (_) {
      // 网络异常：返回已取到的部分（可能为空）。
    }

    // ---- 2) 我的投稿（需要登录）----
    final mine = await _loadMine();
    items.addAll(mine);

    // 按时间倒序；没有时间的排最后。
    items.sort((a, b) {
      final da = a.date, db = b.date;
      if (da == null && db == null) return b.id.compareTo(a.id);
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return items;
  }

  static Future<List<NoticeItem>> _loadMine() async {
    final out = <NoticeItem>[];
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('ybh_wp_token');
      if (token == null || token.isEmpty) return out;
      final method = prefs.getString('ybh_wp_method') ?? 'basic';
      final headers = {
        'Authorization': method == 'jwt' ? 'Bearer $token' : 'Basic $token',
      };

      final meResp = await http
          .get(Uri.parse('${AppConfig.apiBase}/users/me'), headers: headers)
          .timeout(_timeout);
      if (meResp.statusCode != 200) return out;
      final me = jsonDecode(utf8.decode(meResp.bodyBytes));
      final authorId = me is Map ? (me['id'] as num?)?.toInt() ?? 0 : 0;
      if (authorId == 0) return out;

      final resp = await http
          .get(
            Uri.parse('${AppConfig.apiBase}/posts').replace(queryParameters: {
              'author': '$authorId',
              'per_page': '30',
              'status': 'publish,pending,draft',
              '_fields': 'id,date,link,title,status',
            }),
            headers: headers,
          )
          .timeout(_timeout);
      if (resp.statusCode != 200) return out;
      final list = jsonDecode(utf8.decode(resp.bodyBytes));
      if (list is! List) return out;
      for (final raw in list.whereType<Map<String, dynamic>>()) {
        final id = (raw['id'] as num?)?.toInt() ?? 0;
        if (id == 0) continue;
        final status = raw['status'] as String? ?? '';
        // 只关心「待审核」和「已发布」；草稿不进消息列表。
        final String? kind = switch (status) {
          'pending' => 'pending',
          'publish' => 'approved',
          _ => null,
        };
        if (kind == null) continue;
        out.add(NoticeItem(
          id: id,
          title: _text(raw['title']) ?? '（无标题）',
          kind: kind,
          date: DateTime.tryParse(raw['date'] as String? ?? ''),
          link: raw['link'] as String?,
        ));
      }
    } catch (_) {
      // 未登录或网络异常：静默。
    }
    return out;
  }

  /// 未读数（用于 AppBar 红点）。失败时返回 0，不打扰用户。
  static Future<int> unreadCount() async {
    final seen = await lastSeenId();
    if (seen <= 0) return 0;
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts').replace(queryParameters: {
            'per_page': '20',
            '_fields': 'id',
          }))
          .timeout(_timeout);
      if (resp.statusCode != 200) return 0;
      final list = jsonDecode(utf8.decode(resp.bodyBytes));
      if (list is! List) return 0;
      var n = 0;
      for (final raw in list.whereType<Map<String, dynamic>>()) {
        final id = (raw['id'] as num?)?.toInt() ?? 0;
        if (id > seen) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// 按 id 取单篇（含正文），用于从消息中心直接进原生阅读页。
  ///
  /// 列表接口刻意**不**返回 `content`（20 篇正文会让首屏变慢），
  /// 只有用户真的点开某一篇时才拉一次。
  static Future<PostSummary?> loadSummary(int id) async {
    if (id <= 0) return null;
    try {
      final resp = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts/$id').replace(queryParameters: {
            '_fields': 'id,date,link,title,excerpt,content,status',
          }))
          .timeout(_timeout);
      if (resp.statusCode != 200) return null;
      final raw = jsonDecode(utf8.decode(resp.bodyBytes));
      if (raw is! Map<String, dynamic>) return null;
      return PostSummary.fromJson(raw);
    } catch (_) {
      return null;
    }
  }

  static String? _text(dynamic field) {
    if (field is Map && field['rendered'] is String) {
      return (field['rendered'] as String).trim();
    }
    return null;
  }

  /// 摘要里可能带 HTML（WordPress 的 excerpt 自带 <p>），列表里只显示纯文本。
  static String _stripTags(String html) {
    var s = html.replaceAll(RegExp(r'<[^>]*>'), ' ');
    s = s
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&hellip;', '…')
        .replaceAll('&#8230;', '…')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#8217;', "'");
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
