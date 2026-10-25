import 'dart:async';

import 'package:flutter/material.dart';

import '../data/blog_api.dart';
import 'post_card.dart';
import 'post_detail_page.dart';

/// 文章搜索页：输入关键词，实时搜索标题与正文（REST `search` 参数）。
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  Timer? _debounce;

  List<PostSummary> _posts = const [];
  int _total = 0;
  bool _loading = false;
  bool _loadingMore = false;
  bool _searched = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(reset: true));
  }

  void _onScroll() {
    if (_loadingMore || _loading || _posts.length >= _total) return;
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300) {
      _search(reset: false);
    }
  }

  Future<void> _search({required bool reset}) async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _posts = const [];
        _total = 0;
        _searched = false;
        _error = null;
      });
      return;
    }
    final page = reset ? 1 : ((_posts.length ~/ 20) + 1);
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
        _searched = true;
      });
    } else {
      setState(() => _loadingMore = true);
    }
    try {
      final result = await BlogApi.fetchPosts(
          search: query,
          page: page,
          perPage: 20,
          fields: BlogApi.fieldsForList);
      if (!mounted) return;
      setState(() {
        if (reset) {
          _posts = result.posts;
        } else {
          _posts = [..._posts, ...result.posts];
        }
        _total = result.total;
        _loading = false;
        _loadingMore = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e;
      });
    }
  }

  void _clear() {
    _controller.clear();
    setState(() {
      _posts = const [];
      _total = 0;
      _searched = false;
      _error = null;
    });
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
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: (_) => _search(reset: true),
          decoration: InputDecoration(
            hintText: '搜索文章标题或内容…',
            border: InputBorder.none,
            suffixIcon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, child) {
                return value.text.isEmpty
                    ? const SizedBox.shrink()
                    : IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: _clear,
                      );
              },
            ),
          ),
        ),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5)),
              ),
            ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (!_searched) {
      return _Hint(
        icon: Icons.search,
        text: '输入关键词，搜索站内文章',
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_off_rounded, size: 56, color: colorScheme.primary.withValues(alpha: 0.7)),
            const SizedBox(height: 12),
            const Text('搜索失败，请检查网络'),
            const SizedBox(height: 16),
            FilledButton(onPressed: () => _search(reset: true), child: const Text('重试')),
          ],
        ),
      );
    }
    if (_posts.isEmpty) {
      return _Hint(
        icon: Icons.search_off,
        text: '没有找到「${_controller.text.trim()}」相关文章',
      );
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _posts.length + (_posts.length < _total ? 1 : 0),
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
        return PostCard(post: post, onTap: () => _openDetail(index));
      },
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 64, color: colorScheme.outline),
          const SizedBox(height: 14),
          Text(text, style: TextStyle(color: colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}
