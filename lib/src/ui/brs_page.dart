import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 广播站（brs.yibianhui.cn）**原生页**。
///
/// 为什么原生：brs 是独立静态子站，在应用内 WebView 里整页白屏
/// （DOM 为空、JS 不执行；系统浏览器里完全正常）。但它的数据是**公开 JSON**：
///
///     https://brs.yibianhui.cn/data/data.json
///     { updated_at, campuses: { main: {label, notice, playlists[]},
///                              north: {label, notice, playlists[]} } }
///     playlists[] = { id, date, period, note, songs[] }
///     songs[]     = { title, artist, by }
///
/// 只读展示用这一份就够（站点的 `api.php` 只有 ping/session/login/logout/save
/// 这类管理端动作，没有公开读取接口），所以原生页不去碰它。
class BrsPage extends StatefulWidget {
  const BrsPage({super.key});

  /// 线上数据地址（公开可读，实测 HTTP 200 / application/json / 43 KB）。
  static const String dataUrl = 'https://brs.yibianhui.cn/data/data.json';

  /// 解析站点 `data/data.json` → 规范化结构（校区 → 期 → 曲目）。
  ///
  /// **独立成公开静态方法是为了能单测**：真机上这个入口要先滚到列表底部再点，
  /// 而这台设备的输入事件会延迟/落到相邻项，UI 路径很难稳定复现；
  /// 可字段名写错（`title` / `artist` / `by` / `campuses`）恰恰只会在真机上暴露
  /// ⇒ 用单测兜住。字段名只在这里出现一次，`_load()` 也走它，避免两处各解析一遍。
  static List<Map<String, dynamic>> parseCampuses(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return const [];
    }
    if (decoded is! Map<String, dynamic>) return const [];
    final raw = decoded['campuses'];
    if (raw is! Map<String, dynamic>) return const [];

    String s(Object? v) => ((v as String?) ?? '').trim();
    final out = <Map<String, dynamic>>[];
    for (final entry in raw.entries) {
      final v = entry.value;
      if (v is! Map<String, dynamic>) continue;
      final label = s(v['label']);
      out.add({
        'key': entry.key,
        'label': label.isEmpty ? entry.key : label,
        'notice': s(v['notice']),
        'playlists': <Map<String, dynamic>>[
          for (final p in (v['playlists'] as List? ?? const []))
            if (p is Map<String, dynamic>)
              {
                'date': s(p['date']),
                'note': s(p['note']),
                'songs': <Map<String, String>>[
                  for (final song in (p['songs'] as List? ?? const []))
                    if (song is Map<String, dynamic>)
                      {
                        'title': s(song['title']),
                        'artist': s(song['artist']),
                        'by': s(song['by']),
                      },
                ],
              },
        ],
      });
    }
    return out;
  }

  @override
  State<BrsPage> createState() => _BrsPageState();
}

/// 一个校区。
class _Campus {
  _Campus({required this.key, required this.label, required this.notice, required this.playlists});

  final String key;
  final String label;
  final String notice;
  final List<_Playlist> playlists;

  int get songCount => playlists.fold(0, (a, p) => a + p.songs.length);

  /// 从 [BrsPage.parseCampuses] 的规范化结果构造（字段名解析只在那一个地方）。
  static _Campus fromMap(Map<String, dynamic> m) => _Campus(
        key: (m['key'] as String?) ?? '',
        label: (m['label'] as String?) ?? '',
        notice: (m['notice'] as String?) ?? '',
        playlists: [
          for (final p in (m['playlists'] as List? ?? const []))
            if (p is Map<String, dynamic>) _Playlist.fromMap(p),
        ],
      );
}

/// 一期歌单。
class _Playlist {
  _Playlist({required this.date, required this.note, required this.songs});

  final String date;
  final String note;
  final List<_Song> songs;

