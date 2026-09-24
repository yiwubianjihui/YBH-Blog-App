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

  static _Campus fromJson(String key, Map<String, dynamic> j) => _Campus(
        key: key,
        label: (j['label'] as String?)?.trim().isNotEmpty == true
            ? (j['label'] as String).trim()
            : key,
        notice: ((j['notice'] as String?) ?? '').trim(),
        playlists: (j['playlists'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(_Playlist.fromJson)
                .toList() ??
            const <_Playlist>[],
      );
}

/// 一期歌单。
class _Playlist {
  _Playlist({required this.date, required this.note, required this.songs});

  final String date;
  final String note;
  final List<_Song> songs;

  static _Playlist fromJson(Map<String, dynamic> j) => _Playlist(
        date: ((j['date'] as String?) ?? '').trim(),
        note: ((j['note'] as String?) ?? '').trim(),
        songs: (j['songs'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(_Song.fromJson)
                .toList() ??
            const <_Song>[],
      );
}

/// 一首歌。
class _Song {
  _Song({required this.title, required this.artist, required this.by});

  final String title;
  final String artist;
  final String by;

  static _Song fromJson(Map<String, dynamic> j) => _Song(
        title: ((j['title'] as String?) ?? '').trim(),
        artist: ((j['artist'] as String?) ?? '').trim(),
        by: ((j['by'] as String?) ?? '').trim(),
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
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw StateError('返回不是对象');
      final campuses = <_Campus>[];
      final raw = decoded['campuses'];
      if (raw is Map<String, dynamic>) {
        for (final e in raw.entries) {
          final v = e.value;
          if (v is Map<String, dynamic>) campuses.add(_Campus.fromJson(e.key, v));
        }
      }
      if (!mounted) return;
      setState(() {
        _campuses = campuses;
        _updatedAt = ((decoded['updated_at'] as String?) ?? '').trim();
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
