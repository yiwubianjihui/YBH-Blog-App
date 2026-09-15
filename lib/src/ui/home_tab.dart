import 'package:flutter/material.dart';

import '../app_config.dart';
import '../data/blog_api.dart';
import '../data/home_config.dart';
import '../data/site_stats.dart';
import '../lucky/lucky_page.dart';
import '../shell/webview_ui_state.dart';
import '../shell/webview_tab.dart' if (dart.library.html) '../shell/webview_tab_stub.dart';
import 'page_reader_page.dart';
import 'post_card.dart';
import 'post_detail_page.dart';
import 'search_page.dart';
import 'tags_page.dart';

/// 首页：YBH 品牌区 + 随站点动态更新的固定链接 + 集成小工具 + 展台。
///
/// 固定链接与展台精选由 `home/config.json` 驱动（站点可随时改），
/// 统计数字（文章数 / 总字数 / 建站天数）由 [SiteStatsFetcher] 实时计算。
class HomeTab extends StatefulWidget {
  const HomeTab({super.key, this.onOpenSite});

  /// 由外壳注入：点击「整站浏览」工具卡时切到「整站」标签。
  final VoidCallback? onOpenSite;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  HomeConfig _config = HomeConfig.fallback;
  SiteStats? _stats;
  List<PostSummary> _featured = const <PostSummary>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final config = await HomeConfigFetcher.fetch();
    final stats = await SiteStatsFetcher.fetch();
    final featured = await _fetchFeatured(config);
    if (!mounted) return;
    setState(() {
      _config = config;
      _stats = stats;
      _featured = featured;
      _loading = false;
    });
  }

  /// 拉取展台精选文章：优先用配置里的 slug，否则用最新文章。
  Future<List<PostSummary>> _fetchFeatured(HomeConfig config) async {
    if (config.featured.isNotEmpty) {
      final posts = await BlogApi.fetchPostsBySlugs(config.featured);
      if (posts.isNotEmpty) return posts;
    }
    final page = await BlogApi.fetchPosts(perPage: 5);
    return page.posts;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
        // 区块顺序对齐**网站主页的组件顺序**：
        //   首屏 → 顶栏工具 → 主入口 → 导航分组 → 文章流/统计 → 页脚
        children: [
          _buildHero(context),
          const SizedBox(height: 14),
          _buildToolRow(context),
          const SizedBox(height: 18),
          _buildQuickLinks(context),
          const SizedBox(height: 18),
          _buildNavGroups(context),
          const SizedBox(height: 18),
          _buildShowcase(context),
          const SizedBox(height: 18),
          _buildFooter(context),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 首屏（对应网站 Hero）

  Widget _buildHero(BuildContext context) {
    final hero = _config.hero;
    return _HeroCard(
      title: hero.title.isEmpty ? 'YBH' : hero.title,
      subtitle: hero.subtitle.isEmpty
          ? '义编会 · ${AppConfig.blogUrl.replaceFirst('https://', '')}'
          : hero.subtitle,
      tagline: hero.tagline,
      signature: hero.signature,
      coverUrl: hero.cover ? _coverUrl : null,
      coverFallbackUrl: hero.cover ? _coverFallbackUrl : null,
      social: _config.social,
      onShuffle: hero.cover ? _shuffleCover : null,
      onOpenUrl: _openUrl,
    );
  }

  /// 首屏背景：站点随机图库。每次进首页/点「换封面」都换一张。
  ///
  /// 走主题的轻量端点 `rand-cover.php`（不加载 WordPress），
  /// 另存一份内建 REST 地址做兜底（见 [CoverImage]）。
  String _coverUrl = AppConfig.randomCoverUrl();
  String _coverFallbackUrl = AppConfig.randomCoverUrlFallback();

  void _shuffleCover() {
    setState(() {
      _coverUrl = AppConfig.randomCoverUrl();
      _coverFallbackUrl = AppConfig.randomCoverUrlFallback();
    });
  }

  // ------------------------------------------------------------ 顶栏工具（对应网站顶栏）

  Widget _buildToolRow(BuildContext context) {
    final tools = _config.tools;
    if (tools.isEmpty) return const SizedBox.shrink();
    return _ActionRow(
      actions: [
        for (final t in tools)
          _RowAction(
            label: t.label,
            icon: _iconFor(t.icon),
            onTap: () => _runTool(t),
          ),
      ],
    );
  }

  void _runTool(HomeTool tool) {
    switch (tool.action) {
      case 'search':
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const SearchPage()),
        );
      case 'randomPost':
        _openUrl(AppConfig.randomPostUrl, '随机文章');
      case 'shuffleCover':
        _shuffleCover();
      case 'site':
        widget.onOpenSite?.call();
      default:
        final url = tool.url;
        if (url != null && url.isNotEmpty) _openUrl(url, tool.label);
    }
  }

  // ------------------------------------------------------------ 导航分组（对应网站主导航）

  Widget _buildNavGroups(BuildContext context) {
    final groups = _config.nav;
    if (groups.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < groups.length; i++) ...[
          if (i > 0) const SizedBox(height: 14),
          _NavGroupCard(
            group: groups[i],
            onOpen: (link) => _openUrl(link.url ?? '', link.title),
          ),
        ],
      ],
    );
  }

  // ------------------------------------------------------------ 页脚（对应网站页脚）

  Widget _buildFooter(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final l in _config.footer)
              _FootChip(
                label: l.title,
                onTap: () => _openUrl(l.url ?? '', l.title),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'YBH 客户端 · 主题 SakurairoYBH（forked from Sakurairo by Fuukei）',
          style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
        ),
        const SizedBox(height: 2),
        Text(
          '内容由 WordPress 驱动 · ${AppConfig.blogUrl.replaceFirst('https://', '')}',
          style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 打开链接

  /// 打开一个地址：站内留在应用内（WebView），站外同样用应用内 WebView
  /// （内部导航策略会把站外转交系统浏览器）。
  void _openUrl(String url, String title) {
    if (url.isEmpty) return;
    // 幸运摇人器有原生实现（含语音播报），别让它退化到网页版
    if (url.contains('lr.yibianhui.cn')) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const LuckyPage()),
      );
      return;
    }
    // 标签页也是原生实现：用 app:// 前缀在配置里标记，避免为它单开一套 schema。
    if (url.startsWith('app://tags')) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const TagsPage()),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _InAppWebPage(title: title, url: url),
      ),
    );
  }

  // ------------------------------------------------------------ 固定链接

  Widget _buildQuickLinks(BuildContext context) {
    final links = _config.links;
    if (links.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: '从这里开始', icon: Icons.bolt_outlined),
        const SizedBox(height: 10),
        for (final link in links)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _QuickLinkCard(
              link: link,
              onTap: () => _openLink(link),
            ),
          ),
      ],
    );
  }

  void _openLink(HomeLink link) {
    if (link.url != null && link.url!.isNotEmpty) {
      // 配置了直链：应用内 WebView 直接打开（站内留在应用内，站外自动转浏览器）。
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _InAppWebPage(title: link.title, url: link.url!),
        ),
      );
      return;
    }
    // 有 slug：原生拉取内容渲染（与「文章」一致）。
    if (link.slug.isNotEmpty) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PageReaderPage(
            title: link.title,
            slug: link.slug,
            type: link.type,
          ),
        ),
      );
    }
  }

  // ------------------------------------------------------------ 展台

  Widget _buildShowcase(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '展台', icon: Icons.auto_awesome_outlined),
        const SizedBox(height: 10),
        if (_config.announcement.isNotEmpty) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colorScheme.primaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(Icons.campaign_outlined,
                    size: 17, color: colorScheme.onPrimaryContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _config.announcement,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.5,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
        ],
        _buildStatsRow(colorScheme),
        const SizedBox(height: 10),
        if (_featured.isNotEmpty)
          for (final post in _featured.take(3))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: PostCard(
                post: post,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PostDetailPage(
                      posts: _featured,
                      initialIndex: _featured.indexOf(post),
                    ),
                  ),
                ),
              ),
            ),
        if (_stats == null && _featured.isEmpty && !_loading)
          Text(
            '展台暂时没有内容',
            style: TextStyle(fontSize: 13, color: colorScheme.outline),
          ),
      ],
    );
  }

  Widget _buildStatsRow(ColorScheme colorScheme) {
    final stats = _stats;
    return Row(
      children: [
        Expanded(
          child: _StatCard(
            icon: Icons.article_outlined,
            value: stats == null ? '—' : '${stats.postCount}',
            label: '篇文章',
            color: colorScheme.primary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.edit_note_outlined,
            value: stats == null ? '—' : stats.wordCountLabel,
            label: '总字数',
            color: colorScheme.tertiary,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _StatCard(
            icon: Icons.hourglass_bottom_outlined,
            value: stats == null ? '—' : '${stats.siteAgeDays}',
            label: '天陪伴',
            color: colorScheme.secondary,
          ),
        ),
      ],
    );
  }
}

