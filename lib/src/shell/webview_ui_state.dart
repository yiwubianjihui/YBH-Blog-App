import 'package:flutter/foundation.dart';

import '../app_config.dart';

/// 外壳与 WebView 页共享的 UI 状态（加载进度、导航能力、当前地址等），
/// 由 HomeShell 持有并监听，用于构建 AppBar 进度条与操作按钮。
class WebViewUiState {
  final ValueNotifier<int> progress = ValueNotifier<int>(0);
  final ValueNotifier<bool> loading = ValueNotifier<bool>(true);
  final ValueNotifier<bool> hasError = ValueNotifier<bool>(false);
  final ValueNotifier<bool> canGoBack = ValueNotifier<bool>(false);
  final ValueNotifier<String> currentUrl = ValueNotifier<String>(AppConfig.blogUrl);

  /// 「这一页在应用内显示不出来」时承载它的地址；非空即在 WebView 上盖一层落地卡。
  ///
  /// 为什么要有它：teacher / brs 这类独立子站在应用内 WebView 里整页白屏
  /// （探针显示 DOM 为空、JS 没执行），**系统浏览器里完全正常**。
  /// 旧做法是探到空页就**直接把用户踢到系统浏览器** —— 人还没反应过来就离开了 App，
  /// 观感很差。现在改成：留在应用内，给一张说得清楚的落地卡
  /// （站点名 + 一句说明 + 「在浏览器中打开」+「复制链接」+「重试」），
  /// 由用户自己决定走不走。
  final ValueNotifier<String> browserFallbackUrl = ValueNotifier<String>('');

  Listenable get merged => Listenable.merge(
      [progress, loading, hasError, canGoBack, currentUrl, browserFallbackUrl]);

  void dispose() {
    progress.dispose();
    loading.dispose();
    hasError.dispose();
    canGoBack.dispose();
    currentUrl.dispose();
    browserFallbackUrl.dispose();
  }
}
