import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';
import '../data/blog_api.dart';
import '../data/home_config.dart';
import '../data/site_stats.dart';
import '../lucky/lucky_page.dart';
import 'page_reader_page.dart';
import 'post_card.dart';
import 'post_detail_page.dart';

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
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        children: [
          _buildBrand(context),
          const SizedBox(height: 18),
          _buildQuickLinks(context),
          const SizedBox(height: 18),
          _buildTools(context),
          const SizedBox(height: 18),
          _buildShowcase(context),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 品牌区

  Widget _buildBrand(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Image.asset(
                'assets/icon/app_icon.png',
                width: 52,
                height: 52,
                cacheWidth: 104,
                cacheHeight: 104,
                errorBuilder: (context, error, stackTrace) => Icon(
                  Icons.article,
                  size: 44,
                  color: colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'YBH',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: colorScheme.onSurface,
                  ),
                ),
                Text(
                  '义编会 · ${AppConfig.blogUrl.replaceFirst('https://', '')}',
                  style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '一个正在慢慢长大的博客社区。写点什么，分享点什么，'
          '偶尔也摇个奖。',
          style: TextStyle(
            fontSize: 13.5,
            height: 1.7,
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
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
      // 配置了直链：整站页跳转，保持网站体验。
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _ExternalWebPage(url: link.url!),
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

  // ------------------------------------------------------------ 集成工具

  Widget _buildTools(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle(title: '集成小工具', icon: Icons.widgets_outlined),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ToolCard(
                icon: Icons.casino_outlined,
                title: '幸运摇人器',
                subtitle: '抽一人 / 连抽多人，含语音播报',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const LuckyPage()),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ToolCard(
                icon: Icons.public_outlined,
                title: '整站浏览',
                subtitle: '完整网站体验',
                onTap: widget.onOpenSite ?? () {},
              ),
            ),
          ],
        ),
      ],
    );
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

/// 打开站内链接的简易网页页（WebView，用于有直链的固定链接）。
class _ExternalWebPage extends StatefulWidget {
  const _ExternalWebPage({required this.url});

  final String url;

  @override
  State<_ExternalWebPage> createState() => _ExternalWebPageState();
}

class _ExternalWebPageState extends State<_ExternalWebPage> {
  @override
  Widget build(BuildContext context) {
    // 复用整站 WebView 能力（webview_tab.dart 里的 BlogWebViewPage）。
    // 简单起见：整站链接交给整站标签页处理，这里用浏览器打开。
    return Scaffold(
      appBar: AppBar(
        title: const Text('网页'),
        actions: [
          IconButton(
            tooltip: '用浏览器打开',
            onPressed: () => launchUrl(
              Uri.parse(widget.url),
              mode: LaunchMode.externalApplication,
            ),
            icon: const Icon(Icons.open_in_browser_outlined),
          ),
        ],
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.language_outlined, size: 48),
              const SizedBox(height: 12),
              const Text('这个链接指向网站页面'),
              const SizedBox(height: 6),
              Text(widget.url,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline,
                  )),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: () => launchUrl(
                  Uri.parse(widget.url),
                  mode: LaunchMode.externalApplication,
                ),
                icon: const Icon(Icons.open_in_browser),
                label: const Text('用浏览器打开'),
              ),
            ],
          ),
        ),
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

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 26, color: colorScheme.primary),
              const SizedBox(height: 10),
              Text(title,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: colorScheme.outline),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
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
