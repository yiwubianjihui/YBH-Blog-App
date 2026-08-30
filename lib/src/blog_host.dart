import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'desktop_fallback_page.dart';
import 'shell/home_shell.dart';
import 'web_redirect_stub.dart' if (dart.library.html) 'web_redirect_page.dart';

/// 根据运行平台选择应用外壳：
/// - Android / iOS / macOS：完整外壳（首页 + 文章 + 整站 WebView + 我的）；
/// - Web：品牌启动页后自动跳转博客整站；
/// - Windows / Linux：轻量桌面壳（跳转系统浏览器打开站点）。
class BlogHost extends StatelessWidget {
  const BlogHost({
    super.key,
    required this.darkMode,
    required this.onToggleDarkMode,
    this.onOpenNotificationSettings,
  });

  final bool darkMode;
  final ValueChanged<bool> onToggleDarkMode;

  /// 打开「通知设置」页（由外层提供，避免这里直接依赖具体页面）。
  final Future<void> Function()? onOpenNotificationSettings;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return const BlogRedirectPage();
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return HomeShellPage(
          darkMode: darkMode,
          onToggleDarkMode: onToggleDarkMode,
          onOpenNotificationSettings: onOpenNotificationSettings,
        );
      default:
        return const DesktopFallbackPage();
    }
  }
}
