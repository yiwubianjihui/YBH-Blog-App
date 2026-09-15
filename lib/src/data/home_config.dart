import 'dart:convert';

import 'package:http/http.dart' as http;

import '../app_config.dart';

/// 首页里的一个链接项。
class HomeLink {
  const HomeLink({
    required this.title,
    this.subtitle = '',
    this.slug = '',
    this.type = 'post',
    this.icon = 'link',
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

/// 导航分组 —— 对应网站主导航里的下拉分组（「关于 YBH」「我们的站点」）。
class HomeNavGroup {
  const HomeNavGroup({
    required this.title,
    this.icon = 'link',
    this.subtitle = '',
    this.links = const <HomeLink>[],
  });

  final String title;
  final String icon;
  final String subtitle;
  final List<HomeLink> links;

  Map<String, dynamic> toJson() => {
        'title': title,
        'icon': icon,
        'subtitle': subtitle,
        'links': links.map((l) => l.toJson()).toList(),
      };

  factory HomeNavGroup.fromJson(Map<String, dynamic> json) => HomeNavGroup(
        title: (json['title'] as String?) ?? '',
        icon: (json['icon'] as String?) ?? 'link',
        subtitle: (json['subtitle'] as String?) ?? '',
        links: (json['links'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(HomeLink.fromJson)
                .toList() ??
            const <HomeLink>[],
      );
}

/// 社交入口 —— 对应网站首屏那一排图标（GitHub / 网易云 / 微信 / 邮箱）。
class HomeSocial {
  const HomeSocial({required this.label, required this.url, this.icon = 'link'});

  final String label;

  /// 可以是 http(s) 链接，也可以是 `mailto:` 之类。
  final String url;
  final String icon;

  Map<String, dynamic> toJson() =>
      {'label': label, 'url': url, 'icon': icon};

  factory HomeSocial.fromJson(Map<String, dynamic> json) => HomeSocial(
        label: (json['label'] as String?) ?? '',
        url: (json['url'] as String?) ?? '',
        icon: (json['icon'] as String?) ?? 'link',
      );
}

/// 顶部工具 —— 对应网站顶栏的「搜索 / 随机换张背景 / 随机文章 / 登录」。
class HomeTool {
  const HomeTool({
    required this.label,
    required this.action,
    this.icon = 'link',
    this.url,
  });

  final String label;

  /// 'search' | 'randomPost' | 'shuffleCover' | 'site' | 'url'
  final String action;
  final String icon;
  final String? url;

  Map<String, dynamic> toJson() => {
        'label': label,
        'action': action,
        'icon': icon,
        if (url != null) 'url': url,
      };

  factory HomeTool.fromJson(Map<String, dynamic> json) => HomeTool(
        label: (json['label'] as String?) ?? '',
        action: (json['action'] as String?) ?? 'url',
        icon: (json['icon'] as String?) ?? 'link',
        url: json['url'] as String?,
      );
}

/// 首屏 —— 对应网站首屏 Hero（封面背景 + 大字标题 + 签名行 + 头像）。
class HomeHero {
  const HomeHero({
    this.title = 'YBH',
    this.subtitle = '',
    this.tagline = '',
    this.signature = '',
    this.cover = true,
  });

  final String title;
  final String subtitle;
  final String tagline;

  /// 网站首屏那行日文题词（Klee One 字体）。
  final String signature;

  /// 是否用站点的随机封面做背景。
  final bool cover;

  Map<String, dynamic> toJson() => {
        'title': title,
        'subtitle': subtitle,
        'tagline': tagline,
        'signature': signature,
        'cover': cover,
      };

  factory HomeHero.fromJson(Map<String, dynamic> json) => HomeHero(
        title: (json['title'] as String?) ?? 'YBH',
        subtitle: (json['subtitle'] as String?) ?? '',
        tagline: (json['tagline'] as String?) ?? '',
        signature: (json['signature'] as String?) ?? '',
        cover: json['cover'] != false,
      );
}

/// 首页配置：首屏 / 工具 / 导航分组 / 固定链接 / 公告 / 展台精选 / 页脚。
///
/// 这份配置托管在下载站 `home/config.json`，App 每次打开首页时拉取——
/// 站点改标题 / 换链接 / 发公告 / 调导航，App 端随之更新，无需发版。
///
/// ⚠️ 字段都是**可选**的：站点上还是旧版 config.json（或干脆没有）时，
/// 缺的部分自动退回本文件里的 [fallback]，绝不让首页变成空白。
class HomeConfig {
  const HomeConfig({
    this.links = const <HomeLink>[],
    this.announcement = '',
    this.featured = const <String>[],
    this.hero = const HomeHero(),
    this.social = const <HomeSocial>[],
    this.tools = const <HomeTool>[],
    this.nav = const <HomeNavGroup>[],
    this.footer = const <HomeLink>[],
  });

  final List<HomeLink> links;

  /// 展台顶部的公告文字。
  final String announcement;

  /// 展台精选文章 slug 列表；为空时展示最新文章。
  final List<String> featured;

  final HomeHero hero;
  final List<HomeSocial> social;
  final List<HomeTool> tools;
  final List<HomeNavGroup> nav;
  final List<HomeLink> footer;

  bool get isEmpty => links.isEmpty && announcement.isEmpty;

  /// 站点连 config.json 都没部署时的兜底：与网站主页的组件保持一致。
  static const HomeConfig fallback = HomeConfig(
    links: <HomeLink>[
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
    hero: HomeHero(
      title: 'YBH',
      subtitle: '义编会 · www.yibianhui.cn',
      tagline: '一个正在慢慢长大的博客社区。写点什么，分享点什么，偶尔也摇个奖。',
      signature: '季節の変わり目の服は、',
    ),
    social: <HomeSocial>[
      HomeSocial(
          label: 'GitHub',
          url: 'https://github.com/yiwubianjihui',
          icon: 'github'),
      HomeSocial(label: '网易云', url: 'https://music.163.com/', icon: 'music'),
      HomeSocial(label: '邮箱', url: 'mailto:ybh@yibianhui.cn', icon: 'mail'),
    ],
    tools: <HomeTool>[
      HomeTool(label: '搜索', action: 'search', icon: 'search'),
      HomeTool(label: '随机文章', action: 'randomPost', icon: 'shuffle'),
      HomeTool(label: '换封面', action: 'shuffleCover', icon: 'image'),
      HomeTool(label: '整站浏览', action: 'site', icon: 'public'),
    ],
    nav: <HomeNavGroup>[
      HomeNavGroup(
        title: '逛站点',
        icon: 'explore',
        subtitle: '网站主页的主入口',
        links: <HomeLink>[
          HomeLink(
              title: '全部文章',
              subtitle: '按分类浏览全部内容',
              url: 'https://www.yibianhui.cn/all-articles/',
              icon: 'article'),
          HomeLink(
              title: '我要投稿',
              subtitle: '把你的作品发到 YBH',
              url: 'https://www.yibianhui.cn/submit/',
              icon: 'edit'),
          HomeLink(
              title: '关于我们',
              subtitle: 'YBH 是什么',
              url: 'https://www.yibianhui.cn/about/',
              icon: 'info'),
          HomeLink(
              title: '友情链接',
              subtitle: '和谁在一起玩',
              url: 'https://www.yibianhui.cn/links/',
              icon: 'link'),
        ],
      ),
      HomeNavGroup(
        title: '我们的站点',
        icon: 'hub',
        subtitle: 'YBH 旗下的其他站点',
        links: <HomeLink>[
          HomeLink(
              title: '幸运摇人器',
              subtitle: '抽一人 / 连抽多人，含语音播报',
              url: 'https://lr.yibianhui.cn',
              icon: 'casino'),
          HomeLink(
              title: '教师节',
              subtitle: '教师节祝福墙',
              url: 'https://teacher.yibianhui.cn',
              icon: 'school'),
          HomeLink(
              title: '广播站',
              subtitle: '校园歌单与点歌',
              url: 'https://brs.yibianhui.cn',
              icon: 'campaign'),
          HomeLink(
              title: '客户端下载',
              subtitle: 'Android 客户端',
              url: 'https://app.yibianhui.cn',
              icon: 'download'),
        ],
      ),
    ],
    footer: <HomeLink>[
      HomeLink(
          title: '更新日志',
          url: 'https://www.yibianhui.cn/changelog/',
          icon: 'history'),
      HomeLink(
          title: '隐私政策',
          url: 'https://www.yibianhui.cn/privacy-policy/',
          icon: 'shield'),
      HomeLink(
          title: 'Cookie 政策',
          url: 'https://www.yibianhui.cn/cookie-policy/',
          icon: 'cookie'),
      HomeLink(
          title: '用户协议',
          url: 'https://www.yibianhui.cn/user-agreement/',
          icon: 'gavel'),
    ],
  );

  Map<String, dynamic> toJson() => {
        'links': links.map((l) => l.toJson()).toList(),
        'announcement': announcement,
        'featured': featured,
        'hero': hero.toJson(),
        'social': social.map((s) => s.toJson()).toList(),
        'tools': tools.map((t) => t.toJson()).toList(),
        'nav': nav.map((g) => g.toJson()).toList(),
        'footer': footer.map((l) => l.toJson()).toList(),
      };

  factory HomeConfig.fromJson(Map<String, dynamic> json) {
    final rawLinks = json['links'];
    final rawHero = json['hero'];
    return HomeConfig(
      links: _linkList(rawLinks),
      announcement: (json['announcement'] as String?) ?? '',
      featured: (json['featured'] as List<dynamic>? ?? const [])
          .map((e) => e.toString())
          .toList(),
      hero: rawHero is Map<String, dynamic>
          ? HomeHero.fromJson(rawHero)
          : const HomeHero(),
      social: (json['social'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(HomeSocial.fromJson)
              .toList() ??
          const <HomeSocial>[],
      tools: (json['tools'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(HomeTool.fromJson)
              .toList() ??
          const <HomeTool>[],
      nav: (json['nav'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(HomeNavGroup.fromJson)
              .toList() ??
          const <HomeNavGroup>[],
      footer: _linkList(json['footer']),
    );
  }

  static List<HomeLink> _linkList(Object? raw) => raw is List
      ? raw.whereType<Map<String, dynamic>>().map(HomeLink.fromJson).toList()
      : const <HomeLink>[];
}

/// 拉取首页配置；失败时返回内置兜底 [HomeConfig.fallback]。
///
/// 站点上的 config.json 可以只写一部分字段（例如只改 announcement）——
/// **缺失的组件段会逐段退回 fallback**，这样新旧配置都能正常用。
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
      if (config.isEmpty) return HomeConfig.fallback;
      return config.mergedWithFallback();
    } catch (_) {
      return HomeConfig.fallback;
    }
  }
}

extension HomeConfigMerge on HomeConfig {
  /// 站点配置里没写的组件段，用 fallback 补齐。
  ///
  /// 这样站点只要维护自己关心的那几段（比如只发个公告），
  /// 首屏 / 工具 / 导航 / 页脚照样有内容 —— 不会凭空少了半页。
  HomeConfig mergedWithFallback() {
    const f = HomeConfig.fallback;
    return HomeConfig(
      links: links.isEmpty ? f.links : links,
      announcement: announcement,
      featured: featured,
      hero: hero.title.isEmpty ? f.hero : hero,
      social: social.isEmpty ? f.social : social,
      tools: tools.isEmpty ? f.tools : tools,
      nav: nav.isEmpty ? f.nav : nav,
      footer: footer.isEmpty ? f.footer : footer,
    );
  }
}
