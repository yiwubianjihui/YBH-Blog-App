import 'package:shared_preferences/shared_preferences.dart';

/// 通知偏好：总开关、检查频率、分类开关。
///
/// 首次启动会请求系统通知权限，这里只存「App 内想不想收通知」。
class NotificationPrefs {
  const NotificationPrefs({
    this.enabled = true,
    this.frequencyMinutes = 60,
    this.newPostEnabled = true,
    this.myPostEnabled = true,
  });

  /// 是否接收通知（总开关）。
  final bool enabled;

  /// 后台检查频率（分钟）：15 / 60 / 180；0 表示关闭后台检查。
  final int frequencyMinutes;

  /// 新文章发布提醒。
  final bool newPostEnabled;

  /// 我的投稿审核通过提醒。
  final bool myPostEnabled;

  NotificationPrefs copyWith({
    bool? enabled,
    int? frequencyMinutes,
    bool? newPostEnabled,
    bool? myPostEnabled,
  }) =>
      NotificationPrefs(
        enabled: enabled ?? this.enabled,
        frequencyMinutes: frequencyMinutes ?? this.frequencyMinutes,
        newPostEnabled: newPostEnabled ?? this.newPostEnabled,
        myPostEnabled: myPostEnabled ?? this.myPostEnabled,
      );

  static const String _enabledKey = 'ybh_notify_enabled';
  static const String _freqKey = 'ybh_notify_frequency_minutes';
  static const String _newPostKey = 'ybh_notify_new_post';
  static const String _myPostKey = 'ybh_notify_my_post';

  static Future<NotificationPrefs> load() async {
    final prefs = await SharedPreferences.getInstance();
    return NotificationPrefs(
      enabled: prefs.getBool(_enabledKey) ?? true,
      frequencyMinutes: prefs.getInt(_freqKey) ?? 60,
      newPostEnabled: prefs.getBool(_newPostKey) ?? true,
      myPostEnabled: prefs.getBool(_myPostKey) ?? true,
    );
  }

  static Future<bool> save(NotificationPrefs prefs) async {
    try {
      final store = await SharedPreferences.getInstance();
      await Future.wait([
        store.setBool(_enabledKey, prefs.enabled),
        store.setInt(_freqKey, prefs.frequencyMinutes),
        store.setBool(_newPostKey, prefs.newPostEnabled),
        store.setBool(_myPostKey, prefs.myPostEnabled),
      ]);
      return true;
    } catch (_) {
      return false;
    }
  }
}
