import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// 本地通知服务：初始化、权限、发送。
abstract final class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static bool _initialized = false;

  /// 是否已拿到系统通知权限。
  static bool permissionGranted = false;

  static const _channelId = 'ybh_blog_news';
  static const _channelName = 'YBH 动态';
  static const _channelDesc = '新文章发布、投稿审核通过提醒';

  /// 初始化（应用启动时调用一次）。
  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidInit,
        iOS: iosInit,
      ),
    );

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    permissionGranted =
        await android?.areNotificationsEnabled() ?? false;
    if (kDebugMode) {
      debugPrint('[notify] notifications enabled: $permissionGranted');
    }
  }

  /// 请求通知权限（Android 13+ 首次启动弹窗；低版本直接返回 true）。
  ///
  /// 返回最终是否可用。
  static Future<bool> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final granted =
        await android?.requestNotificationsPermission() ?? true;
    permissionGranted = granted;
    return granted;
  }

  /// 发送一条即时通知。
  static Future<void> show({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!permissionGranted) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        _channelId,
        _channelName,
        channelDescription: _channelDesc,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.recommendation,
      );
      await _plugin.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: androidDetails,
        ),
      );
    } catch (e) {
      debugPrint('[notify] 发送失败: $e');
    }
  }
}
