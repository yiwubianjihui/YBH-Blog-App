import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import 'lucky_demo_data.dart';
import 'lucky_models.dart';
import 'lucky_picker.dart';
import 'lucky_roster_source.dart';

/// 名单管理：查看 / 增删改、从服务器获取、粘贴导入、恢复示例名单。
///
/// 保存后 pop 出新名单，由主页写回本地存储。
class LuckyRosterPage extends StatefulWidget {
  const LuckyRosterPage({super.key, required this.roster});

  final LuckyRoster roster;

  @override
  State<LuckyRosterPage> createState() => _LuckyRosterPageState();
}

class _LuckyRosterPageState extends State<LuckyRosterPage> {
  late List<LuckyStudent> _students;
  late Map<String, String> _classes;
  String _query = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _students = [...widget.roster.students];
    _classes = {...widget.roster.classes};
  }

  LuckyRoster get _current => LuckyRoster(
        classes: _classes,
        students: _students,
        source: widget.roster.source,
        updatedAt: DateTime.now(),
      );

  List<LuckyStudent> get _visible {
    final q = _query.trim();
    if (q.isEmpty) return _students;
    return _students
        .where((s) =>
            s.name.contains(q) ||
            s.classId.contains(q) ||
            _className(s.classId).contains(q))
        .toList();
  }

  String _className(String id) =>
      _classes[id] ?? (RegExp(r'^\d+$').hasMatch(id) ? '$id班' : id);

  Future<void> _save() async {
    if (_students.isEmpty) {
      _toast('名单是空的，至少要有一个人');
      return;
    }
    Navigator.of(context).pop(_current);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ------------------------------------------------------------ 名单编辑

  Future<void> _editStudent({LuckyStudent? existing, int? index}) async {
    final result = await showDialog<LuckyStudent>(
      context: context,
      builder: (context) => _StudentEditDialog(
        existing: existing,
        classId: existing?.classId ?? _defaultClassId(),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      if (index != null) {
        _students[index] = result;
      } else {
        _students.add(result);
      }
    });
  }

  String _defaultClassId() {
    if (_students.isEmpty) return '1';
    return _students.last.classId;
  }

  Future<void> _removeAt(int index) async {
    final student = _visible[index];
    setState(() => _students.remove(student));
    _toast('已移除 ${student.name}');
  }

  // ------------------------------------------------------------ 名单来源

  Future<void> _fetchFromServer() async {
    setState(() => _busy = true);
    final roster = await LuckyRosterFetcher.fetch(AppConfig.luckyRosterUrl);
    if (!mounted) return;
    setState(() => _busy = false);
    if (roster == null || roster.isEmpty) {
      _toast('服务器上还没有名单，或暂时取不到。可先用粘贴导入。');
      return;
    }
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('获取名单'),
            content: Text(
                '服务器上共有 ${roster.count} 人。\n确定要替换当前名单吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('替换'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    setState(() {
      _students = [...roster.students];
      _classes = {...roster.classes};
    });
    _toast('已获取 ${roster.count} 人，点右上角「保存」生效');
  }

  Future<void> _importFromText() async {
    final result = await showModalBottomSheet<LuckyRoster>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => const _ImportSheet(),
    );
    if (result == null || !mounted) return;
    setState(() {
      _students = [...result.students];
      if (result.classes.isNotEmpty) _classes = {...result.classes};
    });
    _toast('导入 ${result.count} 人，点右上角「保存」生效');
  }

  Future<void> _restoreDemo() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('恢复示例名单'),
            content: const Text('会用虚构的示例名单替换当前名单，当前名单将丢失。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('恢复'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    setState(() {
      _students = [...luckyDemoRoster.students];
      _classes = {...luckyDemoRoster.classes};
    });
    _toast('已恢复示例名单，点右上角「保存」生效');
  }

  Future<void> _clearAll() async {
    if (_students.isEmpty) return;
    final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('清空名单'),
            content: Text('将移除全部 ${_students.length} 人，此操作不可撤销。'),
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
    if (!ok || !mounted) return;
    setState(() => _students = <LuckyStudent>[]);
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final visible = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('名单管理'),
        actions: [
          TextButton(onPressed: _busy ? null : _save, child: const Text('保存')),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _fetchFromServer,
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.cloud_download_outlined, size: 18),
                  label: const Text('从服务器获取'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromText,
                  icon: const Icon(Icons.content_paste_go_outlined, size: 18),
                  label: const Text('粘贴导入'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _editStudent,
                  icon: const Icon(Icons.person_add_outlined, size: 18),
                  label: const Text('手动添加'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索姓名 / 班级',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: const OutlineInputBorder(),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _query = ''),
                      ),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Row(
              children: [
                Text(
                  '共 ${_students.length} 人',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.outline,
                  ),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'demo') _restoreDemo();
                    if (v == 'clear') _clearAll();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'demo', child: Text('恢复示例名单')),
                    PopupMenuItem(value: 'clear', child: Text('清空名单')),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _students.isEmpty ? '名单是空的' : '没有匹配的人',
                      style: TextStyle(color: colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    itemCount: visible.length,
                    itemBuilder: (context, index) {
                      final s = visible[index];
                      return ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 16,
                          backgroundColor: s.gender == '女'
                              ? colorScheme.tertiaryContainer
                              : colorScheme.primaryContainer,
                          child: Icon(
                            s.gender == '女' ? Icons.female : Icons.male,
                            size: 16,
                            color: s.gender == '女'
                                ? colorScheme.onTertiaryContainer
                                : colorScheme.onPrimaryContainer,
                          ),
                        ),
                        title: Text(s.name),
                        subtitle: Text('${_className(s.classId)} · ${s.gender}'),
                        onTap: () => _editStudent(
                          existing: s,
                          index: _students.indexOf(s),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 20),
                          onPressed: () => _removeAt(index),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 单个学生的编辑对话框。
class _StudentEditDialog extends StatefulWidget {
  const _StudentEditDialog({this.existing, required this.classId});

  final LuckyStudent? existing;
  final String classId;

  @override
  State<_StudentEditDialog> createState() => _StudentEditDialogState();
}

class _StudentEditDialogState extends State<_StudentEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _classController;
  late String _gender;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.existing?.name ?? '');
    _classController = TextEditingController(
        text: widget.existing?.classId ?? widget.classId);
    _gender = widget.existing?.gender ?? '男';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _classController.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(LuckyStudent(
      name: name,
      classId: _classController.text.trim().isEmpty
          ? '1'
          : _classController.text.trim(),
      gender: _gender,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加学生' : '编辑学生'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '姓名',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _classController,
            decoration: const InputDecoration(
              labelText: '班级号',
              helperText: '数字即可，如 19',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: '男', label: Text('男')),
              ButtonSegment(value: '女', label: Text('女')),
            ],
            selected: {_gender},
            onSelectionChanged: (s) => setState(() => _gender = s.first),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}

/// 粘贴导入：把 CSV / TSV 文本贴进来解析成名单。
class _ImportSheet extends StatefulWidget {
  const _ImportSheet();

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  final TextEditingController _controller = TextEditingController();
  String? _preview;
  LuckyRoster? _parsed;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse() {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      setState(() {
        _preview = '请先粘贴内容';
        _parsed = null;
      });
      return;
    }
    final result = LuckyPicker.parseRosterText(text);
    setState(() {
      _parsed = LuckyRoster(
        students: result.students,
        source: LuckyRosterSource.imported,
      );
      _preview = result.students.isEmpty
          ? '没识别到有效数据，请检查格式'
          : '识别到 ${result.students.length} 人'
              '${result.skipped > 0 ? '，跳过 ${result.skipped} 行' : ''}';
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.isEmpty) return;
    setState(() => _controller.text = text);
    _parse();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            16, 8, 16, MediaQuery.of(context).viewInsets.bottom + 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('粘贴导入',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(
              '支持 CSV / Excel 复制出来的表格 / 制表符文本。'
              '第一行是表头（姓名、班级、性别）时会自动识别。',
              style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: '姓名,班级,性别\n张三,1,男\n李四,1,女',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              onChanged: (_) => setState(() {
                _preview = null;
                _parsed = null;
              }),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                TextButton.icon(
                  onPressed: _pasteFromClipboard,
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('从剪贴板粘贴'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _parse,
                  child: const Text('解析'),
                ),
              ],
            ),
            if (_preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  _preview!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: _parsed == null ? colorScheme.error : colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _parsed == null
                  ? null
                  : () => Navigator.of(context).pop(_parsed),
              icon: const Icon(Icons.check),
              label: const Text('导入'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
