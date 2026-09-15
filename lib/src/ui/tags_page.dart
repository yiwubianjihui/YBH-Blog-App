import 'package:flutter/material.dart';

import '../data/blog_api.dart';
import 'post_card.dart';
import 'post_detail_page.dart';

/// 标签页：把站点的标签全部列出来，点进去看该标签下的文章。
///
/// 标签数据复用 [BlogCategory]（WP REST 里标签与分类字段同构），
/// 排序与分类一致：按文章数降序。
class TagsPage extends StatefulWidget {
  const TagsPage({super.key});

  @override
  State<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends State<TagsPage> {
  List<BlogCategory> _tags = const [];
  bool _loading = true;
  Object? _error;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tags = await BlogApi.fetchTags();
      if (!mounted) return;
      setState(() {
        _tags = tags;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  List<BlogCategory> get _visible {
    if (_filter.isEmpty) return _tags;
    final q = _filter.toLowerCase();
    return _tags.where((t) => t.name.toLowerCase().contains(q)).toList();
  }

  void _openTag(BlogCategory tag) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => TagPostsPage(tag: tag)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('标签')),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 56, color: colorScheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            const Text('标签加载失败，请检查网络'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_tags.isEmpty) {
      return Center(
        child: Text('站点还没有标签',
            style: TextStyle(color: colorScheme.onSurfaceVariant)),
      );
    }

    final tags = _visible;
    return Column(
      children: [
        // 标签多的时候给个筛选框，省得一路翻。
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            onChanged: (v) => setState(() => _filter = v.trim()),
            decoration: InputDecoration(
              isDense: true,
              hintText: '筛选标签（共 ${_tags.length} 个）',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        Expanded(
          child: tags.isEmpty
              ? Center(
                  child: Text('没有匹配的标签',
                      style: TextStyle(color: colorScheme.onSurfaceVariant)),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in tags)
                        _TagChip(tag: tag, onTap: () => _openTag(tag)),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 单个标签：名称 + 文章数。字号随文章数微调，形成轻量的「标签云」观感。
class _TagChip extends StatelessWidget {
  const _TagChip({required this.tag, required this.onTap});

  final BlogCategory tag;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 文章越多字号略大 —— 只做 12.5 → 15.5 的温和区间，避免排版被撑乱。
    final weight = tag.count.clamp(1, 20) / 20;
    final size = 12.5 + weight * 3;
    return Material(
      color: colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.tag, size: 13, color: colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                tag.name,
                style: TextStyle(
                  fontSize: size,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
              ),
              const SizedBox(width: 5),
              Text(
                '${tag.count}',
                style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 某个标签下的文章列表（分页加载，与搜索页同一套交互）。
class TagPostsPage extends StatefulWidget {
  const TagPostsPage({super.key, required this.tag});

  final BlogCategory tag;

  @override
  State<TagPostsPage> createState() => _TagPostsPageState();
}

class _TagPostsPageState extends State<TagPostsPage> {
  final ScrollController _scrollController = ScrollController();

  List<PostSummary> _posts = const [];
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_loadingMore || _loading || _posts.length >= _total) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      _load(reset: false);
    }
  }

  Future<void> _load({required bool reset}) async {
    final page = reset ? 1 : ((_posts.length ~/ 20) + 1);
    setState(() {
      if (reset) {
        _loading = true;
        _error = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final result = await BlogApi.fetchPosts(
        tagId: widget.tag.id,
        page: page,
        perPage: 20,
      );
      if (!mounted) return;
      setState(() {
        _posts = reset ? result.posts : [..._posts, ...result.posts];
        _total = result.total;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  void _openDetail(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PostDetailPage(posts: _posts, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text('#${widget.tag.name}'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _loading ? '加载中…' : '共 $_total 篇',
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded,
                size: 56, color: colorScheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            const Text('加载失败，请检查网络'),
            const SizedBox(height: 16),
            FilledButton(
                onPressed: () => _load(reset: true), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_posts.isEmpty) {
      return Center(
        child: Text('这个标签下还没有文章',
            style: TextStyle(color: colorScheme.onSurfaceVariant)),
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      itemCount: _posts.length + (_posts.length < _total ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _posts.length) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5)),
            ),
          );
        }
        return PostCard(post: _posts[index], onTap: () => _openDetail(index));
      },
    );
  }
}
