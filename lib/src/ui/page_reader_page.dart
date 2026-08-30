import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';
import 'article_reader_view.dart';

/// 用 WordPress REST 按 slug 拉取文章 / 页面，并用原生阅读器渲染。
///
/// 用于首页固定链接（如「请给我们钱」/「加入 YBH」），体验与「文章」一致。
class PageReaderPage extends StatefulWidget {
  const PageReaderPage({
    super.key,
    required this.title,
    required this.slug,
    required this.type,
  });

  final String title;
  final String slug;

  /// 'post' 文章 / 'page' 页面。
  final String type;

  @override
  State<PageReaderPage> createState() => _PageReaderPageState();
}

class _PageReaderPageState extends State<PageReaderPage> {
  bool _loading = true;
  Object? _error;
  String _content = '';
  String _realTitle = '';

  static const Duration _timeout = Duration(seconds: 20);

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
      final endpoint = widget.type == 'page' ? 'pages' : 'posts';
      final uri = Uri.parse('${AppConfig.apiBase}/$endpoint')
          .replace(queryParameters: {
        'slug': widget.slug,
        'per_page': '1',
        '_fields': 'title,content,link',
      });
      final response = await http.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List || decoded.isEmpty) {
        throw StateError('NOT_FOUND');
      }
      final item = decoded.first as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _content =
            (item['content'] as Map?)?['rendered'] as String? ?? '';
        _realTitle = (item['title'] as Map?)?['rendered'] as String? ?? widget.title;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(_realTitle.isEmpty ? widget.title : _realTitle,
            overflow: TextOverflow.ellipsis),
        actions: [
          if (!_loading && _error == null)
            IconButton(
              tooltip: '用浏览器打开',
              onPressed: () => _openInBrowser(colorScheme),
              icon: const Icon(Icons.open_in_browser_outlined),
            ),
        ],
      ),
      body: _buildBody(colorScheme),
    );
  }

  Future<void> _openInBrowser(ColorScheme colorScheme) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('在浏览器中打开'),
        content: const Text('此页面的完整版在网站上，是否用系统浏览器打开？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('留在应用内'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('打开浏览器'),
          ),
        ],
      ),
    );
    if (ok == true) {
      messenger.hideCurrentSnackBar();
      await launchUrl(
        Uri.parse('${AppConfig.blogUrl}/${widget.slug}/'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 56, color: colorScheme.error),
              const SizedBox(height: 14),
              const Text('页面暂时加载失败', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(
                '可能是网络问题或页面不存在',
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (_content.trim().isEmpty) {
      return Center(
        child: Text('这个页面还没有内容', style: TextStyle(color: colorScheme.outline)),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ArticleWebView(content: _content, dark: dark);
  }
}
