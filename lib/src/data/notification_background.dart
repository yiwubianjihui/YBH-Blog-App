import 'package:workmanager/workmanager.dart';

import 'notification_checker.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';

/// WorkManager 后台任务的入口。
///
/// 必须在顶层（不能放在类里），且用 @pragma 标注，保证 release 构建
/// 不被 tree-shake 掉。App 前台运行同一个回调时也可以直接调用
/// [NotificationChecker.runOnce]。
@pragma('vm:entry-point')
void notificationBackgroundCallback() {
  Workmanager().executeTask((task, inputData) async {
    await NotificationService.init();
    await NotificationChecker.runOnce();
    return true;
  });
}

/// 周期任务调度：依据用户设置注册 / 更新 / 取消后台检查。
abstract final class NotificationScheduler {
  static const String _taskName = 'ybh_periodic_notification';
  static bool _initialized = false;

  /// 初始化 WorkManager（应用启动时调用一次）。
  static Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    await Workmanager().initialize(notificationBackgroundCallback);
  }

  /// 按当前设置注册或取消周期任务。设置变更后也应调用。
  static Future<void> schedule() async {
    final prefs = await NotificationPrefs.load();
    if (!prefs.enabled || prefs.frequencyMinutes <= 0) {
      await Workmanager().cancelByUniqueName(_taskName);
      return;
    }
    // Android WorkManager 的最小周期是 15 分钟，过小会抛异常。
    final minutes = prefs.frequencyMinutes.clamp(15, 180);
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: Duration(minutes: minutes),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    );
  }

  /// 立即在后台执行一次检查（前台测试 / 手动「立即检查」用）。
  static Future<void> runNow() => NotificationChecker.runOnce();
}