/// 应用内网页：首页「从这里开始」里配置了直链的卡片用它打开。
///
/// 之前这里是个占位页 —— 只提示「这个链接指向网站页面」，再让用户手动去浏览器，
/// 等于点了没反应。现在直接内嵌 WebView：站内地址留在应用内，
/// 站外地址仍由 [BlogWebViewPage] 的导航策略转交系统浏览器。
class _InAppWebPage extends StatefulWidget {
  const _InAppWebPage({required this.title, required this.url});

  final String title;
  final String url;

  @override
  State<_InAppWebPage> createState() => _InAppWebPageState();
}

class _InAppWebPageState extends State<_InAppWebPage> {
  final WebViewUiState _ui = WebViewUiState();
  final GlobalKey<BlogWebViewState> _webKey = GlobalKey<BlogWebViewState>();

  @override
  void dispose() {
    _ui.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: SizedBox(
            height: 3,
            child: ListenableBuilder(
              listenable: _ui.merged,
              builder: (context, child) {
                if (!_ui.loading.value) return const SizedBox.shrink();
                final progress = _ui.progress.value;
                return LinearProgressIndicator(
                  value: progress <= 0 ? null : progress / 100,
                  minHeight: 3,
                );
              },
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => _webKey.currentState?.reload(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: '用浏览器打开',
            onPressed: () => _webKey.currentState?.openInBrowser(),
            icon: const Icon(Icons.open_in_browser_outlined),
          ),
        ],
      ),
      body: BlogWebViewPage(
        key: _webKey,
        uiState: _ui,
        initialUrl: widget.url,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(icon, size: 17, color: colorScheme.primary),
        const SizedBox(width: 6),
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}

class _QuickLinkCard extends StatelessWidget {
  const _QuickLinkCard({required this.link, required this.onTap});

  final HomeLink link;
  final VoidCallback onTap;

  IconData get _icon => switch (link.icon) {
        'coffee' => Icons.coffee_outlined,
        'group' => Icons.group_outlined,
        'gift' => Icons.card_giftcard_outlined,
        'heart' => Icons.favorite_outline,
        'link' => Icons.link_outlined,
        _ => Icons.link_outlined,
      };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(_icon, color: colorScheme.onPrimaryContainer, size: 22),
        ),
        title: Text(link.title,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: link.subtitle.isEmpty
            ? null
            : Text(link.subtitle,
                style: TextStyle(fontSize: 12, color: colorScheme.outline)),
        trailing: const Icon(Icons.chevron_right_outlined),
        onTap: onTap,
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.icon,
    required this.value,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String value;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: colorScheme.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// 以下为「对齐网站主页组件」新增的部件
// ============================================================================

/// 图标名 → Material 图标。配置里只写名字，映射放在 App 端，
/// 这样站点改配置不必关心 Flutter 的图标常量。
IconData _iconFor(String name) => switch (name) {
      'coffee' => Icons.coffee_outlined,
      'group' => Icons.group_outlined,
      'gift' => Icons.card_giftcard_outlined,
      'heart' => Icons.favorite_outline,
      'article' => Icons.article_outlined,
      'edit' => Icons.edit_outlined,
      'info' => Icons.info_outline,
      'link' => Icons.link_outlined,
      'casino' => Icons.casino_outlined,
      'school' => Icons.school_outlined,
      'campaign' => Icons.campaign_outlined,
      'download' => Icons.download_outlined,
      'person_add' => Icons.person_add_alt_outlined,
      'search' => Icons.search_outlined,
      'shuffle' => Icons.shuffle_outlined,
      'image' => Icons.image_outlined,
      'public' => Icons.public_outlined,
      'github' => Icons.code_outlined,
      'music' => Icons.music_note_outlined,
      'mail' => Icons.mail_outline,
      'wechat' => Icons.chat_bubble_outline,
      'explore' => Icons.explore_outlined,
      'hub' => Icons.hub_outlined,
      'history' => Icons.history_outlined,
      'shield' => Icons.shield_outlined,
      'cookie' => Icons.cookie_outlined,
      'gavel' => Icons.gavel_outlined,
      'bolt' => Icons.bolt_outlined,
      'widgets' => Icons.widgets_outlined,
      'star' => Icons.auto_awesome_outlined,
      'tag' => Icons.tag,
      _ => Icons.link_outlined,
    };

/// 首屏卡片 —— 对应网站主页的首屏：随机封面背景 + 大字标题 + 日文题词
/// + 站点头像 + 社交图标行 + 「换封面」。
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.title,
    required this.subtitle,
    required this.tagline,
    required this.signature,
    required this.coverUrl,
    required this.coverFallbackUrl,
    required this.social,
    required this.onShuffle,
    required this.onOpenUrl,
  });

