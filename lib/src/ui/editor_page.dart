import 'package:flutter/material.dart';

import '../data/blog_api.dart';
import '../data/embedded_fonts.dart';
import '../data/media_picker.dart';
import '../data/web_style.dart';
import '../data/wp_auth.dart';
import 'rich_text_editor.dart';

/// 写文章页：标题 + **富文本正文** + 分类 + 状态（发布 / 提交审核 / 草稿）。
///
/// 正文不再是纯文本输入框，而是一个 `contenteditable` 的 WebView
/// （见 [RichTextEditor]）：编辑区用的是**站点自己的正文样式**
/// （字体、字号、段距、引用、代码块都与网页端一致），因此
/// 「编辑器里长什么样，发布后就是什么样」。
///
/// 提交时以 **HTML** 送交 REST API（[WpAuth.publishPost] 的 `contentIsHtml`），
/// 与网页端经典编辑器写进数据库的内容形态相同 —— 前台 `wpautop` /
/// `.entry-content` 规则照常生效，不会出现"App 发的文章排版不一样"。
///
/// **投稿者适配**：WordPress 的「投稿者（contributor）」没有 `publish_posts`
/// 能力，直接发布会被服务端以 403 拒绝。本页会在打开时读取当前账号的角色与
/// 能力，无直接发布权限时：
///   - 状态选项从「直接发布」换成「提交审核」；
///   - 顶部提示当前角色与审核说明；
///   - 提交后明确告诉用户「已提交，待审核」。
class EditorPage extends StatefulWidget {
  const EditorPage({super.key});

  @override
  State<EditorPage> createState() => _EditorPageState();
}

class _EditorPageState extends State<EditorPage> {
  final TextEditingController _titleController = TextEditingController();
  final RichTextEditorController _editor = RichTextEditorController();

  List<BlogCategory> _categories = const [];
  int? _categoryId;
  String _status = 'publish';
  bool _submitting = false;
  bool _uploading = false;
  String? _error;

  /// 当前登录用户（含角色与能力）；为 null 表示还在读取。
  WpUser? _me;
  bool _loadingCapabilities = false;

  /// 有未保存内容（用于返回时提醒）。
  bool _dirty = false;
  bool _submitted = false;

  /// 是否有直接发布权限（读不到能力时乐观视为 true）。
  bool get _canPublish => _me?.canPublish ?? true;

  @override
  void initState() {
    super.initState();
    _status = 'publish';
    _titleController.addListener(_markDirty);
    _loadCategories();
    _loadCapabilities();
    // 站点样式与打包字体先备好，编辑区一打开就是网页同款观感。
    WebStyle.instance.prepare();
    EmbeddedFonts.instance.prepare();
  }

