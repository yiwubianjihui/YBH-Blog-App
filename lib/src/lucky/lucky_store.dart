import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'lucky_demo_data.dart';
import 'lucky_models.dart';

/// 摇人器的本地存储：名单、偏好、抽选记录。
///
/// 名单默认落在 SharedPreferences；真实名单**不会**写入版本库
/// （仓库里只有 [luckyDemoRoster] 这份虚构示例数据）。
abstract final class LuckyStore {
  static const String _rosterKey = 'ybh_lucky_roster';
  static const String _settingsKey = 'ybh_lucky_settings';
  static const String _historyKey = 'ybh_lucky_history';
  static const String _usedKey = 'ybh_lucky_used';

  /// 抽选记录最多保留的条数。
  static const int historyLimit = 300;

  static Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 名单

  /// 读取名单；没有存过则返回内置示例名单。
  static Future<LuckyRoster> loadRoster() async {
    final prefs = await _prefs();
    final raw = prefs?.getString(_rosterKey);
    if (raw == null || raw.isEmpty) return luckyDemoRoster;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return luckyDemoRoster;
      return LuckyRoster.fromJson(decoded);
    } catch (_) {
      return luckyDemoRoster;
    }
  }

  /// 保存名单（覆盖式的，不做合并）。
  static Future<bool> saveRoster(LuckyRoster roster) async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.setString(_rosterKey, jsonEncode(roster.toJson()));
    } catch (_) {
      return false;
    }
  }

  /// 恢复内置示例名单。
  static Future<bool> resetToDemo() async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.remove(_rosterKey);
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 偏好

  static Future<LuckySettings> loadSettings() async {
    final prefs = await _prefs();
    final raw = prefs?.getString(_settingsKey);
    if (raw == null || raw.isEmpty) return const LuckySettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const LuckySettings();
      return LuckySettings.fromJson(decoded);
    } catch (_) {
      return const LuckySettings();
    }
  }

  static Future<bool> saveSettings(LuckySettings settings) async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    } catch (_) {
      return false;
    }
  }

  // -------------------------------------------------------- 不重复池状态

  /// 读取「本轮已抽中」的姓名集合。
  static Future<Set<String>> loadUsed() async {
    final prefs = await _prefs();
    final raw = prefs?.getStringList(_usedKey);
    return raw?.toSet() ?? <String>{};
  }

  static Future<bool> saveUsed(Set<String> used) async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.setStringList(_usedKey, used.toList());
    } catch (_) {
      return false;
    }
  }

  static Future<bool> clearUsed() async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.remove(_usedKey);
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------- 记录

  static Future<List<LuckyPickRecord>> loadHistory() async {
    final prefs = await _prefs();
    final raw = prefs?.getString(_historyKey);
    if (raw == null || raw.isEmpty) return const <LuckyPickRecord>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <LuckyPickRecord>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(LuckyPickRecord.fromJson)
          .toList();
    } catch (_) {
      return const <LuckyPickRecord>[];
    }
  }

  /// 追加一条记录（最新的在前，超出上限自动丢弃最旧的）。
  static Future<bool> appendHistory(LuckyPickRecord record) async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      final list = await loadHistory();
      final next = <LuckyPickRecord>[record, ...list];
      if (next.length > historyLimit) {
        next.removeRange(historyLimit, next.length);
      }
      return await prefs.setString(
          _historyKey, jsonEncode(next.map((r) => r.toJson()).toList()));
    } catch (_) {
      return false;
    }
  }

  static Future<bool> clearHistory() async {
    final prefs = await _prefs();
    if (prefs == null) return false;
    try {
      return await prefs.remove(_historyKey);
    } catch (_) {
      return false;
    }
  }
}

/// 摇人器的界面偏好。
class LuckySettings {
  const LuckySettings({
    this.classId = '',
    this.gender = LuckyGenderFilter.all,
    this.noRepeat = true,
    this.ttsEnabled = true,
    this.multiCount = 5,
  });

  /// 上次选择的班级号；空表示全部班级。
  final String classId;

  final LuckyGenderFilter gender;

  /// 不重复模式。
  final bool noRepeat;

  /// 是否语音播报结果。
  final bool ttsEnabled;

  /// 「连抽」一次抽几个人。
  final int multiCount;

  LuckySettings copyWith({
    String? classId,
    LuckyGenderFilter? gender,
    bool? noRepeat,
    bool? ttsEnabled,
    int? multiCount,
  }) =>
      LuckySettings(
        classId: classId ?? this.classId,
        gender: gender ?? this.gender,
        noRepeat: noRepeat ?? this.noRepeat,
        ttsEnabled: ttsEnabled ?? this.ttsEnabled,
        multiCount: multiCount ?? this.multiCount,
      );

  Map<String, dynamic> toJson() => {
        'classId': classId,
        'gender': gender.name,
        'noRepeat': noRepeat,
        'ttsEnabled': ttsEnabled,
        'multiCount': multiCount,
      };

  factory LuckySettings.fromJson(Map<String, dynamic> json) => LuckySettings(
        classId: json['classId'] as String? ?? '',
        gender: LuckyGenderFilter.values.firstWhere(
          (e) => e.name == json['gender'],
          orElse: () => LuckyGenderFilter.all,
        ),
        noRepeat: json['noRepeat'] as bool? ?? true,
        ttsEnabled: json['ttsEnabled'] as bool? ?? true,
        multiCount: json['multiCount'] as int? ?? 5,
      );
}
