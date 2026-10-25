import 'package:flutter/material.dart';

import '../data/blog_api.dart';
import '../data/category_order.dart';
import 'post_card.dart';
import 'post_detail_page.dart';

/// 原生文章列表页（不依赖 WebView）：
/// - WordPress REST API 拉取文章
/// - 分类筛选 chips
/// - 下拉刷新、触底加载更多、加载/错误状态
class PostsTab extends StatefulWidget {
  const PostsTab({super.key, this.onOpenCategoryOrder});

  /// 打开「分类管理」页（由外壳提供，避免在文章页里重复导航逻辑）。
  final Future<void> Function()? onOpenCategoryOrder;

  @override
  State<PostsTab> createState() => PostsTabState();
}

class PostsTabState extends State<PostsTab> {
  final ScrollController _scrollController = ScrollController();

  List<PostSummary> _posts = const [];
  /// 服务器原始分类（按文章数降序），作为套用本地偏好的基准。
  List<BlogCategory> _rawCategories = const [];
  /// 套用本地偏好（置顶/排序/隐藏）后、实际用于筛选条展示的分类。
  List<BlogCategory> _categories = const [];
  int? _selectedCategoryId;
  bool _loading = true;
  bool _loadingMore = false;
  bool _categoriesLoading = true;
  bool _hasMore = false;
  Object? _error;

