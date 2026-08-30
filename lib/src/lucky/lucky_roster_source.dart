import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lucky_models.dart';

// 名单的远程来源。
//
// 真实名单**不进版本库**（公开仓库会泄露学生姓名），改为托管在下载站的
// `lucky/roster.json`。更新这个文件后，App 里点「从服务器获取」就能同步。
// 注意：类名不要与 lucky_models.dart 里的 [LuckyRosterSource] 枚举重名。
abstract final class LuckyRosterFetcher {
  static const Duration _timeout = Duration(seconds: 20);

  /// 从服务器下载名单。
  ///
  /// 支持两种格式：
  ///  1. `{"classes": {...}, "students": [...]}` —— 直接就是名单；
  ///  2. `{"rosterUrl": "..."}` 或纯文本 URL —— 再去该地址取名单。
  ///
  /// 返回 null 表示取不到（未部署 / 网络异常）。
  static Future<LuckyRoster?> fetch(String url) async {
    try {
      final response =
          await http.get(Uri.parse(url)).timeout(_timeout);
      if (response.statusCode != 200) return null;
      final body = utf8.decode(response.bodyBytes);
      final decoded = jsonDecode(body);

      if (decoded is Map<String, dynamic>) {
        // 中间层：指向真正的名单地址。
        final nested = decoded['rosterUrl'] as String?;
        if (nested != null && nested.trim().isNotEmpty) {
          return await fetch(nested.trim());
        }
        if (decoded.containsKey('students')) {
          return LuckyRoster.fromJson(
            decoded,
            source: LuckyRosterSource.remote,
            updatedAt: DateTime.now(),
          );
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