  @override
  void dispose() {
    _titleController.removeListener(_markDirty);
    _titleController.dispose();
    _editor.dispose();
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  Future<void> _loadCategories() async {
    try {
      final categories = await BlogApi.fetchCategories();
      if (!mounted) return;
      setState(() => _categories = categories);
    } catch (_) {
      // 忽略：分类为可选项。
    }
  }

  /// 读取当前账号的角色 / 能力，决定能否「直接发布」。
  Future<void> _loadCapabilities() async {
    var me = wpAuth.user;
    if (me == null || !me.capabilitiesKnown) {
      if (mounted) setState(() => _loadingCapabilities = true);
      me = await wpAuth.refreshMe() ?? me;
    }
    if (!mounted) return;
    setState(() {
      _me = me;
      _loadingCapabilities = false;
      // 没有直接发布权限时，默认改为「提交审核」。
      if (!_canPublish && _status == 'publish') _status = 'pending';
    });
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final title = _titleController.text.trim();
    final html = (await _editor.getHtml()).trim();
    final plain = (await _editor.getPlainText()).trim();
    if (!mounted) return;
    if (title.isEmpty) {
      setState(() => _error = '请填写标题');
      return;
    }
    if (plain.isEmpty) {
      setState(() => _error = '请填写正文');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await wpAuth.publishPost(
      title: title,
      content: html,
      contentIsHtml: true,
      status: _status,
      categories: _categoryId == null ? null : [_categoryId!],
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (!result.ok) {
      setState(() => _error = result.message ?? '提交失败，请稍后重试');
      return;
    }
    _submitted = true;
    // 刷新角色信息：若这是第一次发文，能力可能刚发生变化。
    await _loadCapabilities();
    if (!mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final notice = result.downgraded
        ? '当前账号不能直接发布，已转为「待审核」提交'
        : result.notice;
    Navigator.of(context).pop(true);
    messenger.showSnackBar(SnackBar(content: Text(notice)));
  }

  /// 当前状态对应的提交按钮文案。
  String get _submitLabel => switch (_status) {
        'draft' => '保存草稿',
        'pending' => '提交审核',
        _ => '发布',
      };

  // ---------------------------------------------------------------- 插入类

  Future<void> _insertLink() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('插入链接'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('插入'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    _markDirty();
    await _editor.insertLink(_normalizeUrl(url));
  }

  /// 插入图片：优先系统相册（选完直接上传到媒体库），否则退回手填地址。
  Future<void> _insertImage() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              subtitle: const Text('选中后自动上传到站点媒体库'),
              onTap: () => Navigator.of(ctx).pop('pick'),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('填写图片地址'),
              subtitle: const Text('使用已有图片的网络地址'),
              onTap: () => Navigator.of(ctx).pop('url'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'pick') {
      await _pickAndUpload();
    } else {
      await _insertImageByUrl();
    }
  }

  Future<void> _pickAndUpload() async {
    final picked = await MediaPicker.pickImage();
    if (!mounted) return;
    if (picked == null) {
      // 用户取消，或原生选择器不可用（非 Android / 通道缺失）。
      if (!MediaPicker.isSupported) {
        await _insertImageByUrl();
      }
      return;
    }
    setState(() => _uploading = true);
    final url = await wpAuth.uploadMedia(
      bytes: picked.bytes,
      filename: picked.name,
    );
    if (!mounted) return;
    setState(() => _uploading = false);
    final messenger = ScaffoldMessenger.of(context);
    if (url == null || url.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text('图片上传失败：可能是当前账号没有上传权限，或网络异常。'
            '可改用「填写图片地址」。'),
      ));
      return;
    }
    _markDirty();
    await _editor.insertImage(url, alt: '');
    messenger.showSnackBar(const SnackBar(content: Text('图片已插入')));
  }

  Future<void> _insertImageByUrl() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('图片地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://…jpg',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('插入'),
          ),
        ],
      ),
    );
    if (url == null || url.isEmpty) return;
    _markDirty();
    await _editor.insertImage(_normalizeUrl(url));
  }

  /// 用户常直接粘贴 `www.xxx.com/a.jpg`，补上协议头。
  static String _normalizeUrl(String raw) {
    final s = raw.trim();
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('//')) return 'https:$s';
    return 'https://$s';
  }

  // ---------------------------------------------------------------- 界面

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // 键盘弹起时可用高度只剩 ~260 逻辑 px，而顶部的权限提示 + 分类选择就要占 ~170 px，
    // 真机实测结果是**工具栏被挤出屏幕、编辑区只剩一条缝**（字打着却看不见）。
    // 所以键盘一弹起就换成紧凑布局：提示压成一行、分类行暂时收起，把高度全让给编辑区。
    final keyboardUp = MediaQuery.of(context).viewInsets.bottom > 0;

    return PopScope(
      canPop: !_dirty || _submitted,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 先把 navigator 取出来：await 之后再用 context 会触发
        // use_build_context_synchronously。
        final navigator = Navigator.of(context);
        final leave = await _confirmDiscard();
        if (leave) navigator.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('写文章'),
          actions: [
            if (_submitting)
              const Padding(
                padding: EdgeInsets.only(right: 16),
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else
              TextButton.icon(
                onPressed: _submit,
                icon: const Icon(Icons.send_outlined, size: 18),
                label: Text(_submitLabel),
              ),
          ],
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, keyboardUp ? 4 : 10, 16, 0),
              child: _PermissionBanner(
                // 会话已失效时就不要再显示「当前身份：投稿者」了，否则与下面的
                // 过期提示自相矛盾
                user: wpAuth.isLoggedIn ? _me : null,
                loading: _loadingCapabilities,
                onRetry: _loadCapabilities,
                compact: keyboardUp,
              ),
            ),
            // 登录态已失效时给出明确出口：不然用户只会在提交时吃到一句英文报错
            if (!wpAuth.isLoggedIn)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Icon(Icons.lock_clock,
                        size: 16, color: colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '登录状态已过期，请回到「我的」重新登录后再投稿',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  hintText: '标题',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w600),
                textInputAction: TextInputAction.next,
              ),
            ),
            // 分类是「发文前设一次」的属性，打字时没必要占着一行 —— 键盘收起后自动回来
            if (!keyboardUp)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: _CategoryRow(
                  categories: _categories,
                  value: _categoryId,
                  onChanged: (v) => setState(() => _categoryId = v),
                ),
              ),
            const Divider(height: 1),
            _Toolbar(
              controller: _editor,
              onInsertLink: _insertLink,
              onInsertImage: _insertImage,
              onChanged: _markDirty,
            ),
            const Divider(height: 1),
            Expanded(
              child: Stack(
                children: [
                  RichTextEditor(
                    controller: _editor,
                    dark: dark,
                    placeholder: '在这里写正文…支持标题、加粗、列表、引用、代码块、'
                        '链接、图片与脚注。',
                  ),
                  if (_uploading)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Color(0x66000000),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 12),
                              Text('图片上传中…',
                                  style: TextStyle(color: Colors.white)),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            _BottomBar(
              status: _status,
              canPublish: _canPublish,
              editor: _editor,
              onStatusChanged: (s) {
                _markDirty();
                setState(() => _status = s);
              },
            ),
            if (_error != null)
              Container(
                width: double.infinity,
                color: colorScheme.errorContainer,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: colorScheme.onErrorContainer,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<bool> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃这篇内容？'),
        content: const Text('当前内容还没有提交，返回后会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    return leave ?? false;
  }
}

/// 分类选择（横向紧凑一行）。
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.categories,
    required this.value,
    required this.onChanged,
  });

  final List<BlogCategory> categories;
  final int? value;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    if (categories.isEmpty) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return DropdownButtonFormField<int?>(
      initialValue: value,
      isDense: true,
      decoration: InputDecoration(
        labelText: '分类（可选）',
        border: const OutlineInputBorder(),
        isDense: true,
        prefixIcon: Icon(Icons.folder_outlined,
            size: 18, color: colorScheme.outline),
      ),
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('未分类')),
        for (final c in categories)
          DropdownMenuItem<int?>(value: c.id, child: Text('${c.name} · ${c.count}')),
      ],
      onChanged: onChanged,
    );
  }
}

