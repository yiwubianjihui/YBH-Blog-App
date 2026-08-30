import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../app_config.dart';

/// 展台的站点统计（内容数 / 总字数 / 建站天数）。
///
/// 这些数据由 App 直接算出来，与主站「展台」区块的口径一致：
/// 内容数 = 文章总数；总字数 = 全部文章去标签后的中文字符 + 字母数字；
/// 建站天数 = 今天 - 最早一篇发布的日期。
class SiteStats {
  const SiteStats({
    required this.postCount,
    required this.wordCount,
    required this.siteAgeDays,
  });

  final int postCount;
  final int wordCount;
  final int siteAgeDays;

  /// 依据总字数给出成就等级（对应主站展台的「笔耕不辍」徽章）。
  String get medalTitle {
    if (wordCount >= 200000) return '笔耕千钧';
    if (wordCount >= 100000) return '文思如泉';
    if (wordCount >= 50000) return '笔耕不辍';
    if (wordCount >= 20000) return '初露锋芒';
    return '破土萌芽';
  }

  /// 距下一等级还需多少字（简化阈值，纯展示用）。
  int get toNextLevel {
    if (wordCount < 20000) return 20000 - wordCount;
    if (wordCount < 50000) return 50000 - wordCount;
    if (wordCount < 100000) return 100000 - wordCount;
    if (wordCount < 200000) return 200000 - wordCount;
    return 0;
  }

  String get wordCountLabel {
    if (wordCount >= 10000) {
      return '${(wordCount / 10000).toStringAsFixed(1)} 万字';
    }
    return '$wordCount 字';
  }
}

/// 拉取展台统计；失败返回 null（首页用占位展示，不打断页面）。
abstract final class SiteStatsFetcher {
  static const Duration _timeout = Duration(seconds: 20);

  static Future<SiteStats?> fetch() async {
    try {
      // 1) 总数（从响应头取）。
      final countResp = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts?per_page=1'))
          .timeout(_timeout);
      final postCount =
          int.tryParse(countResp.headers['x-wp-total'] ?? '') ?? 0;
      if (postCount == 0) return null;

      // 2) 拉全部文章算字数与最早日期（per_page=100 一次拿完）。
      final allResp = await http
          .get(Uri.parse('${AppConfig.apiBase}/posts'
              '?per_page=100&_fields=id,date,content'))
          .timeout(_timeout);
      if (allResp.statusCode != 200) return null;
      final decoded = jsonDecode(utf8.decode(allResp.bodyBytes));
      if (decoded is! List) return null;

      var words = 0;
      DateTime? earliest;
      for (final item in decoded.whereType<Map<String, dynamic>>()) {
        final content = (item['content'] as Map?)?['rendered'] as String? ?? '';
        words += _countWords(content);
        final date = DateTime.tryParse((item['date'] as String?) ?? '');
        if (date != null && (earliest == null || date.isBefore(earliest))) {
          earliest = date;
        }
      }

      final ageDays = earliest == null
          ? 0
          : max(0, DateTime.now().difference(earliest).inDays);
      return SiteStats(
        postCount: postCount,
        wordCount: words,
        siteAgeDays: ageDays,
      );
    } catch (_) {
      return null;
    }
  }

  /// 去掉 HTML 标签后，统计「中文字符 + 字母数字」的个数（与站点口径接近）。
  static int _countWords(String html) {
    var text = html
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll(RegExp(r'&[a-zA-Z#0-9]+;'), ' ');
    final cjk = RegExp(r'[\u4e00-\u9fff]').allMatches(text).length;
    final alnum = RegExp(r'[A-Za-z0-9]').allMatches(text).length;
    return cjk + alnum;
  }
}