  /// 已隐藏的分类数量（在筛选条末尾的管理入口上提示，避免用户忘记自己藏过）。
  int _hiddenCount = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadInitial();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      _loadMore();
    }
  }

  Future<void> _loadInitial() async {
    await Future.wait([
      _loadPosts(reset: true, showSpinner: true),
      _loadCategories(),
    ]);
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await BlogApi.fetchCategories();
      if (!mounted) return;
      final prefs = await CategoryOrderStore.load();
      if (!mounted) return;
      setState(() {
        _rawCategories = categories;
        _categories = _applyPrefs(categories, prefs);
        _hiddenCount = _countHidden(categories, prefs);
        _categoriesLoading = false;
      });
      await _deselectHidden(prefs);
    } catch (_) {
      if (!mounted) return;
      setState(() => _categoriesLoading = false);
    }
  }

  /// 统计「确实存在且被隐藏」的分类数量。
  int _countHidden(List<BlogCategory> base, CategoryPrefs prefs) {
    final ids = base.map((c) => c.id).toSet();
    return prefs.hidden.where(ids.contains).length;
  }

  /// 套用本地偏好：置顶优先 → 自定义顺序 → 服务器顺序，并剔除已隐藏的分类。
  List<BlogCategory> _applyPrefs(List<BlogCategory> base, CategoryPrefs prefs) {
    return CategoryOrderStore.applyOrderWith<BlogCategory>(
      categories: base,
      idOf: (c) => c.id,
      order: prefs.order,
      pinned: prefs.pinned.toList(),
      hidden: prefs.hidden.toList(),
      excludeHidden: true,
    );
  }

  /// 若当前选中的分类被隐藏了，退回「全部」并重新拉文章。
  Future<void> _deselectHidden(CategoryPrefs prefs) async {
    final selected = _selectedCategoryId;
    if (selected == null) return;
    if (!prefs.hidden.contains(selected) || prefs.pinned.contains(selected)) {
      return;
    }
    if (!mounted) return;
    setState(() => _selectedCategoryId = null);
    await _loadPosts(reset: true, showSpinner: true);
  }

  /// 分类排序页保存后调用：重新按本地偏好套用到已加载的分类。
  Future<void> applyCategoryOrder() async {
    if (_categoriesLoading || _rawCategories.isEmpty) return;
    final prefs = await CategoryOrderStore.load();
    if (!mounted) return;
    setState(() {
      _categories = _applyPrefs(_rawCategories, prefs);
      _hiddenCount = _countHidden(_rawCategories, prefs);
    });
    await _deselectHidden(prefs);
  }

  Future<void> _loadPosts({bool reset = false, bool showSpinner = false}) async {
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final page = reset ? 1 : ((_posts.length ~/ 20) + 1);
    try {
      final result = await BlogApi.fetchPosts(
        categoryId: _selectedCategoryId,
        page: page,
        // 白名单保留 content：详情页正文直接复用列表带回来的这份，不再多一次往返。
        fields: BlogApi.fieldsForList,
      );
      if (!mounted) return;
      setState(() {
        if (reset) {
          _posts = result.posts;
        } else {
          _posts = [..._posts, ...result.posts];
        }
        // 以累计条数与总数比较，避免最后一页不足一页时误判“还有更多”导致底部无限转圈。
        _hasMore = _posts.length < result.total;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final page = (_posts.length ~/ 20) + 1;
      final result = await BlogApi.fetchPosts(
        categoryId: _selectedCategoryId,
        page: page,
        // 白名单保留 content：详情页正文直接复用列表带回来的这份，不再多一次往返。
        fields: BlogApi.fieldsForList,
      );
      if (!mounted) return;
      setState(() {
        _posts = [..._posts, ...result.posts];
        _hasMore = _posts.length < result.total;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载更多失败，请稍后重试')),
      );
    }
  }

  Future<void> refresh() => _loadPosts(reset: true);

  /// 服务器原始分类（未套用本地偏好），供「分类排序」页直接复用，避免重复联网。
  List<BlogCategory> get rawCategories => _rawCategories;

  Future<void> _selectCategory(int? id) async {
    if (_selectedCategoryId == id) return;
    setState(() => _selectedCategoryId = id);
    if (_scrollController.hasClients) {
      _scrollController.jumpTo(0);
    }
    await _loadPosts(reset: true, showSpinner: true);
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
    return Column(
      children: [
        _CategoryFilterBar(
          categories: _categories,
          loading: _categoriesLoading,
          selectedId: _selectedCategoryId,
          onSelected: _selectCategory,
          onManage: widget.onOpenCategoryOrder,
          hiddenCount: _hiddenCount,
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const _PostsSkeleton();
    }
    if (_error != null) {
      return _PostsError(
        error: _error!,
        onRetry: () => _loadPosts(reset: true, showSpinner: true),
      );
    }
    if (_posts.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.article_outlined, size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('这个分类下暂时没有文章', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _loadPosts(reset: true),
      child: ListView.builder(
        controller: _scrollController,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _posts.length + (_hasMore || _loadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _posts.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            );
          }
          final post = _posts[index];
          return PostCard(
            post: post,
            onTap: () => _openDetail(index),
          );
        },
      ),
    );
  }
}

/// 分类筛选横向滚动条。末尾固定一个「管理」入口，让置顶/隐藏功能不必去「我的」页翻找。
class _CategoryFilterBar extends StatelessWidget {
  const _CategoryFilterBar({
    required this.categories,
    required this.loading,
    required this.selectedId,
    required this.onSelected,
    this.onManage,
    this.hiddenCount = 0,
  });

  final List<BlogCategory> categories;
  final bool loading;
  final int? selectedId;
  final ValueChanged<int?> onSelected;
  final Future<void> Function()? onManage;

  /// 已隐藏的分类数（>0 时在管理入口上标出，避免用户忘记自己藏过）。
  final int hiddenCount;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: 52,
        child: Center(
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (categories.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('全部'),
              selected: selectedId == null,
              onSelected: (_) => onSelected(null),
            ),
          ),
          for (final category in categories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text('${category.name} · ${category.count}'),
                selected: selectedId == category.id,
                onSelected: (_) => onSelected(category.id),
              ),
            ),
          if (onManage != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: ActionChip(
                avatar: Icon(Icons.tune_outlined,
                    size: 16, color: colorScheme.primary),
                label: Text(
                  hiddenCount > 0 ? '管理（已隐藏 $hiddenCount）' : '管理',
                  style: TextStyle(
                    color: colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                backgroundColor: colorScheme.surface,
                side: BorderSide(color: colorScheme.outlineVariant),
                onPressed: () => onManage!(),
              ),
            ),
        ],
      ),
    );
  }
}

/// 加载骨架屏。
class _PostsSkeleton extends StatelessWidget {
  const _PostsSkeleton();

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: 6,
      itemBuilder: (context, index) {
        return Card(
          margin: const EdgeInsets.only(bottom: 12),
          child: SizedBox(
            height: 112,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 112, height: 112, color: base),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(height: 15, color: base),
                        const SizedBox(height: 8),
                        Container(height: 15, width: 180, color: base),
                        const SizedBox(height: 10),
                        Container(height: 11, color: base),
                        const SizedBox(height: 6),
                        Container(height: 11, width: 120, color: base),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PostsError extends StatelessWidget {
  const _PostsError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 64, color: colorScheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 16),
            const Text('文章加载失败', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('请检查网络连接后重试。', style: TextStyle(color: colorScheme.onSurfaceVariant)),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重新加载'),
            ),
          ],
        ),
      ),
    );
  }
}
