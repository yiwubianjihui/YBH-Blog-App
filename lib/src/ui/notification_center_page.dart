import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/notification_feed.dart';
import 'post_detail_page.dart';

/// 应用内消息中心（T30）。
///
/// 为什么不只靠系统通知：通知是一次性的、会被划掉，用户想回头找「刚才那条新文章」
/// 就没处找了。这里把同一份数据源（站点 REST）在 App 内做成列表，
/// 并且**复用通知检查器的已读游标** —— 系统通知与列表红点永远一致。
class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});

  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  List<NoticeItem> _items = const [];
  bool _loading = true;
  String? _error;

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
    final items = await NotificationFeed.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
      _error = items.isEmpty ? '暂时没有新消息（也可能是网络不通）' : null;
    });
    // 进入页面即视为已读：把游标推到当前最新的一篇。
    final newest = items
        .where((e) => e.kind == 'new')
        .fold<int>(0, (max, e) => e.id > max ? e.id : max);
    await NotificationFeed.markAllSeen(newest);
  }

  Future<void> _open(NoticeItem item) async {
    final link = item.link;
    // 站内文章优先用原生阅读页（离线排版、字号控制都在那边）。
    if (item.kind == 'new' || item.kind == 'approved') {
      final summary = await NotificationFeed.loadSummary(item.id);
      if (!mounted) return;
      if (summary != null) {
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => PostDetailPage(posts: [summary], initialIndex: 0),
          ),
        );
        return;
      }
    }
    // 草稿预览等需要登录态的地址，交系统浏览器（那里有会话）。
    if (link == null || link.isEmpty) return;
    await launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('消息中心'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _items.isEmpty
                ? ListView(
                    // 必须可滚动，否则下拉刷新失效。
                    children: [
                      const SizedBox(height: 120),
                      Icon(Icons.notifications_none_rounded,
                          size: 64, color: colorScheme.outlineVariant),
                      const SizedBox(height: 12),
                      Center(
                        child: Text(
                          _error ?? '暂时没有新消息',
                          style: TextStyle(color: colorScheme.outline),
                        ),
                      ),
                    ],
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _items.length,
                    separatorBuilder: (_, _) =>
                        const Divider(height: 1, indent: 68),
                    itemBuilder: (context, i) => _NoticeTile(
                      item: _items[i],
                      onTap: () => _open(_items[i]),
                    ),
                  ),
      ),
    );
  }
}

class _NoticeTile extends StatelessWidget {
  const _NoticeTile({required this.item, required this.onTap});

  final NoticeItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, label, tint) = switch (item.kind) {
      'pending' => (Icons.hourglass_top_rounded, '待审核', colorScheme.tertiary),
      'approved' => (Icons.verified_outlined, '已发布', colorScheme.primary),
      _ => (Icons.article_outlined, '新文章', colorScheme.primary),
    };

    return ListTile(
      onTap: onTap,
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: tint.withValues(alpha: 0.12),
            child: Icon(icon, size: 20, color: tint),
          ),
          if (item.unread)
            Positioned(
              right: -1,
              top: -1,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: colorScheme.error,
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.surface, width: 1.5),
                ),
              ),
            ),
        ],
      ),
      title: Text(
        item.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14.5,
          height: 1.35,
          fontWeight: item.unread ? FontWeight.w600 : FontWeight.w400,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          [
            label,
            if (item.date != null) _ago(item.date!),
            if ((item.summary ?? '').isNotEmpty) item.summary!,
          ].join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, height: 1.5, color: colorScheme.outline),
        ),
      ),
      trailing: const Icon(Icons.chevron_right_outlined, size: 20),
    );
  }

  /// 相对时间：刚发生的事用「x 分钟前」，久远的用日期。
  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    final l = t.toLocal();
    return '${l.year}-${l.month.toString().padLeft(2, '0')}-'
        '${l.day.toString().padLeft(2, '0')}';
  }
}