  static _Playlist fromMap(Map<String, dynamic> m) => _Playlist(
        date: (m['date'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        songs: [
          for (final s in (m['songs'] as List? ?? const []))
            if (s is Map<String, dynamic>) _Song.fromMap(s),
        ],
      );
}

/// 一首歌。
class _Song {
  _Song({required this.title, required this.artist, required this.by});

  final String title;
  final String artist;
  final String by;

  static _Song fromMap(Map<String, dynamic> m) => _Song(
        title: (m['title'] as String?) ?? '',
        artist: (m['artist'] as String?) ?? '',
        by: (m['by'] as String?) ?? '',
      );
}

class _BrsPageState extends State<BrsPage> {
  bool _loading = true;
  Object? _error;
  String _updatedAt = '';
  List<_Campus> _campuses = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    try {
      final resp = await http
          .get(Uri.parse(BrsPage.dataUrl))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
      final text = utf8.decode(resp.bodyBytes);
      // 解析走 BrsPage.parseCampuses（字段名只有那一处，单测覆盖它）
      final campuses = [
        for (final c in BrsPage.parseCampuses(text)) _Campus.fromMap(c),
      ];
      final updated = (jsonDecode(text) as Map<String, dynamic>)['updated_at'];
      if (!mounted) return;
      setState(() {
        _campuses = campuses;
        _updatedAt = ((updated as String?) ?? '').trim();
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

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _campuses.isEmpty ? 1 : _campuses.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('广播站'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: _campuses.isEmpty
              ? null
              : TabBar(tabs: [for (final c in _campuses) Tab(text: c.label)]),
        ),
        body: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              const Text('歌单加载失败', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('请检查网络后重试。', style: TextStyle(color: colorScheme.onSurfaceVariant)),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }
    if (_campuses.isEmpty) {
      return Center(
        child: Text('暂时没有歌单', style: TextStyle(color: colorScheme.onSurfaceVariant)),
      );
    }
    return TabBarView(
      children: [for (final c in _campuses) _campusView(context, c)],
    );
  }

  Widget _campusView(BuildContext context, _Campus c) {
    final colorScheme = Theme.of(context).colorScheme;
    // 歌单按日期倒序，最新一期在最上面。
    final lists = [...c.playlists]
      ..sort((a, b) => b.date.compareTo(a.date));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        children: [
          if (c.notice.isNotEmpty)
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                c.notice,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          Row(
            children: [
              Icon(Icons.queue_music, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text('${c.playlists.length} 期 · ${c.songCount} 首',
                  style: TextStyle(fontSize: 12.5, color: colorScheme.onSurfaceVariant)),
              const Spacer(),
              if (_updatedAt.isNotEmpty)
                Text('更新于 $_updatedAt',
                    style: TextStyle(fontSize: 11.5, color: colorScheme.outline)),
            ],
          ),
          const SizedBox(height: 8),
          for (final p in lists) _playlistCard(context, p),
        ],
      ),
    );
  }

  Widget _playlistCard(BuildContext context, _Playlist p) {
    final colorScheme = Theme.of(context).colorScheme;
    final title = p.date.isEmpty ? '（未标日期）' : p.date;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
        leading: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(11),
          ),
          child: Icon(Icons.radio_outlined, size: 20, color: colorScheme.onPrimaryContainer),
        ),
        title: Text(title,
            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700)),
        subtitle: Text(
          p.note.isNotEmpty ? '${p.songs.length} 首 · ${p.note}' : '${p.songs.length} 首',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: colorScheme.outline),
        ),
        children: [
          for (var i = 0; i < p.songs.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    child: Text('${i + 1}',
                        style: TextStyle(fontSize: 12.5, color: colorScheme.outline)),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.songs[i].title,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        if (p.songs[i].artist.isNotEmpty || p.songs[i].by.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              [
                                if (p.songs[i].artist.isNotEmpty) p.songs[i].artist,
                                if (p.songs[i].by.isNotEmpty) '点歌：${p.songs[i].by}',
                              ].join(' · '),
                              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
