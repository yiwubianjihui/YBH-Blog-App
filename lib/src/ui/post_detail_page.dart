import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:convert' show HtmlEscape;

import '../app_config.dart';
import '../data/blog_api.dart';
import 'article_reader_view.dart';

/// 文章详情页：正文优先用 WebView 阅读器（[ArticleWebView]，Android/iOS/macOS），
/// 完整渲染站点样式、自适应图片、Ruby 振假名、代码块语言标签与自定义字体；
/// 其余平台（Web/桌面）退回 flutter_html 渲染。
///
/// 支持在传入的 [posts] 列表内翻页（上一篇 / 下一篇）。
class PostDetailPage extends StatefulWidget {
  const PostDetailPage({
    super.key,
    required this.posts,
    required this.initialIndex,
  });

  final List<PostSummary> posts;
  final int initialIndex;

  @override
  State<PostDetailPage> createState() => _PostDetailPageState();
}

class _PostDetailPageState extends State<PostDetailPage> {
  late int _index = widget.initialIndex;

  /// 阅读器滚动位置（CSS px）。用来让 AppBar 的标题**滚过正文标题后才出现**。
  final ValueNotifier<double> _scrollY = ValueNotifier<double>(0);

  @override
  void dispose() {
    _scrollY.dispose();
    super.dispose();
  }

  PostSummary get _post => widget.posts[_index];

  bool get _hasPrev => _index > 0;
  bool get _hasNext => _index < widget.posts.length - 1;

  /// 文章头部 HTML（标题 / 时间 / 分类）。
  ///
  /// ⚠️ 放进**正文里面**，而不是 Flutter 侧固定一块：
  /// 固定头部会一直占着屏幕、把正文挤成一条缝；而且 AppBar 里再放一份标题
  /// 就成了「一页两个标题」（真机反馈的两个问题都出在这）。
  /// 放进正文后标题随正文一起滚走，AppBar 只在滚过它之后才补标题。
  String _headerHtml(PostSummary post) {
    const esc = HtmlEscape();
    final terms = post.terms.take(4).join(' · ');
    final date = _formatDate(post.date);
    return '<header class="ybh-article-head">'
        '<div class="ybh-title">${esc.convert(post.title)}</div>'
        '<div class="ybh-article-meta">'
        '${date.isEmpty ? '' : '<span>${esc.convert(date)}</span>'}'
        '${terms.isEmpty ? '' : '<span class="ybh-cat">${esc.convert(terms)}</span>'}'
        '</div></header>';
  }

