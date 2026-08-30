import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'lucky_demo_data.dart';
import 'lucky_history_page.dart';
import 'lucky_models.dart';
import 'lucky_picker.dart';
import 'lucky_roster_page.dart';
import 'lucky_store.dart';
import 'lucky_tts.dart';

/// 幸运摇人器主页面（Flutter 原生实现）。
///
/// 功能对齐桌面版：班级 / 性别筛选、不重复模式、抽一人 / 连抽多人、
/// 屏蔽名单、重置池、语音播报、抽选记录、名单管理。
///
/// 名单默认使用内置示例数据（虚构姓名），真实名单可从服务器获取或导入，
/// 只存在本机，不会进入版本库。
class LuckyPage extends StatefulWidget {
  const LuckyPage({super.key});

  @override
  State<LuckyPage> createState() => _LuckyPageState();
}

class _LuckyPageState extends State<LuckyPage> {
  LuckyRoster _roster = luckyDemoRoster;
  LuckySettings _settings = const LuckySettings();
  Set<String> _used = <String>{};
  Set<String> _blocked = <String>{};

  /// 当前展示的结果（滚动动画期间会不断刷新）。
  List<LuckyStudent> _result = const <LuckyStudent>[];

  /// 滚动动画期间临时显示的名字。
  List<String> _rolling = const <String>[];
  Timer? _rollTimer;
  bool _picking = false;

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    LuckyTts.instance.init();
  }

  @override
  void dispose() {
    _rollTimer?.cancel();
    LuckyTts.instance.stop();
    super.dispose();
  }

  Future<void> _load() async {
    final roster = await LuckyStore.loadRoster();
    final settings = await LuckyStore.loadSettings();
    final used = await LuckyStore.loadUsed();
    if (!mounted) return;
    setState(() {
      _roster = roster;
      _settings = settings;
      _used = used;
      _loading = false;
    });
  }

  // ------------------------------------------------------------ 派生状态

  List<LuckyStudent> get _candidates => LuckyPicker.candidates(
        roster: _roster,
        classId: _settings.classId.isEmpty ? null : _settings.classId,
        gender: _settings.gender,
        blocked: _blocked,
      );

  ({int total, int remaining}) get _stats => LuckyPicker.stats(
        candidates: _candidates,
        used: _used,
        noRepeat: _settings.noRepeat,
      );

  // ------------------------------------------------------------ 抽取逻辑

  Future<void> _pick({required int count}) async {
    if (_picking) return;
    final candidates = _candidates;
    if (candidates.isEmpty) {
      _toast('当前条件下没有可抽的人，换个班级或清空屏蔽名单试试');
      return;
    }

    setState(() => _picking = true);
    final picked = LuckyPicker.pick(
      candidates: candidates,
      used: _used,
      noRepeat: _settings.noRepeat,
      count: count,
    );

    // 滚动动画：快速闪动候选名字，再定格到结果。
    await _roll(candidates, picked, count);

    final used = LuckyPicker.markUsed(
      used: _used,
      picked: picked,
      noRepeat: _settings.noRepeat,
    );
    if (!mounted) return;
    setState(() {
      _result = picked;
      _used = used;
      _picking = false;
    });
    await LuckyStore.saveUsed(used);

    await LuckyStore.appendHistory(LuckyPickRecord(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      at: DateTime.now(),
      classId: _settings.classId,
      mode: count > 1 ? 'multi' : 'single',
      names: picked.map((s) => s.name).toList(),
    ));

    if (_settings.ttsEnabled) {
      await LuckyTts.instance.speakResult(picked.map((s) => s.name).toList());
    }
  }

  /// 名字滚动动画：随机闪动 [ticks] 次，最后定格到 [picked]。
  Future<void> _roll(
      List<LuckyStudent> candidates, List<LuckyStudent> picked, int count) async {
    final rng = Random();
    const ticks = 14;
    const step = Duration(milliseconds: 55);
    for (var i = 0; i < ticks; i++) {
      if (!mounted) return;
      final names = <String>[
        for (var j = 0; j < count; j++) candidates[rng.nextInt(candidates.length)].name,
      ];
      setState(() => _rolling = names);
      await Future<void>.delayed(step);
    }
    if (!mounted) return;
    setState(() => _rolling = const <String>[]);
  }

  Future<void> _resetPool() async {
    await LuckyStore.clearUsed();
    if (!mounted) return;
    setState(() => _used = <String>{});
    _toast('已重置，所有人重新参与');
  }

  Future<void> _replay() async {
    if (_result.isEmpty) return;
    await LuckyTts.instance.speakResult(_result.map((s) => s.name).toList());
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------ 设置变更

  Future<void> _updateSettings(LuckySettings next) async {
    setState(() => _settings = next);
    await LuckyStore.saveSettings(next);
  }

  Future<void> _onRosterChanged(LuckyRoster roster) async {
    final ok = await LuckyStore.saveRoster(roster);
    if (!ok) {
      _toast('保存失败，请稍后重试');
      return;
    }
    if (!mounted) return;
    setState(() {
      _roster = roster;
      _used = <String>{};
      _result = const <LuckyStudent>[];
    });
    await LuckyStore.clearUsed();
    if (!mounted) return;
    _toast('名单已更新：共 ${roster.count} 人');
  }

  Future<void> _openRoster() async {
    final result = await Navigator.of(context).push<LuckyRoster>(
      MaterialPageRoute<LuckyRoster>(
        builder: (_) => LuckyRosterPage(roster: _roster),
      ),
    );
    if (result != null && mounted) await _onRosterChanged(result);
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const LuckyHistoryPage()),
    );
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('幸运摇人器'),
        actions: [
          IconButton(
            tooltip: '名单管理',
            onPressed: _openRoster,
            icon: const Icon(Icons.people_outline),
          ),
          IconButton(
            tooltip: '抽选记录',
            onPressed: _openHistory,
            icon: const Icon(Icons.history_outlined),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildClassBar(colorScheme),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
              children: [
                _buildFilters(colorScheme),
                const SizedBox(height: 14),
                _buildStage(colorScheme),
                const SizedBox(height: 16),
                _buildActions(colorScheme),
                const SizedBox(height: 14),
                _buildBlockList(colorScheme),
                const SizedBox(height: 12),
                _buildRosterHint(colorScheme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部班级横向选择条。
  Widget _buildClassBar(ColorScheme colorScheme) {
    final ids = _roster.classIds;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('全部班级'),
              selected: _settings.classId.isEmpty,
              onSelected: (_) =>
                  _updateSettings(_settings.copyWith(classId: '')),
            ),
          ),
          for (final id in ids)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(_roster.classNameOf(id)),
                selected: _settings.classId == id,
                onSelected: (_) =>
                    _updateSettings(_settings.copyWith(classId: id)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilters(ColorScheme colorScheme) {
    return Row(
      children: [
        Expanded(
          child: SegmentedButton<LuckyGenderFilter>(
            segments: const [
              ButtonSegment(
                  value: LuckyGenderFilter.all, label: Text('都抽')),
              ButtonSegment(
                  value: LuckyGenderFilter.male, label: Text('男生')),
              ButtonSegment(
                  value: LuckyGenderFilter.female, label: Text('女生')),
            ],
            selected: {_settings.gender},
            onSelectionChanged: (s) =>
                _updateSettings(_settings.copyWith(gender: s.first)),
          ),
        ),
      ],
    );
  }

  /// 结果舞台：滚动动画 + 定格结果 + 统计。
  Widget _buildStage(ColorScheme colorScheme) {
    final stats = _stats;
    final rolling = _rolling.isNotEmpty;
    final names = rolling ? _rolling : _result.map((s) => s.name).toList();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 230),
      padding: const EdgeInsets.fromLTRB(18, 22, 18, 18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.55),
            colorScheme.surfaceContainerHighest,
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (names.isEmpty) ...[
            Icon(Icons.casino_outlined,
                size: 56, color: colorScheme.primary.withValues(alpha: 0.55)),
            const SizedBox(height: 12),
            Text(
              _candidates.isEmpty ? '没有可抽的人' : '点下面的按钮开始',
              style: TextStyle(
                fontSize: 14,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ] else ...[
            for (final name in names.take(8))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 120),
                  style: TextStyle(
                    fontSize: names.length > 3 ? 26 : 40,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                    color: rolling
                        ? colorScheme.onSurfaceVariant
                        : colorScheme.primary,
                  ),
                  child: Text(name, textAlign: TextAlign.center),
                ),
              ),
          ],
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            children: [
              _StatChip(
                icon: Icons.groups_outlined,
                label: '候选 ${stats.total} 人',
              ),
              if (_settings.noRepeat)
                _StatChip(
                  icon: Icons.undo_outlined,
                  label: '剩余 ${stats.remaining} 人',
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildActions(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: _picking ? null : () => _pick(count: 1),
          icon: const Icon(Icons.casino_outlined),
          label: const Text('抽一人', style: TextStyle(fontSize: 16)),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _picking ? null : () => _pick(count: _settings.multiCount),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: Text('连抽 ${_settings.multiCount} 人'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _result.isEmpty ? null : _replay,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(56, 48),
              ),
              child: const Icon(Icons.volume_up_outlined),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SwitchListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('不重复'),
                value: _settings.noRepeat,
                onChanged: (v) => _updateSettings(_settings.copyWith(noRepeat: v)),
              ),
            ),
            TextButton.icon(
              onPressed: _used.isEmpty ? null : _resetPool,
              icon: const Icon(Icons.restart_alt_outlined, size: 18),
              label: const Text('重置池'),
            ),
          ],
        ),
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('语音播报'),
          subtitle: LuckyTts.instance.available
              ? null
              : const Text('系统没有可用的语音引擎'),
          value: _settings.ttsEnabled && LuckyTts.instance.available,
          onChanged: LuckyTts.instance.available
              ? (v) => _updateSettings(_settings.copyWith(ttsEnabled: v))
              : null,
        ),
      ],
    );
  }

  /// 屏蔽名单：输入姓名可临时屏蔽，不改动名单数据。
  Widget _buildBlockList(ColorScheme colorScheme) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.block_outlined, size: 16, color: colorScheme.primary),
                const SizedBox(width: 6),
                const Text('屏蔽名单',
                    style:
                        TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
                const Spacer(),
                if (_blocked.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _blocked = <String>{}),
                    child: const Text('清空'),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (_blocked.isEmpty)
              Text(
                '没人在屏蔽名单里。点下方按钮可临时排除某些人（不会改动名单数据）。',
                style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final name in _blocked)
                    Chip(
                      label: Text(name),
                      onDeleted: () =>
                          setState(() => _blocked = {..._blocked}..remove(name)),
                    ),
                ],
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _showBlockPicker,
              icon: const Icon(Icons.person_off_outlined, size: 18),
              label: const Text('选择要屏蔽的人'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(42),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showBlockPicker() async {
    final pool = LuckyPicker.candidates(
      roster: _roster,
      classId: _settings.classId.isEmpty ? null : _settings.classId,
      gender: _settings.gender,
    );
    if (pool.isEmpty) {
      _toast('当前条件下没有可屏蔽的人');
      return;
    }
    final selected = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _BlockPickerSheet(
        names: pool.map((s) => s.name).toList(),
        initial: _blocked,
      ),
    );
    if (selected != null && mounted) {
      setState(() => _blocked = selected);
    }
  }

  /// 名单来源提示：示例名单时提醒用户换成真实名单。
  Widget _buildRosterHint(ColorScheme colorScheme) {
    final isDemo = _roster.source == LuckyRosterSource.builtIn;
    if (!isDemo) {
      return Row(
        children: [
          Icon(Icons.check_circle_outline,
              size: 15, color: colorScheme.outline),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '当前名单：${_roster.count} 人（${_sourceLabel(_roster.source)}）',
              style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
            ),
          ),
        ],
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: colorScheme.onTertiaryContainer),
              const SizedBox(width: 6),
              Text(
                '当前是示例名单',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onTertiaryContainer,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '为了不把真实姓名放进公开仓库，内置名单用的是虚构名字。'
            '点右上角「名单管理」可从服务器获取真实名单，或导入 CSV。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: colorScheme.onTertiaryContainer,
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: _openRoster,
              child: const Text('去设置'),
            ),
          ),
        ],
      ),
    );
  }

  static String _sourceLabel(LuckyRosterSource source) => switch (source) {
        LuckyRosterSource.builtIn => '示例',
        LuckyRosterSource.imported => '已导入',
        LuckyRosterSource.remote => '服务器',
      };
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

/// 底部弹出的屏蔽名单选择器。
class _BlockPickerSheet extends StatefulWidget {
  const _BlockPickerSheet({required this.names, required this.initial});

  final List<String> names;
  final Set<String> initial;

  @override
  State<_BlockPickerSheet> createState() => _BlockPickerSheetState();
}

class _BlockPickerSheetState extends State<_BlockPickerSheet> {
  late Set<String> _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _selected = {...widget.initial};
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();
    final names = widget.names
        .where((n) => query.isEmpty || n.contains(query))
        .toList();
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                autofocus: false,
                decoration: const InputDecoration(
                  hintText: '搜索姓名',
                  prefixIcon: Icon(Icons.search),
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: names.length,
                itemBuilder: (context, index) {
                  final name = names[index];
                  final checked = _selected.contains(name);
                  return CheckboxListTile(
                    dense: true,
                    title: Text(name),
                    value: checked,
                    onChanged: (v) => setState(() {
                      if (v == true) {
                        _selected.add(name);
                      } else {
                        _selected.remove(name);
                      }
                    }),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(_selected),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text('确定（已选 ${_selected.length} 人）'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
