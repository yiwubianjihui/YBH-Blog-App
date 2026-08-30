import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';
import '../data/blog_api.dart';
import '../data/category_order.dart';
import '../data/update_checker.dart';
import '../data/wp_auth.dart';
import 'editor_page.dart';
import 'post_card.dart';
import 'post_detail_page.dart';

/// 「我的」页：未登录显示登录表单；登录后显示用户信息、我的文章与写文章入口。
class ProfileTab extends StatefulWidget {
  const ProfileTab({
    super.key,
    this.onOpenCategoryOrder,
    this.onOpenNotificationSettings,
  });

  /// 打开「分类排序」页（由外壳实现，返回后刷新文章页分类顺序）。
  final Future<void> Function()? onOpenCategoryOrder;

  /// 打开「通知设置」页。
  final Future<void> Function()? onOpenNotificationSettings;

  @override
  State<ProfileTab> createState() => _ProfileTabState();
}

class _ProfileTabState extends State<ProfileTab> {
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _logging = false;
  String? _loginError;
  bool _showAppPwHelp = false;
  bool _pwdVisible = false;

  List<PostSummary> _myPosts = const [];
  bool _loadingPosts = false;
  bool _postsError = false;

  /// 分类偏好（置顶 / 隐藏 数量），用于「分类管理」入口的概要展示。
  CategoryPrefs _categoryPrefs = const CategoryPrefs();

