import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'src/app_config.dart';
import 'src/blog_host.dart';
import 'src/data/notification_background.dart';
import 'src/data/notification_checker.dart';
import 'src/data/notification_prefs.dart';
import 'src/data/notification_service.dart';
import 'src/data/wp_auth.dart';
import 'src/ui/notification_settings_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 通知：初始化 + 注册后台周期任务（在 runApp 之前，纯异步无 UI 依赖）。
  _initNotifications();
  runApp(const YbhApp());
}

/// 通知相关的一次性初始化。
Future<void> _initNotifications() async {
  await NotificationService.init();
  await NotificationScheduler.initialize();
  await NotificationScheduler.schedule();
  // 首次启动弹窗询问通知权限（Android 13+ 系统会再次确认）。
  final prefs = await NotificationPrefs.load();
  if (prefs.enabled) {
    await NotificationService.requestPermission();
  }
  // 登记当前待审核文章，为「审核通过」提醒铺路（静默失败）。
  await NotificationChecker.seedPendingIds();
}

class YbhApp extends StatefulWidget {
  const YbhApp({super.key});

  @override
  State<YbhApp> createState() => _YbhAppState();
}

class _YbhAppState extends State<YbhApp> {
  static const String _darkModeKey = 'ybh_dark_mode';

  bool _darkMode = false;

  /// 「通知设置」页入口（由「我的」页调用）。
  Future<void> _openNotificationSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const NotificationSettingsPage()),
    );
    // 返回后按新设置重新注册周期任务。
    await NotificationScheduler.schedule();
  }

  @override
  void initState() {
    super.initState();
    _loadDarkMode();
    wpAuth.load();
  }

  Future<void> _loadDarkMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() => _darkMode = prefs.getBool(_darkModeKey) ?? false);
    } catch (_) {
      // 读取失败则保持默认。
    }
  }

  Future<void> _toggleDarkMode(bool value) async {
    setState(() => _darkMode = value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_darkModeKey, value);
    } catch (_) {
      // 忽略写入失败。
    }
  }

  @override
  Widget build(BuildContext context) {
    const primary = Color(AppConfig.themeColorValue);
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.system,
      theme: _buildTheme(primary, dark: false),
      darkTheme: _buildTheme(primary, dark: true),
      home: BlogHost(
        darkMode: _darkMode,
        onToggleDarkMode: _toggleDarkMode,
        onOpenNotificationSettings: _openNotificationSettings,
      ),
    );
  }

  ThemeData _buildTheme(Color primary, {required bool dark}) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: primary,
      brightness: dark ? Brightness.dark : Brightness.light,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      primaryColor: primary,
      appBarTheme: AppBarTheme(
        backgroundColor: colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: Colors.transparent,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
        linearTrackColor: colorScheme.primary.withValues(alpha: 0.2),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12)),
      ),
    );
  }
}