  final String title;
  final String subtitle;
  final String tagline;
  final String signature;
  final String? coverUrl;
  final String? coverFallbackUrl;
  final List<HomeSocial> social;
  final VoidCallback? onShuffle;
  final void Function(String url, String label) onOpenUrl;

  /// 封面与兜底都取不到时的底：主题色渐变。
  static Widget _gradient(ColorScheme c) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [c.primary, c.tertiary],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const onCover = Colors.white;
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: Stack(
        children: [
          // 背景：站点随机封面；两个端点都取不到才退成主题色渐变
          Positioned.fill(
            child: coverUrl == null
                ? _gradient(colorScheme)
                : CoverImage(
                    url: coverUrl!,
                    fallbackUrl: coverFallbackUrl,
                    errorWidget: _gradient(colorScheme),
                  ),
          ),
          // 压暗一层，保证白字在任何封面上都读得清
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.28),
                    Colors.black.withValues(alpha: 0.62),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Container(
                        color: Colors.white.withValues(alpha: 0.16),
                        padding: const EdgeInsets.all(3),
                        child: Image.asset(
                          'assets/icon/app_icon.png',
                          width: 44,
                          height: 44,
                          cacheWidth: 88,
                          cacheHeight: 88,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.article,
                            size: 40,
                            color: onCover,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 30,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                              color: onCover,
                            ),
                          ),
                          if (subtitle.isNotEmpty)
                            Text(
                              subtitle,
                              style: TextStyle(
                                fontSize: 12,
                                color: onCover.withValues(alpha: 0.82),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (onShuffle != null)
                      IconButton(
                        onPressed: onShuffle,
                        tooltip: '换封面',
                        icon: Icon(Icons.casino_outlined,
                            color: onCover.withValues(alpha: 0.9), size: 20),
                      ),
                  ],
                ),
                if (signature.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      signature,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: onCover.withValues(alpha: 0.95),
                      ),
                    ),
                  ),
                ],
                if (tagline.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    tagline,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.65,
                      color: onCover.withValues(alpha: 0.92),
                    ),
                  ),
                ],
                if (social.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in social)
                        _SocialChip(
                          label: s.label,
                          icon: _iconFor(s.icon),
                          onTap: () => onOpenUrl(s.url, s.label),
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SocialChip extends StatelessWidget {
  const _SocialChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: Colors.white),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶栏工具行 —— 对应网站顶栏的「搜索 / 随机换张背景 / 随机文章」。
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.actions});

  final List<_RowAction> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: actions[i]),
        ],
      ],
    );
  }
}