/// 格式化工具栏（可横向滚动）。按钮状态跟随光标位置高亮。
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.controller,
    required this.onInsertLink,
    required this.onInsertImage,
    required this.onChanged,
  });

  final RichTextEditorController controller;
  final Future<void> Function() onInsertLink;
  final Future<void> Function() onInsertImage;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ValueListenableBuilder<EditorToolbarState>(
        valueListenable: controller.toolbar,
        builder: (context, st, _) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                _BlockMenu(controller: controller, current: st.block, onChanged: onChanged),
                const _Sep(),
                _Btn(
                  icon: Icons.undo,
                  tip: '撤销',
                  onTap: () => _run('undo'),
                ),
                _Btn(
                  icon: Icons.redo,
                  tip: '重做',
                  onTap: () => _run('redo'),
                ),
                const _Sep(),
                _Btn(
                  icon: Icons.format_bold,
                  tip: '加粗',
                  active: st.bold,
                  onTap: () => _run('bold'),
                ),
                _Btn(
                  icon: Icons.format_italic,
                  tip: '斜体',
                  active: st.italic,
                  onTap: () => _run('italic'),
                ),
                _Btn(
                  icon: Icons.format_strikethrough,
                  tip: '删除线',
                  active: st.strike,
                  onTap: () => _run('strikeThrough'),
                ),
                _Btn(
                  icon: Icons.code,
                  tip: '行内代码',
                  onTap: () => _runCustom(controller.inlineCode),
                ),
                const _Sep(),
                _Btn(
                  icon: Icons.format_list_bulleted,
                  tip: '无序列表',
                  active: st.ul,
                  onTap: () => _run('insertUnorderedList'),
                ),
                _Btn(
                  icon: Icons.format_list_numbered,
                  tip: '有序列表',
                  active: st.ol,
                  onTap: () => _run('insertOrderedList'),
                ),
                _Btn(
                  icon: Icons.format_quote,
                  tip: '引用',
                  active: st.block == 'blockquote',
                  onTap: () => _toggleBlock('blockquote'),
                ),
                _Btn(
                  icon: Icons.data_object,
                  tip: '代码块',
                  active: st.block == 'pre',
                  onTap: () => _runCustom(controller.codeBlock),
                ),
                const _Sep(),
                _Btn(
                  icon: Icons.link,
                  tip: '链接',
                  onTap: () { onChanged(); onInsertLink(); },
                ),
                _Btn(
                  icon: Icons.image_outlined,
                  tip: '图片',
                  onTap: () { onChanged(); onInsertImage(); },
                ),
                _Btn(
                  icon: Icons.format_indent_increase,
                  tip: '首行缩进',
                  onTap: () => _runCustom(controller.toggleIndent),
                ),
                _Btn(
                  icon: Icons.superscript,
                  tip: '脚注',
                  active: st.inFootnote,
                  onTap: () => _runCustom(controller.insertFootnote),
                ),
                _Btn(
                  icon: Icons.format_clear,
                  tip: '清除格式',
                  onTap: () => _runCustom(controller.clearFormat),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _run(String cmd, {String? value}) async {
    onChanged();
    await controller.exec(cmd, value: value);
    await controller.focus();
  }

  Future<void> _runCustom(Future<void> Function() fn) async {
    onChanged();
    await fn();
    await controller.focus();
  }

  Future<void> _toggleBlock(String tag) async {
    onChanged();
    await controller.exec('formatBlock', value: '<$tag>');
    await controller.focus();
  }
}

/// 块级格式菜单（正文 / 标题 / 引用 / 代码块）。
class _BlockMenu extends StatelessWidget {
  const _BlockMenu({
    required this.controller,
    required this.current,
    required this.onChanged,
  });

  final RichTextEditorController controller;
  final String current;
  final VoidCallback onChanged;

  static const Map<String, String> _labels = {
    'p': '正文',
    'h2': '标题 2',
    'h3': '标题 3',
    'h4': '标题 4',
    'blockquote': '引用',
    'pre': '代码块',
  };

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final label = _labels[current] ?? '正文';
    return PopupMenuButton<String>(
      tooltip: '段落格式',
      onSelected: (v) async {
        onChanged();
        if (v == 'pre') {
          await controller.codeBlock();
        } else {
          await controller.exec('formatBlock', value: '<$v>');
        }
        await controller.focus();
      },
      itemBuilder: (ctx) => [
        for (final e in _labels.entries)
          PopupMenuItem<String>(
            value: e.key,
            child: Row(
              children: [
                if (e.key == current)
                  Icon(Icons.check, size: 16, color: colorScheme.primary)
                else
                  const SizedBox(width: 16),
                const SizedBox(width: 8),
                Text(e.value),
              ],
            ),
          ),
      ],
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(label, style: const TextStyle(fontSize: 13)),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

class _Btn extends StatelessWidget {
  const _Btn({
    required this.icon,
    required this.tip,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: tip,
      child: IconButton(
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        isSelected: active,
        style: IconButton.styleFrom(
          backgroundColor: active ? colorScheme.primaryContainer : null,
          foregroundColor: active ? colorScheme.onPrimaryContainer : null,
        ),
        icon: Icon(icon),
      ),
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 22,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Theme.of(context).colorScheme.outlineVariant,
      );
}

/// 底部：提交方式 + 字数。
class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.status,
    required this.canPublish,
    required this.editor,
    required this.onStatusChanged,
  });

  final String status;
  final bool canPublish;
  final RichTextEditorController editor;
  final ValueChanged<String> onStatusChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              style: const ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              segments: [
                ButtonSegment(
                  value: 'publish',
                  label: Text(canPublish ? '直接发布' : '提交审核',
                      style: const TextStyle(fontSize: 12.5)),
                ),
                const ButtonSegment(
                  value: 'draft',
                  label: Text('存为草稿', style: TextStyle(fontSize: 12.5)),
                ),
              ],
              selected: {status == 'pending' ? 'publish' : status},
              onSelectionChanged: (s) => onStatusChanged(
                s.first == 'publish' ? (canPublish ? 'publish' : 'pending') : s.first,
              ),
            ),
          ),
          const SizedBox(width: 10),
          ValueListenableBuilder<EditorToolbarState>(
            valueListenable: editor.toolbar,
            builder: (context, st, _) => Text(
              '${st.chars} 字',
              style: TextStyle(fontSize: 12, color: colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部角色提示条：投稿者等无发布权限的账号会看到审核说明。
///
/// 有直接发布权限时不显示，避免打扰。
class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner({
    required this.user,
    required this.loading,
    required this.onRetry,
    this.compact = false,
  });

  final WpUser? user;
  final bool loading;
  final VoidCallback onRetry;

  /// 键盘弹起时为 true：压成一行，把高度让给编辑区（见 [EditorPage.build] 的说明）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    final me = user;
    if (me == null) return const SizedBox.shrink();

    // 读不到能力时不臆测，保持安静。
    if (!me.capabilitiesKnown) return const SizedBox.shrink();

    final role = me.roleLabel;
    final canPublish = me.canPublish;
    final colorScheme = Theme.of(context).colorScheme;

    if (canPublish) {
      if (role.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: EdgeInsets.only(bottom: compact ? 2 : 8),
        child: Row(
          children: [
            Icon(Icons.verified_outlined, size: 15, color: colorScheme.primary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                compact ? '$role · 可直接发布' : '当前身份：$role · 可直接发布',
                style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    // 紧凑态：只留一行「身份 · 去向」，不占地方
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          children: [
            Icon(Icons.info_outline,
                size: 14, color: colorScheme.onTertiaryContainer),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                '${role.isEmpty ? '投稿者' : role} · 提交后进入待审核队列',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onTertiaryContainer,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
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
              Expanded(
                child: Text(
                  role.isEmpty ? '当前账号需要审核' : '当前身份：$role',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onTertiaryContainer,
                  ),
                ),
              ),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('重新读取', style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '「${role.isEmpty ? '投稿者' : role}」没有直接发布权限，'
            '点「提交审核」后的文章会进入待审核队列，管理员通过后即可公开显示。',
            style: TextStyle(
              fontSize: 12.5,
              height: 1.6,
              color: colorScheme.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
