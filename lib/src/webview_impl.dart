import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'app_config.dart';
import 'data/embedded_fonts.dart';
import 'data/update_checker.dart';
import 'data/wp_auth.dart';
import 'shell/webview_ui_state.dart';

/// 整站 WebView 页（Android / iOS / macOS）。
///
/// 仅承载 WebView 本体与加载/错误浮层；AppBar、返回键等由 HomeShell 统一处理。
/// 内嵌 https://www.yibianhui.cn 整站，特性：
/// - 加载进度与错误页通过 [WebViewUiState] 上报给外壳
/// - 站外链接自动转交系统浏览器，站内链接留在应用内
/// - 页面加载完成后注入“性能模式”样式，关闭站点重特效提升旧设备滚动流畅度
/// - **网页字体本地化（T30）**：站点一次首页加载要拉 19.2 MB 中文字体；
///   打包进 APK 的字体以 `data:` URI 内联顶掉站点规则，页面一个字体请求都不发
/// - **登录态同步**：App 在「我的」页登录后，WebView 用内存中的最新凭据
///   自动完成 wp-login 表单登录（服务端只信任真实浏览器指纹的登录，
///   应用内 HttpClient 拿到的会话无效，故必须由 WebView 自身登录）；
///   退出登录时清空 WebView Cookie。
class BlogWebViewPage extends StatefulWidget {
  const BlogWebViewPage({super.key, required this.uiState, this.initialUrl});

  final WebViewUiState uiState;

  /// 起始地址；为空表示站点首页。首页「从这里开始」的直链会用这个参数
  /// 直接内嵌打开，而不是丢给系统浏览器。
  final String? initialUrl;

  @override
  State<BlogWebViewPage> createState() => BlogWebViewState();
}

class BlogWebViewState extends State<BlogWebViewPage> {
  /// 页面脚本：尽早注入（不等 `window.load`）。
  ///
  /// 两件事：
  /// 1. **性能模式样式**：站点主题自带动画/毛玻璃/固定背景/粒子 canvas，在旧设备
  ///    WebView 上掉帧明显。
  /// 2. **兜底移除站点载入遮罩 `#preload`**：站点首页要拉 20+ MB 中文字体，
  ///    `window.load` 在移动网络下可能几十秒甚至几分钟都不触发，而站点自己的遮罩
  ///    恰好挂在 `window.load` 上移除 —— 两者叠加就是「整站页一直转圈、不见内容」。
  ///
  /// 因此在导航早期（onPageStarted / 进度 10·35·65）和 onPageFinished 都注入一次，
  /// 靠 `window.__ybhPageScript` + 样式元素 id 双重去重，重复注入无副作用。
  static const String _pageScript = '''
(function () {
  if (window.__ybhPageScript) { return; }
  window.__ybhPageScript = true;

  // 诊断：把页面里的 JS 报错 / 资源加载失败回报给 App（每页最多 4 条）。
  // 站点在 WebView 里若因某处报错导致 app.js 未执行完，载入遮罩就不会被摘掉，
  // 没有这层回报只能靠猜。Dart 侧用 YbhDiag 通道接收，只打日志、不影响页面。
  function report(text) {
    try { if (window.YbhDiag) { window.YbhDiag.postMessage(String(text).slice(0, 300)); } } catch (e) {}
  }
  try {
    var budget = 4;
    function send(tag, text) { if (budget > 0) { budget--; report(tag + ' | ' + text); } }
    window.addEventListener('error', function (ev) {
      var t = ev && ev.target;
      if (t && t.tagName) {
        send('资源失败', t.tagName + ' ' + (t.currentSrc || t.src || t.href || ''));
      } else {
        send('JS错误', (ev && ev.message ? ev.message : 'unknown') +
          ' @ ' + (ev && ev.filename ? ev.filename : '') + ':' + (ev && ev.lineno ? ev.lineno : 0));
      }
    }, true);
    window.addEventListener('unhandledrejection', function (ev) {
      send('Promise拒绝', ev && ev.reason ? ev.reason : 'unknown');
    });
  } catch (e) {}

  function applyPerf() {
    try {
      if (document.getElementById('ybh-perf-style')) { return; }
      var css = [
        '*{-webkit-animation-duration:0s!important;animation-duration:0s!important;',
        '-webkit-animation-iteration-count:1!important;animation-iteration-count:1!important;',
        '-webkit-transition-duration:0s!important;transition-duration:0s!important;}',
        '*{background-attachment:scroll!important;}',
        '*{-webkit-backdrop-filter:none!important;backdrop-filter:none!important;}',
        '*{filter:none!important;}',
        'canvas{display:none!important;}',
        '[data-aos]{opacity:1!important;-webkit-transform:none!important;transform:none!important;}',
        'html,body{scroll-behavior:auto!important;}'
      ].join('\\n');
      var style = document.createElement('style');
      style.id = 'ybh-perf-style';
      style.appendChild(document.createTextNode(css));
      (document.head || document.documentElement).appendChild(style);
      if (window.AOS && typeof window.AOS.refreshHard === 'function') {
        try { window.AOS.refreshHard(); } catch (e) {}
      }
    } catch (e) {}
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', applyPerf);
  } else {
    applyPerf();
  }

  // 兜底：DOM 解析完成后，只要站点遮罩还在就淡出移除（最多盯 24 秒）。
  var ticks = 0;
  var timer = setInterval(function () {
    ticks++;
    if (document.readyState !== 'loading') {
      applyPerf();
      // 一次性盘点已加载失败（naturalWidth 为 0）的图片，方便定位站点侧破图。
      if (!window.__ybhImgChecked) {
        window.__ybhImgChecked = true;
        try {
          var bad = [];
          var imgs = document.images || [];
          for (var i = 0; i < imgs.length && bad.length < 3; i++) {
            if (imgs[i].complete && imgs[i].naturalWidth === 0) {
              bad.push(imgs[i].getAttribute('src') || '(空 src)');
            }
          }
          if (bad.length) { report('破图 | ' + bad.join(' ; ')); }
        } catch (e) {}
      }
      var mask = document.getElementById('preload');
      if (mask) {
        try {
          mask.style.setProperty('transition', 'opacity .25s linear');
          mask.style.setProperty('opacity', '0', 'important');
          mask.style.setProperty('pointer-events', 'none', 'important');
        } catch (e) {}
        setTimeout(function () { try { mask.remove(); } catch (e) {} }, 320);
      }
    }
    if (ticks > 60) { clearInterval(timer); }
  }, 400);
})();
''';

