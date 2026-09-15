import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../data/blog_api.dart';

/// 文章卡片（列表与搜索结果共用）。
class PostCard extends StatelessWidget {
  const PostCard({super.key, required this.post, this.onTap});

  final PostSummary post;
  final VoidCallback? onTap;

  static String formatDate(DateTime? date) {
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 112,
              height: 112,
              child: CoverImage(
                url: post.coverUrl,
                fallbackUrl: post.coverUrlFallback,
                memCacheWidth: 448,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, height: 1.35),
                    ),
                    if (post.excerpt.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        post.excerpt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: colorScheme.onSurfaceVariant, height: 1.45),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.schedule_outlined, size: 13, color: colorScheme.outline),
                        const SizedBox(width: 4),
                        Text(
                          formatDate(post.date),
                          style: TextStyle(fontSize: 11.5, color: colorScheme.outline),
                        ),
                        const SizedBox(width: 8),
                        if (post.terms.isNotEmpty)
                          Expanded(
                            child: Text(
                              post.terms.take(2).join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: colorScheme.primary),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 封面占位（渐变 + 图标）。
class CoverPlaceholder extends StatelessWidget {
  const CoverPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.75),
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.45),
          ],
        ),
      ),
      child: const Center(
        child: Icon(Icons.article_outlined, color: Colors.white70, size: 30),
      ),
    );
  }
}

/// 封面图：先试主地址，失败自动换兜底地址重试一次，再失败才显示占位。
///
/// 为什么要这一层：App 的封面走主题的轻量端点 `rand-cover.php`（不加载 WordPress，
/// 比内建 REST 快两个数量级）。但它毕竟是个主题文件 —— 万一主题被换掉、
/// 文件被删，所有卡片会同时变成占位图。这里让它**自动退回内建 REST**，多一层保险。
class CoverImage extends StatefulWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
    this.memCacheWidth,
    this.errorWidget,
  });

  final String url;
  final String? fallbackUrl;
  final BoxFit fit;
  final int? memCacheWidth;

  /// 两个地址都失败时显示什么（默认 [CoverPlaceholder]）。
  final Widget? errorWidget;

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  late String _url = widget.url;
  bool _switched = false;

  @override
  void didUpdateWidget(CoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 父级换了图（例如点「换封面」）：跟着换，并允许重新走一次兜底
    if (oldWidget.url != widget.url) {
      _url = widget.url;
      _switched = false;
    }
  }

  void _switchToFallback() {
    final fb = widget.fallbackUrl;
    if (_switched || fb == null || fb.isEmpty || fb == _url) return;
    _switched = true;
    // errorWidget 是在 build 期间构造的，不能直接 setState ⇒ 推到下一帧
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _url = fb);
    });
  }

  @override
  Widget build(BuildContext context) {
    final fallbackView = widget.errorWidget ?? const CoverPlaceholder();
    return CachedNetworkImage(
      key: ValueKey<String>(_url),
      imageUrl: _url,
      fit: widget.fit,
      memCacheWidth: widget.memCacheWidth,
      placeholder: (context, url) => fallbackView,
      errorWidget: (context, url, error) {
        _switchToFallback();
        return fallbackView;
      },
    );
  }
}