class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Column(
            children: [
              Icon(icon, size: 19, color: colorScheme.primary),
              const SizedBox(height: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 导航分组 —— 对应网站主导航的分组（「逛站点」「我们的站点」）。
class _NavGroupCard extends StatelessWidget {
  const _NavGroupCard({required this.group, required this.onOpen});

  final HomeNavGroup group;
  final void Function(HomeLink link) onOpen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionTitle(title: group.title, icon: _iconFor(group.icon)),
        if (group.subtitle.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3, left: 23),
            child: Text(
              group.subtitle,
              style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
            ),
          ),
        const SizedBox(height: 10),
        Card(
          clipBehavior: Clip.antiAlias,
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < group.links.length; i++) ...[
                if (i > 0) const Divider(height: 1, indent: 62),
                ListTile(
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Icon(_iconFor(group.links[i].icon),
                        size: 20, color: colorScheme.onPrimaryContainer),
                  ),
                  title: Text(
                    group.links[i].title,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w700),
                  ),
                  subtitle: group.links[i].subtitle.isEmpty
                      ? null
                      : Text(
                          group.links[i].subtitle,
                          style: TextStyle(
                              fontSize: 12, color: colorScheme.outline),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                  onTap: () => onOpen(group.links[i]),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 页脚的法务胶囊 —— 对应网站页脚的「更新日志 / 隐私政策 / Cookie 政策 / 用户协议」。
class _FootChip extends StatelessWidget {
  const _FootChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: colorScheme.outlineVariant),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
