import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_config.dart';

/// 首页的固定链接项。
class HomeLink {
  const HomeLink({
    required this.title,
    required this.subtitle,
    required this.slug,
    required this.type,
    required this.icon,
    this.url,
  });

  final String title;
  final String subtitle;

  /// WordPress slug（如 tip / join-ybh）。
  final String slug;

  /// 'post' 文章 / 'page' 页面。
  final String type;

  /// 图标名（如 coffee / group / gift）。
  final String icon;

  /// 可选：直接给链接地址（有 slug 时优先用 slug 拉内容原生渲染）。
  final String? url;

  Map<String, dynamic> toJson() => {
        'title': title,
        'subtitle': subtitle,
        'slug': slug,
        'type': type,
        'icon': icon,
        if (url != null) 'url': url,
      };

  factory HomeLink.fromJson(Map<String, dynamic> json) => HomeLink(
        title: (json['title'] as String?) ?? '',
        subtitle: (json['subtitle'] as String?) ?? '',
        slug: (json['slug'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'post',
        icon: (json['icon'] as String?) ?? 'link',
        url: json['url'] as String?,
      );
}

/// 首页配置：固定链接、公告、展台精选。
///
/// 这份配置托管在下载站 `home/config.json`，App 每次打开首页时拉取——
/// 站点改标题 / 换链接 / 发公告，App 端随之更新，无需发版。
class HomeConfig {
  const HomeConfig({
    this.links = const <HomeLink>[],
    this.announcement = '',
    this.featured = const <String>[],
  });

  final List<HomeLink> links;

  /// 展台顶部的公告文字。
  final String announcement;

  /// 展台精选文章 slug 列表；为空时展示最新文章。
  final List<String> featured;

  bool get isEmpty => links.isEmpty && announcement.isEmpty;

  /// 内置兜底配置：站点还没有部署 config.json 时也能工作。
  static const HomeConfig fallback = HomeConfig(
    links: [
      HomeLink(
        title: '请给我们钱',
        subtitle: '一份小小的支持，让我们走得更远',
        slug: 'tip',
        type: 'post',
        icon: 'coffee',
      ),
      HomeLink(
        title: '加入 YBH',
        subtitle: '成为我们的一员',
        slug: 'join-ybh',
        type: 'page',
        icon: 'group',
      ),
    ],
    announcement: '',
    featured: <String>[],
  );

  Map<String, dynamic> toJson() => {
        'links': links.map((l) => l.toJson()).toList(),
        'announcement': announcement,
        'featured': featured,
      };

  factory HomeConfig.fromJson(Map<String, dynamic> json) {
    final rawLinks = json['links'];
    return HomeConfig(
      links: rawLinks is List
          ? rawLinks
              .whereType<Map<String, dynamic>>()
              .map(HomeLink.fromJson)
              .toList()
          : const <HomeLink>[],
      announcement: (json['announcement'] as String?) ?? '',
      featured: (json['featured'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }
}

/// 拉取首页配置；失败时返回内置兜底 [HomeConfig.fallback]。
abstract final class HomeConfigFetcher {
  static const Duration _timeout = Duration(seconds: 15);

  static Future<HomeConfig> fetch() async {
    try {
      final response =
          await http.get(Uri.parse(AppConfig.homeConfigUrl)).timeout(_timeout);
      if (response.statusCode != 200) return HomeConfig.fallback;
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return HomeConfig.fallback;
      final config = HomeConfig.fromJson(decoded);
      return config.isEmpty ? HomeConfig.fallback : config;
    } catch (_) {
      return HomeConfig.fallback;
    }
  }
}
