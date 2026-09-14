import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 从系统相册/文件选择的一张图片。
@immutable
class PickedImage {
  const PickedImage({required this.bytes, required this.name});

  final Uint8List bytes;
  final String name;

  int get length => bytes.length;
}

/// 系统图片选择器（Android 原生 `ACTION_GET_CONTENT`）。
///
/// 为什么不用 `image_picker` 插件：本项目当前的构建环境无法新增 pub 依赖
/// （沙箱 DNS 不通、`pub get` 拉不到新包）。原生实现只有一个 MethodChannel，
/// 与既有的 `power_guard` 同一套写法，零依赖、零权限（GET_CONTENT 不需要
/// 读存储权限）。
///
/// 非 Android 平台 / 通道不可用时返回 null，调用方退回「手动填写图片地址」。
class MediaPicker {
  MediaPicker._();

  static const MethodChannel _channel =
      MethodChannel('cn.yibianhui.blog/picker');

  /// 是否可用（通道存在）。首次调用后缓存结果。
  static bool? _available;
  static bool get isSupported => _available ?? false;

  /// 打开系统图片选择器；用户取消或平台不支持时返回 null。
  static Future<PickedImage?> pickImage() async {
    try {
      final raw = await _channel.invokeMethod<Object?>('pickImage');
      _available = true;
      if (raw is! Map) return null;
      final bytes = raw['bytes'];
      final name = raw['name'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      return PickedImage(
        bytes: bytes,
        name: (name is String && name.trim().isNotEmpty)
            ? name.trim()
            : 'upload-${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
    } on MissingPluginException {
      _available = false;
      return null;
    } catch (e) {
      debugPrint('[MediaPicker] 选择失败: $e');
      return null;
    }
  }
}
