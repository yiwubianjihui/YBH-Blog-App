import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_config.dart';
import '../data/blog_api.dart';
import '../data/update_checker.dart';
import '../ui/category_order_page.dart';
import '../ui/home_tab.dart';
import '../ui/profile_tab.dart';
import '../ui/posts_tab.dart';
import '../ui/search_page.dart';
import 'webview_ui_state.dart';
import 'webview_tab.dart' if (dart.library.html) 'webview_tab_stub.dart';

/// 主外壳：底部导航（首页 / 文章 / 整站 / 我的）+ 抽屉菜单 + 动态 AppBar。
class HomeShellPage extends StatefulWidget {
  const HomeShellPage({
    super.key,
    required this.darkMode,
    required this.onToggleDarkMode,
    this.onOpenNotificationSettings,
  });

  final bool darkMode;
  final ValueChanged<bool> onToggleDarkMode;

  /// 打开「通知设置」页。
  final Future<void> Function()? onOpenNotificationSettings;

  @override
  State<HomeShellPage> createState() => _HomeShellPageState();
}

class _HomeShellPageState extends State<HomeShellPage> {
  /// tab 索引：0 首页 / 1 文章 / 2 整站 / 3 我的。
  int _tab = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey<PostsTabState> _postsKey = GlobalKey<PostsTabState>();
  final GlobalKey<BlogWebViewState> _webKey = GlobalKey<BlogWebViewState>();
  final WebViewUiState _webUi = WebViewUiState();
  DateTime? _lastBackPressedAt;

  @override
  void initState() {
    super.initState();
    _autoCheckUpdate();
  }

