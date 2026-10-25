import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';

/// 远程版本信息（对应 YBH-blog-release/update/version.json 模板）。
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.url,
  });

  /// 最新版本号，如 "0.0.5"。
  final String version;

  /// 更新说明（多行文本）。
  final String notes;

  /// 下载地址（安装包或下载页，用系统浏览器打开）。
  final String url;

  bool get isValid => version.trim().isNotEmpty && url.trim().isNotEmpty;

  factory UpdateInfo.fromJson(Map<String, dynamic> json) {
    return UpdateInfo(
      version: (json['version'] as String?)?.trim() ?? '',
      notes: (json['notes'] as String?) ?? '',
      url: (json['url'] as String?)?.trim() ?? '',
    );
  }
}

/// 检查更新：拉取远程版本清单并与当前版本比较。
abstract final class UpdateChecker {
  /// 解析 "a.b.c" / "a.b" 版本号为可比较三元组；非法返回 null。
  static (int, int, int)? parseVersion(String version) {
    final parts = version.trim().split('.');
    if (parts.isEmpty || parts.length > 3) return null;
    final nums = <int>[];
    for (final part in parts) {
      final n = int.tryParse(part);
      if (n == null || n < 0) return null;
      nums.add(n);
    }
    while (nums.length < 3) {
      nums.add(0);
    }
    return (nums[0], nums[1], nums[2]);
  }

  /// 当前版本是否低于 [latest]。
  ///
  /// 按 `MAJOR.MINOR.PATCH` **逐段数值**比较，不按字符串 —
  /// 否则 `0.1.0` 会被判成低于 `0.0.9`、`0.0.10` 会低于 `0.0.9`，
  /// 老用户就永远收不到更新提示。
  static bool isNewerVersion(String current, String latest) {
    final c = parseVersion(current);
    final l = parseVersion(latest);
    if (c == null || l == null) return false;
    if (l.$1 != c.$1) return l.$1 > c.$1;
    if (l.$2 != c.$2) return l.$2 > c.$2;
    return l.$3 > c.$3;
  }

  /// 当前安装版本号（versionName）。
  static Future<String> currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '0.0.0';
    }
  }

  /// 拉取远程版本清单；网络失败、超时或格式非法时返回 null。
  static Future<UpdateInfo?> fetch() async {
    final uri = Uri.parse(AppConfig.updateManifestUrl);
    final http.Response response;
    try {
      response = await http.get(uri).timeout(const Duration(seconds: 12));
    } catch (_) {
      return null;
    }
    if (response.statusCode != 200) return null;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final info = UpdateInfo.fromJson(decoded);
      return info.isValid ? info : null;
    } catch (_) {
      return null;
    }
  }

  /// 展示「发现新版本」对话框，可选择用系统浏览器打开下载页。
  static Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          icon: Icon(
            Icons.system_update_alt,
            size: 36,
            color: Theme.of(dialogContext).colorScheme.primary,
          ),
          title: Text('发现新版本 v${info.version}'),
          content: SingleChildScrollView(
            child: Text(
              info.notes.trim().isEmpty ? '新版本已发布，去看看更新内容吧。' : info.notes,
              style: const TextStyle(height: 1.6, fontSize: 14),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('稍后'),
            ),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                launchUrl(
                  Uri.parse(info.url),
                  mode: LaunchMode.externalApplication,
                );
              },
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('去下载'),
            ),
          ],
        );
      },
    );
  }
}