import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'lucky_models.dart';
import 'lucky_store.dart';

/// 抽选记录：时间、班级、类型与抽中名单，支持复制与清空。
class LuckyHistoryPage extends StatefulWidget {
  const LuckyHistoryPage({super.key});

  @override
  State<LuckyHistoryPage> createState() => _LuckyHistoryPageState();
}

class _LuckyHistoryPageState extends State<LuckyHistoryPage> {
  List<LuckyPickRecord> _records = const <LuckyPickRecord>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final records = await LuckyStore.loadHistory();
    if (!mounted) return;
    setState(() {
      _records = records;
      _loading = false;
    });
  }

  Future<void> _clear() async {
    if (_records.isEmpty) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('清空记录'),
            content: Text('将删除全部 ${_records.length} 条抽选记录，不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('清空'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    await LuckyStore.clearHistory();
    await _load();
    if (!mounted) return;
    _toast('记录已清空');
  }

  Future<void> _copy(LuckyPickRecord record) async {
    await Clipboard.setData(ClipboardData(text: record.names.join('、')));
    if (!mounted) return;
    _toast('已复制抽中名单');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 累计抽取人次与去重人数。
  ({int draws, int unique}) get _summary {
    final names = <String>{};
    var draws = 0;
    for (final r in _records) {
      draws += r.names.length;
      names.addAll(r.names);
    }
    return (draws: draws, unique: names.length);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(
        title: const Text('抽选记录'),
        actions: [
          if (_records.isNotEmpty)
            IconButton(
              tooltip: '清空记录',
              onPressed: _clear,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _records.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history_toggle_off_outlined,
                          size: 56, color: colorScheme.outline),
                      const SizedBox(height: 10),
                      Text('还没有抽选记录',
                          style: TextStyle(color: colorScheme.outline)),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          _SummaryChip(
                            icon: Icons.touch_app_outlined,
                            label: '累计 ${summary.draws} 人次',
                          ),
                          const SizedBox(width: 8),
                          _SummaryChip(
                            icon: Icons.people_outline,
                            label: '覆盖 ${summary.unique} 人',
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        itemCount: _records.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final r = _records[index];
                          return ListTile(
                            title: Text(r.names.join('、')),
                            subtitle: Text(
                                '${_formatTime(r.at)} · ${_classLabel(r.classId)} · ${_modeLabel(r.mode)}'),
                            trailing: IconButton(
                              icon: const Icon(Icons.copy_outlined, size: 18),
                              onPressed: () => _copy(r),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  static String _classLabel(String classId) =>
      classId.isEmpty ? '全部班级' : '$classId班';

  static String _modeLabel(String mode) =>
      mode == 'multi' ? '连抽' : '抽一人';

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

class _SummaryChip extends StatelessWidget {
  const _SummaryChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onPrimaryContainer),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
