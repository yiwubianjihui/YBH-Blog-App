import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 摇人结果的语音播报。
///
/// 移动端直接调用系统 TTS 引擎（flutter_tts），优先选中文女声；
/// 桌面端（Windows / Linux / macOS）flutter_tts 同样走系统语音。
/// 若系统没有中文语音，会退回默认语音，不抛异常——播报失败不该影响摇人。
class LuckyTts {
  LuckyTts._();

  static final LuckyTts instance = LuckyTts._();

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;

  /// 播报是否可用（初始化失败 / 无语音时为 false）。
  bool available = false;

  /// 当前选中的语音名称（仅用于界面显示）。
  String? voiceName;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(0.46);
      await _tts.setPitch(1.05);
      await _tts.setVolume(1.0);
      await _selectChineseVoice();
      available = true;
    } catch (e) {
      debugPrint('[lucky_tts] 初始化失败: $e');
      available = false;
    }
  }

  /// 在可用语音里挑一个中文普通话的，挑不到就用系统默认。
  Future<void> _selectChineseVoice() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is! List || voices.isEmpty) return;
      final candidates = voices.whereType<Map<Object?, Object?>>().map((v) {
        return <String, String>{
          'name': (v['name'] ?? '').toString(),
          'locale': (v['locale'] ?? '').toString(),
        };
      }).toList();

      String? pick;
      for (final v in candidates) {
        final locale = v['locale']!.toLowerCase().replaceAll('_', '-');
        if (locale.startsWith('zh') || locale.startsWith('cmn')) {
          pick = v['name'];
          // 优先女声，其次任意中文声
          final name = v['name']!.toLowerCase();
          if (name.contains('female') ||
              name.contains('xiaoxiao') ||
              name.contains('yaoyao') ||
              name.contains('huihui') ||
              name.contains('女')) {
            break;
          }
        }
      }
      if (pick != null && pick.isNotEmpty) {
        await _tts.setVoice({'name': pick, 'locale': 'zh-CN'});
        voiceName = pick;
      }
    } catch (e) {
      debugPrint('[lucky_tts] 语音选择失败: $e');
    }
  }

  /// 播报一段文字；失败时静默忽略。
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    if (!_initialized) await init();
    if (!available) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('[lucky_tts] 播报失败: $e');
    }
  }

  /// 播报抽中结果：一个人直接念名字，多人念「张三、李四、王五」。
  Future<void> speakResult(List<String> names) async {
    if (names.isEmpty) return;
    await speak(names.join('、'));
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {
      // 忽略
    }
  }

  /// 桌面端（非 Android/iOS/Web）flutter_tts 支持有限，这里给出提示文案。
  bool get isWellSupported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);
}