  /// 是否用 WebView 阅读器（移动端 + macOS 可用；Web/桌面退回 flutter_html）。
  static bool get _useWebView =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS);

  static String _formatDate(DateTime? date) {
    if (date == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}';
  }

  void _goPrev() {
    if (_hasPrev) setState(() => _index--);
    _scrollY.value = 0;
  }

  void _goNext() {
    if (_hasNext) setState(() => _index++);
    _scrollY.value = 0;
  }

  Future<void> _share() async {
    await SharePlus.instance.share(
      ShareParams(
        text: '《${_post.title}》—— 来自${AppConfig.appName}',
        uri: Uri.parse(_post.link),
      ),
    );
  }

  Future<void> _openInBrowser() async {
    await launchUrl(Uri.parse(_post.link), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final post = _post;

    return Scaffold(
      appBar: AppBar(
        // 「一页两个标题」的修法：正文里已经有标题了，AppBar 这份**默认隐藏**，
        // 只在滚过正文标题之后淡入 —— 既不会一页两标题，也不会一直占着屏幕。
        title: _useWebView
            ? ValueListenableBuilder<double>(
                valueListenable: _scrollY,
                builder: (context, y, child) => AnimatedOpacity(
                  opacity: y > 48 ? 1 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: child,
                ),
                child: Text(
                  post.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600),
                ),
              )
            : Text(
                post.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
        actions: [
          IconButton(
            tooltip: '分享',
            onPressed: _share,
            icon: const Icon(Icons.share_outlined),
          ),
          IconButton(
            tooltip: '用浏览器打开',
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_browser_outlined),
          ),
        ],
      ),
      body: _useWebView
          // 标题 / 时间 / 分类都塞进正文里，随正文一起滚走。
          ? ArticleWebView(
              content: post.content,
              dark: dark,
              headerHtml: _headerHtml(post),
              scrollY: _scrollY,
            )
          // 非 WebView 平台（Web/桌面）保持原来的固定头部。
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        post.title,
                        style: const TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                            height: 1.4),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(Icons.schedule_outlined,
                              size: 14, color: colorScheme.outline),
                          const SizedBox(width: 4),
                          Text(
                            _formatDate(post.date),
                            style: TextStyle(
                                fontSize: 12.5, color: colorScheme.outline),
                          ),
                          if (post.terms.isNotEmpty) ...[
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                post.terms.take(4).join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: colorScheme.primary),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Divider(height: 1),
                    ],
                  ),
                ),
                Expanded(child: _HtmlBody(content: post.content)),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              // 上一篇。
              IconButton.outlined(
                tooltip: '上一篇',
                onPressed: _hasPrev ? _goPrev : null,
                icon: const Icon(Icons.chevron_left),
              ),
              const SizedBox(width: 8),
              // 链接 + 网页查看。
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      post.link.replaceFirst('https://', ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 11, color: colorScheme.outline),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${_index + 1} / ${widget.posts.length}',
                          style: TextStyle(
                              fontSize: 11.5, color: colorScheme.outline),
                        ),
                        TextButton.icon(
                          onPressed: _openInBrowser,
                          icon: const Icon(Icons.open_in_new, size: 14),
                          label: const Text('网页查看',
                              style: TextStyle(fontSize: 12.5)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // 下一篇。
              IconButton.filled(
                tooltip: '下一篇',
                onPressed: _hasNext ? _goNext : null,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// flutter_html 兜底正文渲染（Web / 桌面等无法使用 WebView 的平台）。
class _HtmlBody extends StatelessWidget {
  const _HtmlBody({required this.content});

  final String content;

  Future<void> _openLink(String? url) async {
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bodyColor = Theme.of(context).textTheme.bodyLarge?.color;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      child: SelectionArea(
        child: Html(
          data: content,
          onLinkTap: (url, attributes, element) => _openLink(url),
          extensions: [
            MediaExtension(onOpen: (url) => _openLink(url)),
          ],
          style: {
            'body': Style(
              margin: Margins.zero,
              padding: HtmlPaddings.zero,
              fontSize: FontSize(16),
              lineHeight: const LineHeight(1.8),
              color: bodyColor,
            ),
            'p': Style(margin: Margins.only(bottom: 14)),
            'img': Style(
              display: Display.block,
              width: Width(100, Unit.percent),
              margin: Margins.symmetric(vertical: 12),
              alignment: Alignment.center,
            ),
            'figure': Style(margin: Margins.symmetric(vertical: 12)),
            'figcaption': Style(
              fontSize: FontSize(13),
              color: colorScheme.outline,
              textAlign: TextAlign.center,
              margin: Margins.only(top: 6),
            ),
            'a': Style(color: colorScheme.primary),
            'ul': Style(margin: Margins.only(bottom: 14, left: 18)),
            'ol': Style(margin: Margins.only(bottom: 14, left: 18)),
            'li': Style(margin: Margins.only(bottom: 4)),
            'table': Style(
              width: Width(100, Unit.percent),
              margin: Margins.symmetric(vertical: 12),
            ),
            'th': Style(
              padding: HtmlPaddings.all(6),
              backgroundColor: colorScheme.surfaceContainerHighest,
            ),
            'td': Style(padding: HtmlPaddings.all(6)),
            'hr': Style(margin: Margins.symmetric(vertical: 14)),
            'pre': Style(
              backgroundColor: colorScheme.surfaceContainerHighest,
              padding: HtmlPaddings.all(12),
              margin: Margins.symmetric(vertical: 12),
              whiteSpace: WhiteSpace.pre,
            ),
            'code': Style(
              backgroundColor: colorScheme.surfaceContainerHighest,
              fontFamily: 'monospace',
            ),
            'blockquote': Style(
              margin: Margins.symmetric(vertical: 12),
              padding: HtmlPaddings.only(left: 14),
              border: Border(
                left: BorderSide(color: colorScheme.primary, width: 3),
              ),
              color: colorScheme.onSurfaceVariant,
            ),
            'h1': Style(fontSize: FontSize(20), fontWeight: FontWeight.w700),
            'h2': Style(fontSize: FontSize(19), fontWeight: FontWeight.w700),
            'h3': Style(fontSize: FontSize(18), fontWeight: FontWeight.w700),
            'h4': Style(fontSize: FontSize(17), fontWeight: FontWeight.w600),
          },
        ),
      ),
    );
  }
}

/// 把文章正文里的 <iframe>/<video>/<audio> 渲染成可点击的卡片，
/// 点击后在系统浏览器打开媒体（flutter_html 本身不渲染 iframe）。
class MediaExtension extends HtmlExtension {
  const MediaExtension({this.onOpen});

  final void Function(String)? onOpen;

  @override
  Set<String> get supportedTags => {'iframe', 'video', 'audio', 'object'};

  @override
  InlineSpan build(ExtensionContext context) {
    final tag = context.elementName;
    final src = context.attributes['src'];
    if (src == null || src.isEmpty) return const TextSpan(text: '');
    final label = tag == 'audio'
        ? '音频'
        : (tag == 'video' ? '视频' : '媒体 / 视频');
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: _MediaCard(label: label, url: src, onOpen: onOpen),
    );
  }
}

class _MediaCard extends StatelessWidget {
  const _MediaCard({
    required this.label,
    required this.url,
    required this.onOpen,
  });

  final String label;
  final String url;
  final void Function(String)? onOpen;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      uri = null;
    }
    final host = uri?.host ?? url;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          onOpen?.call(url);
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Icon(Icons.play_circle_outline, color: colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$label（点击在浏览器打开）',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(
                      host,
                      style: TextStyle(
                        fontSize: 12,
                        color: colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.open_in_browser_outlined),
            ],
          ),
        ),
      ),
    );
  }
}