  /// 在登录页填表并提交的脚本。
  ///
  /// 凭据以 JSON 字符串嵌入（避免引号/反斜杠注入）。返回值为诊断用字符串：
  /// - `'ok'` 表单已提交；
  /// - `'no-form'` 页面上找不到密码输入框（可能是错误页/已登录的重定向页）；
  /// - `'no-user-field'` 表单里找不到用户名输入框。
  ///
  /// 站点主题（Sakurairo）可能用自己的登录表单而非标准 wp-login 结构，
  /// 因此这里不依赖 `#user_login` / `#loginform` 等固定 id，改为：
  /// 先定位密码框 → 取其所属 form → 在 form 内找用户名框（按常见 name/id 依次回退）。
  /// 提交时优先 `requestSubmit()`（会触发主题绑定的校验与 AJAX 逻辑），
  /// 失败再退回点击提交按钮、最后才是 `form.submit()`。
  static String _loginScript(String user, String pass) {
    final u = jsonEncode(user);
    final p = jsonEncode(pass);
    return '''
(function () {
  var u = $u, p = $p;
  var pass = document.querySelector('input[type="password"]');
  if (!pass) return 'no-form';
  var form = pass.form;
  if (!form) return 'no-form';
  var user = form.querySelector('input[name="log"]')
          || form.querySelector('#user_login')
          || form.querySelector('input[name="username"]')
          || form.querySelector('input[name="user_login"]')
          || form.querySelector('input[autocomplete="username"]')
          || form.querySelector('input[type="email"]')
          || form.querySelector('input[type="text"]');
  if (!user) return 'no-user-field';

  // 用原生 setter 赋值并派发事件，确保 Vue/React 等框架能感知到输入。
  function setVal(el, v) {
    var proto = el instanceof HTMLTextAreaElement
      ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    var desc = Object.getOwnPropertyDescriptor(proto, 'value');
    if (desc && desc.set) { desc.set.call(el, v); } else { el.value = v; }
    el.dispatchEvent(new Event('input', { bubbles: true }));
    el.dispatchEvent(new Event('change', { bubbles: true }));
  }
  setVal(user, u);
  setVal(pass, p);

  // 勾上「记住我」，让整站会话在下次冷启动仍然有效。
  var remember = form.querySelector('input[name="rememberme"]');
  if (remember && !remember.checked) {
    remember.checked = true;
    remember.dispatchEvent(new Event('change', { bubbles: true }));
  }

  var btn = form.querySelector('input[type="submit"]')
         || form.querySelector('button[type="submit"]')
         || form.querySelector('button');
  var fired = false;
  form.addEventListener('submit', function () { fired = true; });

  // requestSubmit 会走表单校验与主题绑定的 submit 处理器，是首选。
  if (typeof form.requestSubmit === 'function') {
    try { form.requestSubmit(btn || undefined); } catch (e) {}
  }
  // 若没触发 submit 事件（主题用 click 处理器），退回到点击按钮。
  if (!fired && btn) {
    try { btn.click(); } catch (e) {}
  }
  // 最后兜底：直接提交（不触发 submit 事件，但一定会导航）。
  if (!fired) {
    try { form.submit(); } catch (e) {}
  }
  return 'ok';
})();
''';
  }