  String _version = '…';
  String _buildNumber = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadCategoryPrefs();
    if (wpAuth.isLoggedIn) _loadMyPosts();
  }

  @override
  void dispose() {
    _userController.dispose();
    _passController.dispose();
    super.dispose();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _buildNumber = info.buildNumber;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _version = '0.0.0');
    }
  }

  Future<void> _login() async {
    if (_logging) return;
    setState(() {
      _logging = true;
      _loginError = null;
    });
    final ok = await wpAuth.login(_userController.text, _passController.text);
    if (!mounted) return;
    setState(() => _logging = false);
    if (ok) {
      _passController.clear();
      _loadMyPosts();
    } else {
      setState(() => _loginError = '登录失败，请检查用户名与应用密码');
    }
  }

  Future<void> _loadMyPosts() async {
    setState(() {
      _loadingPosts = true;
      _postsError = false;
    });
    try {
      final posts = await wpAuth.fetchMyPosts();
      if (!mounted) return;
      setState(() {
        _myPosts = posts;
        _loadingPosts = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingPosts = false;
        _postsError = true;
      });
    }
  }

  Future<void> _logout() async {
    await wpAuth.logout();
    if (!mounted) return;
    setState(() {
      _myPosts = const [];
    });
  }

  Future<void> _checkUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    final info = await UpdateChecker.fetch();
    if (!mounted) return;
    if (info == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('检查更新失败，请稍后重试')),
      );
      return;
    }
    if (UpdateChecker.isNewerVersion(_version, info.version)) {
      await UpdateChecker.showUpdateDialog(context, info);
    } else {
      messenger.showSnackBar(
        SnackBar(content: Text('已是最新版本 v$_version')),
      );
    }
  }

  /// 「分类管理」入口的概要文案：已置顶 / 已隐藏的数量。
  String get _categorySummary {
    final pinned = _categoryPrefs.pinned.length;
    final hidden = _categoryPrefs.hidden.length;
    final parts = <String>[];
    if (pinned > 0) parts.add('已置顶 $pinned 个');
    if (hidden > 0) parts.add('已隐藏 $hidden 个');
    if (parts.isEmpty) return '已自定义排序';
    return '${parts.join(' · ')} · 点此修改';
  }

  Future<void> _loadCategoryPrefs() async {
    final prefs = await CategoryOrderStore.load();
    if (!mounted) return;
    setState(() => _categoryPrefs = prefs);
  }

  Future<void> _writeArticle() async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(builder: (_) => const EditorPage()),
    );
    if (result == true && mounted) _loadMyPosts();
  }

  Future<void> _openCategoryOrder() async {
    await widget.onOpenCategoryOrder?.call();
    if (!mounted) return;
    await _loadCategoryPrefs();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
      children: [
        if (!wpAuth.isLoggedIn) _LoginCard(
          userController: _userController,
          passController: _passController,
          logging: _logging,
          error: _loginError,
          pwdVisible: _pwdVisible,
          onTogglePwd: () => setState(() => _pwdVisible = !_pwdVisible),
          onLogin: _login,
          showHelp: _showAppPwHelp,
          onToggleHelp: () => setState(() => _showAppPwHelp = !_showAppPwHelp),
        )
        else
          _LoggedInHeader(
            user: wpAuth.user!,
            onLogout: _logout,
            onWrite: _writeArticle,
          ),
        const SizedBox(height: 20),
        // 分类管理放在最前面：这是最常用的个性化入口，以前藏在页面底部不容易找到。
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('分类管理'),
                subtitle: Text(
                  _categoryPrefs.isEmpty
                      ? '置顶常用分类 · 隐藏不感兴趣的分类 · 拖动调整顺序'
                      : _categorySummary,
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_categoryPrefs.isEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '已设置',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: colorScheme.onPrimaryContainer,
                          ),
                        ),
                      ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right_outlined),
                  ],
                ),
                onTap: widget.onOpenCategoryOrder == null
                    ? null
                    : () async {
                        await _openCategoryOrder();
                      },
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (wpAuth.isLoggedIn) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  '我的文章',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh_outlined, size: 20),
                onPressed: _loadingPosts ? null : _loadMyPosts,
              ),
            ],
          ),
          const SizedBox(height: 4),
          _MyPostsList(
            loading: _loadingPosts,
            error: _postsError,
            posts: _myPosts,
            onRetry: _loadMyPosts,
            onOpen: (index) => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PostDetailPage(
                  posts: _myPosts,
                  initialIndex: index,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
        Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.system_update_alt_outlined),
                title: const Text('检查更新'),
                subtitle: const Text('查看是否有新版本可用'),
                onTap: _checkUpdate,
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.public_outlined),
                title: const Text('站点地址'),
                subtitle: const Text(AppConfig.blogUrl),
                trailing: IconButton(
                  tooltip: '复制',
                  icon: const Icon(Icons.copy_outlined, size: 20),
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await Clipboard.setData(
                      const ClipboardData(text: AppConfig.blogUrl),
                    );
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('站点地址已复制到剪贴板')),
                      );
                    }
                  },
                ),
                onTap: () => launchUrl(
                  Uri.parse(AppConfig.blogUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('分享应用'),
                subtitle: const Text('把 YBH 推荐给朋友'),
                onTap: () => SharePlus.instance.share(
                  ShareParams(
                    text: '推荐这个博客客户端给你：${AppConfig.appName}\n站点：${AppConfig.blogUrl}',
                    uri: Uri.parse(AppConfig.blogUrl),
                  ),
                ),
              ),
              const Divider(height: 1, indent: 56),
              ListTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('通知设置'),
                subtitle: const Text('新文章发布、投稿审核通过提醒'),
                trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                onTap: widget.onOpenNotificationSettings == null
                    ? null
                    : () => widget.onOpenNotificationSettings!(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '关于本应用',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'YBH 是义编会（www.yibianhui.cn）的官方客户端：'
                  '刷文章、逛整站、投稿、摇人，一个 App 全搞定。\n'
                  '支持 Android / iOS / macOS / Web，桌面端会跳转到系统浏览器。',
                  style: TextStyle(
                    fontSize: 13.5,
                    height: 1.7,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                // 开源入口：主页面上只放一句人话，技术细节收进下方折叠区。
                OutlinedButton.icon(
                  onPressed: () => launchUrl(
                    Uri.parse('https://github.com/Yibianhui/YBH-Blog-App'),
                    mode: LaunchMode.externalApplication,
                  ),
                  icon: const Icon(Icons.code_outlined, size: 18),
                  label: const Text('查看开源代码（GitHub）'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                  ),
                ),
                const SizedBox(height: 4),
                // 技术细节折叠区：不在主页面上用术语打扰普通用户。
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text(
                    '技术信息',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'YBH 用 Flutter 开发（Dart），数据来自站点的 WordPress REST 接口。'
                        '「文章」页为原生列表 + 正文阅读器，「整站」页为内嵌完整网站。'
                        '项目以 MIT 协议开源在 GitHub，欢迎提交 Issue 或代码。',
                        style: TextStyle(
                          fontSize: 12.5,
                          height: 1.7,
                          color: colorScheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  'v$_version ($_buildNumber)',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 未登录：登录表单 + 应用密码获取说明。
class _LoginCard extends StatelessWidget {
  const _LoginCard({
    required this.userController,
    required this.passController,
    required this.logging,
    required this.error,
    required this.pwdVisible,
    required this.onTogglePwd,
    required this.onLogin,
    required this.showHelp,
    required this.onToggleHelp,
  });

  final TextEditingController userController;
  final TextEditingController passController;
  final bool logging;
  final String? error;
  final bool pwdVisible;
  final VoidCallback onTogglePwd;
  final VoidCallback onLogin;
  final bool showHelp;
  final VoidCallback onToggleHelp;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '登录',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '使用站点账号的「用户名 + 密码」登录后可发布文章。',
              style: TextStyle(fontSize: 12.5, color: colorScheme.outline),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: userController,
              decoration: const InputDecoration(
                labelText: '用户名 / 邮箱',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person_outline),
              ),
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passController,
              obscureText: !pwdVisible,
              decoration: InputDecoration(
                labelText: '密码',
                helperText: '账号登录密码（JWT，登录后整站自动同步）',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key_outlined),
                suffixIcon: IconButton(
                  icon: Icon(
                    pwdVisible ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: onTogglePwd,
                ),
              ),
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => onLogin(),
              autofillHints: const [AutofillHints.password],
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: logging ? null : onLogin,
                icon: logging
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      )
                    : const Icon(Icons.login, size: 18),
                label: const Text('登录'),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Text(
                error!,
                style: TextStyle(color: colorScheme.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 10),
            TextButton(
              onPressed: onToggleHelp,
              child: Text(showHelp ? '收起说明' : '登录方式说明'),
            ),
            if (showHelp)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  '默认用「用户名 + 账号密码」通过 JWT 登录（站点已安装 JWT 插件，最方便）。\n'
                  '若 JWT 不可用（插件未装/未配置），会自动改用 WordPress 核心的「应用密码」：\n'
                  '  1. 用浏览器登录站点后台（WordPress 仪表盘）；\n'
                  '  2. 进入「用户 → 个人资料」；\n'
                  '  3. 找到「应用密码」一栏，输入名称后点击「添加新应用密码」；\n'
                  '  4. 复制生成的 24 位密码（含空格），粘贴到「密码」框即可。\n'
                  '（两种方式均需站点启用 HTTPS，本站已满足。）',
                  style: TextStyle(fontSize: 12.5, height: 1.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 已登录：用户信息头部 + 写文章按钮。
class _LoggedInHeader extends StatelessWidget {
  const _LoggedInHeader({
    required this.user,
    required this.onLogout,
    required this.onWrite,
  });

  final WpUser user;
  final VoidCallback onLogout;
  final VoidCallback onWrite;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final initial = (user.name.isNotEmpty ? user.name[0] : '?').toUpperCase();
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: colorScheme.primaryContainer,
              backgroundImage:
                  user.avatarUrl != null ? NetworkImage(user.avatarUrl!) : null,
              child: user.avatarUrl == null
                  ? Text(
                      initial,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            user.name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (user.roleLabel.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              user.roleLabel,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (user.email != null && user.email!.isNotEmpty)
                      Text(
                        user.email!,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: colorScheme.outline,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            FilledButton.icon(
              onPressed: onWrite,
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('写文章'),
            ),
            const SizedBox(width: 4),
            IconButton(
              tooltip: '退出登录',
              icon: const Icon(Icons.logout_outlined),
              onPressed: onLogout,
            ),
          ],
        ),
      ),
    );
  }
}

/// 已登录：我的文章列表。
class _MyPostsList extends StatelessWidget {
  const _MyPostsList({
    required this.loading,
    required this.error,
    required this.posts,
    required this.onRetry,
    required this.onOpen,
  });

  final bool loading;
  final bool error;
  final List<PostSummary> posts;
  final VoidCallback onRetry;
  final void Function(int) onOpen;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (error) {
      return Center(
        child: Column(
          children: [
            const Icon(Icons.wifi_off_rounded, size: 40),
            const SizedBox(height: 8),
            const Text('加载失败'),
            TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      );
    }
    if (posts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            '还没有发布文章',
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
    }
    return Column(
      children: [
        for (var i = 0; i < posts.length; i++) ...[
          _MyPostItem(post: posts[i], onTap: () => onOpen(i)),
          const SizedBox(height: 12),
        ],
      ],
    );
  }
}

/// 「我的文章」的单条：在卡片右上角叠一个状态角标（草稿 / 待审核）。
class _MyPostItem extends StatelessWidget {
  const _MyPostItem({required this.post, required this.onTap});

  final PostSummary post;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final label = post.statusLabel;
    if (label == null) return PostCard(post: post, onTap: onTap);
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        PostCard(post: post, onTap: onTap),
        PositionedDirectional(
          top: 8,
          end: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: colorScheme.tertiaryContainer.withValues(alpha: 0.95),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: colorScheme.onTertiaryContainer,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
