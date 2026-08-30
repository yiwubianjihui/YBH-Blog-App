import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';

/// 通知检查逻辑：新文章发布、我的投稿审核通过。
///
/// 同一份逻辑既在 App 前台调用，也由 WorkManager 在后台周期调用。
abstract final class NotificationChecker {
  static const Duration _timeout = Duration(seconds: 20);

  /// 存「上次看到的最新文章 id」。
  static const String _lastSeenKey = 'ybh_notify_last_seen_post_id';

  /// 存「处于待审核状态的我的文章 id 列表」。
  static const String _pendingKey = 'ybh_notify_pending_ids';

  /// 后台执行一次完整检查。
  static Future<void> runOnce() async {
    final prefs = await NotificationPrefs.load();
    if (!prefs.enabled || prefs.frequencyMinutes <= 0) return;
    if (prefs.newPostEnabled) await _checkNewPost();
    if (prefs.myPostEnabled) await _checkMyPosts();
  }

  /// 检查是否有新文章发布。
  static Future<void> _checkNewPost() async {
    try {
      final response = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts?per_page=1&_fields=id,title'))
          .timeout(_timeout);
      if (response.statusCode != 200) return;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List || decoded.isEmpty) return;
      final item = decoded.first as Map<String, dynamic>;
      final id = (item['id'] as num?)?.toInt() ?? 0;
      if (id == 0) return;

      final prefs = await SharedPreferences.getInstance();
      final lastSeen = prefs.getInt(_lastSeenKey) ?? 0;
      if (id > lastSeen && lastSeen > 0) {
        final title =
            ((item['title'] as Map?)?['rendered'] as String?)?.trim();
        await NotificationService.show(
          id: 1001,
          title: 'YBH 有新文章啦',
          body: title == null || title.isEmpty ? '快去看看吧' : title,
        );
      }
      // 无论是否通知都推进游标（id 增大说明有更新）。
      if (id > lastSeen) {
        await prefs.setInt(_lastSeenKey, id);
      }
    } catch (_) {
      // 网络异常静默。
    }
  }

  /// 检查「我的投稿」是否有审核通过的。
  static Future<void> _checkMyPosts() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('ybh_wp_token');
      if (token == null || token.isEmpty) return;
      final method = prefs.getString('ybh_wp_method') ?? 'basic';
      final auth = method == 'jwt' ? 'Bearer $token' : 'Basic $token';
      final headers = {'Authorization': auth};

      // 1) 拿我的用户 id。
      final meResp = await http
          .get(Uri.parse('${AppConfig.apiBase}/users/me'), headers: headers)
          .timeout(_timeout);
      if (meResp.statusCode != 200) return;
      final me = jsonDecode(utf8.decode(meResp.bodyBytes));
      final authorId = me is Map ? (me['id'] as num?)?.toInt() ?? 0 : 0;
      if (authorId == 0) return;

      // 2) 拉我名下所有文章的状态。
      final postsResp = await http
          .get(
            Uri.parse('${AppConfig.apiBase}/posts')
                .replace(queryParameters: {
              'author': '$authorId',
              'per_page': '100',
              '_fields': 'id,status',
            }),
            headers: headers,
          )
          .timeout(_timeout);
      if (postsResp.statusCode != 200) return;
      final posts = jsonDecode(utf8.decode(postsResp.bodyBytes));
      if (posts is! List) return;

      final published = <int>{};
      final stillPending = <int>[];
      for (final p in posts.whereType<Map<String, dynamic>>()) {
        final id = (p['id'] as num?)?.toInt() ?? 0;
        final status = p['status'] as String? ?? '';
        if (status == 'publish') published.add(id);
        if (status == 'pending') stillPending.add(id);
      }

      final storedPending = (prefs.getStringList(_pendingKey) ?? const [])
          .map(int.tryParse)
          .whereType<int>()
          .toSet();

      // 之前待审核、现在已发布 → 通知。
      final justApproved = storedPending.where(published.contains).toList();
      for (final id in justApproved) {
        await NotificationService.show(
          id: 2000 + id % 1000,
          title: '你的投稿通过了审核',
          body: '文章已经公开，快去看看吧',
        );
      }

      // 更新待审核集合（保留仍在等待的 + 新出现的待审核）。
      final nextPending = <int>{
        ...storedPending.where(stillPending.contains),
        ...stillPending,
      }.toList();
      await prefs.setStringList(_pendingKey, nextPending.map((e) => '$e').toList());
    } catch (_) {
      // 未登录或网络异常都静默。
    }
  }

  /// 登录成功后把当前待审核文章登记进 [pendingKey]，
  /// 这样之后通过审核时 App 才知道要提醒。
  static Future<void> seedPendingIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final token = prefs.getString('ybh_wp_token');
      if (token == null || token.isEmpty) return;
      final method = prefs.getString('ybh_wp_method') ?? 'basic';
      final auth = method == 'jwt' ? 'Bearer $token' : 'Basic $token';
      final headers = {'Authorization': auth};
      final meResp = await http
          .get(Uri.parse('${AppConfig.apiBase}/users/me'), headers: headers)
          .timeout(_timeout);
      if (meResp.statusCode != 200) return;
      final me = jsonDecode(utf8.decode(meResp.bodyBytes));
      final authorId = me is Map ? (me['id'] as num?)?.toInt() ?? 0 : 0;
      if (authorId == 0) return;
      final postsResp = await http
          .get(
            Uri.parse('${AppConfig.apiBase}/posts')
                .replace(queryParameters: {
              'author': '$authorId',
              'per_page': '100',
              '_fields': 'id,status',
            }),
            headers: headers,
          )
          .timeout(_timeout);
      if (postsResp.statusCode != 200) return;
      final posts = jsonDecode(utf8.decode(postsResp.bodyBytes));
      if (posts is! List) return;
      final pending = <int>[];
      for (final p in posts.whereType<Map<String, dynamic>>()) {
        if ((p['status'] as String?) == 'pending') {
          pending.add((p['id'] as num?)?.toInt() ?? 0);
        }
      }
      await prefs.setStringList(_pendingKey, pending.map((e) => '$e').toList());
    } catch (_) {
      // 静默。
    }
  }
}