  /// 启动后延迟静默检查一次更新：有新版弹窗提醒，失败不打扰用户。
  Future<void> _autoCheckUpdate() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    final info = await UpdateChecker.fetch();
    if (!mounted || info == null) return;
    final current = await UpdateChecker.currentVersion();
    if (!mounted) return;
    if (UpdateChecker.isNewerVersion(current, info.version)) {
      await UpdateChecker.showUpdateDialog(context, info);
    }
  }

  @override
  void dispose() {
    _webUi.dispose();
    super.dispose();
  }

  void _selectTab(int index) {
    setState(() => _tab = index);
  }

  /// Android 返回键逻辑：
  /// 抽屉开着 → 关抽屉；整站页可后退 → 网页后退；否则切回首页；
  /// 已在首页 → 双击退出。
  Future<void> _handleBack() async {
    if (_scaffoldKey.currentState?.isDrawerOpen ?? false) {
      _scaffoldKey.currentState?.closeDrawer();
      return;
    }
    if (_tab == 2) {
      final state = _webKey.currentState;
      if (state != null && await state.goBackIfPossible()) return;
      _selectTab(0);
      return;
    }
    if (_tab != 0) {
      _selectTab(0);
      return;
    }
    final now = DateTime.now();
    if (_lastBackPressedAt != null &&
        now.difference(_lastBackPressedAt!) < const Duration(seconds: 2)) {
      if (mounted) await SystemNavigator.pop();
      return;
    }
    _lastBackPressedAt = now;
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('再按一次返回键退出应用')));
    }
  }

  Future<void> _shareSite() async {
    await SharePlus.instance.share(
      ShareParams(
        text: '来自${AppConfig.appName}的分享',
        uri: Uri.parse(AppConfig.blogUrl),
      ),
    );
  }

  Future<void> _openSiteInBrowser() async {
    await launchUrl(
      Uri.parse(AppConfig.blogUrl),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _copySiteUrl() async {
    await Clipboard.setData(const ClipboardData(text: AppConfig.blogUrl));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('站点地址已复制到剪贴板')),
      );
    }
  }

  /// 打开「分类排序」页；若用户保存了新偏好，则通知「文章」页立即重排分类筛选条。
  Future<void> _openCategoryOrder() async {
    // 复用「文章」页已拉取的原始分类，省掉一次联网请求。
    final loaded = _postsKey.currentState?.rawCategories ?? const <BlogCategory>[];
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CategoryOrderPage(initialCategories: loaded),
      ),
    );
    if (result == true && mounted) {
      _postsKey.currentState?.applyCategoryOrder();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        key: _scaffoldKey,
        appBar: _buildAppBar(),
        drawer: _buildDrawer(),
        body: IndexedStack(
          sizing: StackFit.expand,
          index: _tab,
          children: [
            HomeTab(
              onOpenSite: () => _selectTab(2),
            ),
            PostsTab(key: _postsKey, onOpenCategoryOrder: _openCategoryOrder),
            BlogWebViewPage(key: _webKey, uiState: _webUi),
            ProfileTab(
              onOpenCategoryOrder: _openCategoryOrder,
              onOpenNotificationSettings: widget.onOpenNotificationSettings,
            ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _selectTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: '首页',
            ),
            NavigationDestination(
              icon: Icon(Icons.article_outlined),
              selectedIcon: Icon(Icons.article),
              label: '文章',
            ),
            NavigationDestination(
              icon: Icon(Icons.public_outlined),
              selectedIcon: Icon(Icons.public),
              label: '整站',
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }

  AppBar _buildAppBar() {
    // 整站页在 AppBar 底部显示加载进度条。
    final progressBar = _tab == 2
        ? PreferredSize(
            preferredSize: const Size.fromHeight(3),
            child: SizedBox(
              height: 3,
              child: ListenableBuilder(
                listenable: _webUi.merged,
                builder: (context, child) {
                  final loading = _webUi.loading.value;
                  final progress = _webUi.progress.value;
                  if (!loading) return const SizedBox.shrink();
                  return LinearProgressIndicator(
                    value: progress <= 0 ? null : progress / 100,
                    minHeight: 3,
                  );
                },
              ),
            ),
          )
        : null;

    switch (_tab) {
      case 0:
        return AppBar(
          title: const _AppTitle(title: AppConfig.appName),
          bottom: progressBar,
        );
      case 1:
        return AppBar(
          title: const _AppTitle(title: '文章'),
          bottom: progressBar,
          actions: [
            IconButton(
              tooltip: '搜索文章',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const SearchPage()),
                );
              },
              icon: const Icon(Icons.search),
            ),
            IconButton(
              tooltip: '分类管理（置顶 / 隐藏 / 排序）',
              onPressed: () => _openCategoryOrder(),
              icon: const Icon(Icons.tune_outlined),
            ),
            IconButton(
              tooltip: '刷新文章',
              onPressed: () => _postsKey.currentState?.refresh(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        );
      case 2:
        return AppBar(
          title: const _AppTitle(title: '整站浏览'),
          bottom: progressBar,
          actions: [
            IconButton(
              tooltip: '回到首页',
              onPressed: () => _webKey.currentState?.goHome(),
              icon: const Icon(Icons.home_outlined),
            ),
            IconButton(
              tooltip: '刷新',
              onPressed: () => _webKey.currentState?.reload(),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: '分享当前页面',
              onPressed: () => _webKey.currentState?.share(),
              icon: const Icon(Icons.share_outlined),
            ),
            IconButton(
              tooltip: '用系统浏览器打开',
              onPressed: () => _webKey.currentState?.openInBrowser(),
              icon: const Icon(Icons.open_in_browser_outlined),
            ),
          ],
        );
      default:
        return AppBar(
          title: const _AppTitle(title: '我的'),
          bottom: progressBar,
        );
    }
  }

  Widget _buildDrawer() {
    final colorScheme = Theme.of(context).colorScheme;
    return NavigationDrawer(
      onDestinationSelected: (index) {
        _scaffoldKey.currentState?.closeDrawer();
        if (index == 0) {
          _selectTab(0);
        } else if (index == 1) {
          _selectTab(1);
        } else if (index == 2) {
          _selectTab(2);
        } else if (index == 3) {
          _selectTab(3);
        } else if (index == 4) {
          _shareSite();
        } else if (index == 5) {
          _openSiteInBrowser();
        } else if (index == 6) {
          _copySiteUrl();
        }
      },
      children: [
        // 头部：logo + 站点信息。
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.asset(
                  'assets/icon/app_icon.png',
                  width: 48,
                  height: 48,
                  cacheWidth: 96,
                  cacheHeight: 96,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.article,
                    size: 40,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      AppConfig.appName,
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppConfig.blogUrl.replaceFirst('https://', ''),
                      style: TextStyle(fontSize: 12, color: colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.home_outlined),
          label: Text('首页'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.article_outlined),
          label: Text('文章列表'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.public_outlined),
          label: Text('整站浏览'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.person_outline),
          label: Text('我的'),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12),
        const NavigationDrawerDestination(
          icon: Icon(Icons.share_outlined),
          label: Text('分享应用'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.open_in_browser_outlined),
          label: Text('用浏览器打开站点'),
        ),
        const NavigationDrawerDestination(
          icon: Icon(Icons.copy_outlined),
          label: Text('复制站点地址'),
        ),
        const Divider(height: 1, indent: 12, endIndent: 12),
        // 夜间模式开关（非导航项，仅设置）。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: const Text('夜间模式'),
            secondary: Icon(
              widget.darkMode ? Icons.dark_mode : Icons.dark_mode_outlined,
            ),
            value: widget.darkMode,
            onChanged: widget.onToggleDarkMode,
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

/// AppBar 左侧标题：站点 logo + 文字。
class _AppTitle extends StatelessWidget {
  const _AppTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/icon/app_icon.png',
          width: 26,
          height: 26,
          cacheWidth: 52,
          cacheHeight: 52,
          errorBuilder: (context, error, stackTrace) =>
              const Icon(Icons.article, size: 20),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