  late final WebViewController _controller;
  bool _androidConfigured = false;

  /// 诊断日志前缀里的 App 版本号（T30：便于按版本区分线上问题）。
  String _appVersion = '?';

  /// 已应用的 WebView 底色是否为深色（跟随明暗主题，避免暗色下闪白）。
  bool? _darkBackground;

  /// 是否正在执行自动登录（页面完成回调里判断是否要填表提交）。
  bool _autoLogging = false;

  /// 自动登录成功后要回到的页面（登录前正在浏览的站内地址）。
  /// 为空表示回站点首页。
  String? _autoLoginReturnUrl;

  WebViewUiState get _ui => widget.uiState;

  @override
  void initState() {
    super.initState();
    // T30：先把打包字体读成 base64 并拼出替代 @font-face（异步、失败静默），
    // 再创建 WebView —— 首帧注入脚本时 webviewScript 已就绪。
    EmbeddedFonts.instance.prepare();
    UpdateChecker.currentVersion().then((v) {
      if (mounted) _appVersion = v;
    });
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'YbhDiag',
        onMessageReceived: (JavaScriptMessage message) {
          // 页面侧诊断回报（JS 报错 / 资源加载失败 / 字体本地化），仅出现问题时才有输出。
          debugPrint('[YBH WebView v$_appVersion] ${message.message}');
        },
      )
      ..setBackgroundColor(const Color(0xFFF5F6F8))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            _ui.progress.value = progress;
            // 关键进度点补注：越早解除站点载入遮罩，整站页越快见到内容。
            if (progress == 10 || progress == 35 || progress == 65) {
              _injectPageScript();
            }
          },
          onPageStarted: (String url) {
            _ui.currentUrl.value = url;
            _ui.loading.value = true;
            _ui.hasError.value = false;
            _injectPageScript();
          },
          onPageFinished: (String url) async {
            _ui.currentUrl.value = url;
            _ui.loading.value = false;
            await _refreshNavigationState();
            await _configureAndroidWebView();
            // 自动登录：登录页加载完成后立即填表提交。
            if (_autoLogging && url.contains('wp-login.php')) {
              _autoLogging = false;
              final creds = wpAuth.webLoginCredentials;
              if (creds != null) {
                try {
                  final result = await _controller.runJavaScriptReturningResult(
                    _loginScript(creds.$1, creds.$2),
                  );
                  // 页面不是登录表单（可能已登录被重定向，或主题换了结构）：
                  // 主动回到目标页面，避免停在无意义的中间页。
                  if (result is String && result.startsWith('no-')) {
                    final target = _autoLoginReturnUrl;
                    if (target != null && target.isNotEmpty) {
                      await _controller.loadRequest(Uri.parse(target));
                    }
                  }
                } catch (_) {
                  // 忽略：自动登录失败不阻塞用户手动登录。
                }
              }
              _autoLoginReturnUrl = null;
            }
            // 仅调试构建开启远程调试（CDP），便于真机验证登录态/渲染。
            if (kDebugMode) {
              try {
                await AndroidWebViewController.enableDebugging(true);
              } catch (_) {
                // 忽略：仅调试用途。
              }
            }
            // 性能模式 + 兜底移除站点载入遮罩（早期已注入，这里兜最后一刀）。
            _injectPageScript();
            // 字体本地化状态回报（打包文件数 / 内联 CSS 体量）。
            final fonts = EmbeddedFonts.instance;
            debugPrint('[YBH WebView v$_appVersion] 字体 | 打包 ${fonts.fileCount} 个，'
                '内联 CSS ${fonts.cssBytes} 字符，就绪=${fonts.isReady}');
          },
          onWebResourceError: (WebResourceError error) {
            // 只对主框架错误显示错误页，避免图片等子资源失败误报。
            if (!(error.isForMainFrame ?? true)) return;
            _ui.hasError.value = true;
            _ui.loading.value = false;
          },
          onNavigationRequest: (NavigationRequest request) {
            if (AppConfig.isInAppUrl(request.url)) {
              return NavigationDecision.navigate;
            }
            openInBrowser(request.url);
            return NavigationDecision.prevent;
          },
        ),
      );
    _controller.loadRequest(Uri.parse(widget.initialUrl ?? AppConfig.blogUrl));
    // App 登录/退出事件：登录 → WebView 自动登录；退出 → 清 Cookie。
    wpAuth.webLoginRequested.addListener(_onWebLoginRequested);
    // 冷启动时若 App 已登录但 WebView 尚无会话：尝试一次自动登录，
    // 保证「整站」与 App 登录态一致（WebView 自身会话在下次启动仍有效，
    // 此处仅兜底，不会重复登录）。
    if (wpAuth.isLoggedIn && wpAuth.webLoginCredentials != null) {
      _startAutoLogin();
    }
  }

  @override
  void dispose() {
    wpAuth.webLoginRequested.removeListener(_onWebLoginRequested);
    super.dispose();
  }

  void _onWebLoginRequested() {
    if (wpAuth.isLoggedIn && wpAuth.webLoginCredentials != null) {
      _startAutoLogin();
    } else {
      _clearSessionAndReload();
    }
  }

  /// 开始自动登录：导航到 wp-login.php，页面加载完自动填表提交。
  ///
  /// [returnTo] 指定登录成功后要回到的页面；不传则取当前正在浏览的页面，
  /// 这样「整站」登录后能回到原处而不是被踢回首页。
  void _startAutoLogin({String? returnTo}) {
    if (_autoLogging) return;
    _autoLogging = true;
    _ui.hasError.value = false;
    _autoLoginReturnUrl = _resolveReturnUrl(returnTo ?? _ui.currentUrl.value);
    _controller.loadRequest(
      Uri.parse(
        '${AppConfig.blogUrl}/wp-login.php'
        '?redirect_to=${Uri.encodeComponent(_autoLoginReturnUrl!)}',
      ),
    );
  }

  /// 决定登录成功后回到哪里。
  ///
  /// 仅接受站内地址；登录页自身、空地址、站外地址一律退回站点首页兜底，
  /// 避免把 `redirect_to` 指向登录页造成死循环。
  String _resolveReturnUrl(String? url) {
    const home = '${AppConfig.blogUrl}/';
    if (url == null || url.isEmpty) return home;
    if (url.contains('wp-login.php')) return home;
    if (!AppConfig.isInAppUrl(url)) return home;
    return url;
  }

  /// 退出登录：清空 WebView Cookie 并回到首页（整站随即呈未登录态）。
  Future<void> _clearSessionAndReload() async {
    try {
      await WebViewCookieManager().clearCookies();
    } catch (_) {
      // 清理失败不阻塞重载。
    }
    if (mounted) {
      await _controller.loadRequest(Uri.parse(AppConfig.blogUrl));
    }
  }

  Future<void> _refreshNavigationState() async {
    _ui.canGoBack.value = await _controller.canGoBack();
  }

  /// Android 专项调优：关闭滚动条与过度滚动光晕，减少滚动时系统额外绘制。
  /// 尽早注入页面脚本（性能样式 + 兜底移除站点载入遮罩）。
  ///
  /// 导航早期调用时目标文档可能还在切换，失败或被作用在旧文档上都没关系：
  /// 脚本自带去重，后续进度点与 onPageFinished 会再补一次。
  void _injectPageScript() {
    _controller.runJavaScript(_pageScript).catchError((Object _) {});
    _injectFontScript();
  }

  /// T30：注入「网页字体本地化」脚本（闸门 → 改写 CSSOM → 放开闸门）。
  ///
  /// 与 [_injectPageScript] 一样在导航早期与多个进度点重复注入；
  /// 脚本以 `window.__ybhFonts` 去重，重复调用只是再 kick 一次。
  void _injectFontScript() {
    final js = EmbeddedFonts.instance.webviewScript;
    if (js.isEmpty) return;   // 服务没起来（例如平台不支持）→ 退回站点原字体
    _controller.runJavaScript(js).catchError((Object _) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // WebView 自身底色：跟随明暗主题，避免暗色模式下页面加载瞬间闪白。
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (dark != _darkBackground) {
      _darkBackground = dark;
      _controller.setBackgroundColor(
        dark ? const Color(0xFF17191C) : const Color(0xFFF5F6F8),
      );
    }
  }

  Future<void> _configureAndroidWebView() async {
    if (_androidConfigured) return;
    _androidConfigured = true;
    final platform = _controller.platform;
    if (platform is! AndroidWebViewController) return;
    await platform.setOverScrollMode(WebViewOverScrollMode.never);
    await platform.setVerticalScrollBarEnabled(false);
    await platform.setHorizontalScrollBarEnabled(false);
  }

  Future<void> reload() async {
    _ui.hasError.value = false;
    _ui.loading.value = true;
    _ui.progress.value = 0;
    await _controller.reload();
  }

  Future<void> goHome() async {
    _ui.hasError.value = false;
    await _controller.loadRequest(Uri.parse(AppConfig.blogUrl));
  }

  /// 返回网页上一页；无可后退页面时返回 false，交由外壳处理。
  Future<bool> goBackIfPossible() async {
    if (_ui.hasError.value) {
      await reload();
      return true;
    }
    if (_ui.canGoBack.value) {
      await _controller.goBack();
      await _refreshNavigationState();
      return true;
    }
    return false;
  }

  Future<void> share() async {
    var url = _ui.currentUrl.value;
    try {
      final current = await _controller.currentUrl();
      if (current != null && current.isNotEmpty) url = current;
    } catch (_) {
      // 忽略：使用页面回调记录的地址。
    }
    await SharePlus.instance.share(
      ShareParams(
        text: '来自${AppConfig.appName}的分享：$url',
        uri: Uri.parse(url),
      ),
    );
  }

  Future<void> openInBrowser([String? url]) async {
    final uri = Uri.tryParse(url ?? _ui.currentUrl.value);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: WebViewWidget(controller: _controller),
        ),
        // 首屏加载动画（progress 仍为 0 且无错误时显示）。
        ListenableBuilder(
          listenable: _ui.merged,
          builder: (context, child) {
            final showSplash =
                _ui.loading.value && _ui.progress.value == 0 && !_ui.hasError.value;
            if (!showSplash) return const SizedBox.shrink();
            return Positioned.fill(
              child: ColoredBox(
                color: colorScheme.surface,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 36,
                        height: 36,
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        '正在加载 ${AppConfig.appName}…',
                        style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        // 主框架加载失败错误页。
        ListenableBuilder(
          listenable: _ui.hasError,
          builder: (context, child) {
            if (!_ui.hasError.value) return const SizedBox.shrink();
            return Positioned.fill(
              child: _ErrorView(
                onRetry: reload,
                onOpenBrowser: openInBrowser,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.onRetry, required this.onOpenBrowser});

  final VoidCallback onRetry;
  final VoidCallback onOpenBrowser;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.wifi_off_rounded,
                size: 72,
                color: colorScheme.primary.withValues(alpha: 0.7),
              ),
              const SizedBox(height: 20),
              const Text(
                '页面加载失败',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 10),
              Text(
                '请检查网络连接后重试。',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重新加载'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onOpenBrowser,
                icon: const Icon(Icons.open_in_browser_outlined),
                label: const Text('用系统浏览器打开'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}