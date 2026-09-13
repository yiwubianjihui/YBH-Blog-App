import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 电池优化白名单（T30 · 通知可达性）。
///
/// 后台通知靠 WorkManager 周期任务投递。华为等 ROM 的省电策略会冻结
/// 「未加入电池优化白名单」的应用，任务停摆 —— 用户看到的是「权限都给了却收不到通知」。
/// 白名单只能由用户确认，App 做「检测 + 引导跳转」。
///
/// 原生实现在 `MainActivity.kt`（官方 API `isIgnoringBatteryOptimizations` /
/// `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`）。任何异常都吞掉并按「无法判定」处理，
/// **绝不因为这项引导影响通知本身的可用性**。
abstract final class PowerGuard {
  static const MethodChannel _channel = MethodChannel('cn.yibianhui.blog/power');

  /// 是否已在电池优化白名单里；平台不支持或调用失败时返回 null（无法判定）。
  static Future<bool?> isIgnoringBatteryOptimizations() async {
    if (kIsWeb) return null;
    try {
      final v = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return v;
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint('[power] 查询电池白名单失败: $e');
      return null;
    }
  }

  /// 弹系统对话框申请加入白名单。返回是否成功拉起系统界面。
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (kIsWeb) return false;
    try {
      final v = await _channel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
      return v ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('[power] 请求电池白名单失败: $e');
      return false;
    }
  }
}
