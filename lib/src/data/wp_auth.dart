import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import '../data/blog_api.dart';

/// 全局单例引用，方便外壳与页面共享登录态。
final WpAuth wpAuth = WpAuth.instance;

/// 登录后的 WordPress 用户（来自 /wp-json/wp/v2/users/me）。
class WpUser {
  const WpUser({
    required this.id,
    required this.login,
    this.displayName,
    this.nickname,
    this.email,
    this.avatarUrl,
    this.roles = const <String>[],
    this.capabilities = const <String>{},
    /// 是否成功读取到能力列表；为 false 时 [canPublish] 只是乐观猜测。
    this.capabilitiesKnown = false,
  });

  final int id;
  final String login;
  final String? displayName;
  final String? nickname;
  final String? email;
  final String? avatarUrl;

  /// 站点角色（如 administrator / editor / author / contributor / subscriber）。
  final List<String> roles;

  /// 能力集合（来自 `GET /users/me?context=edit` 的 `capabilities`）。
  final Set<String> capabilities;

  /// 是否真的读到了能力集合。
  final bool capabilitiesKnown;

  String get name => (displayName ?? nickname ?? login).trim().isEmpty
      ? login
      : (displayName ?? nickname ?? login);

  /// 是否可以直接发布（对应 WordPress 的 `publish_posts` 能力）。
  ///
  /// 「作者 / 编辑 / 管理员」为 true；「投稿者（contributor）」为 false，
  /// 其投稿只能进入「待审核」。读不到能力时乐观返回 true（由服务端错误兜底）。
  bool get canPublish =>
      !capabilitiesKnown || capabilities.contains('publish_posts');

  /// 角色中文名，用于界面提示。
  String get roleLabel => switch (roles.isEmpty ? '' : roles.first) {
        'administrator' => '管理员',
        'editor' => '编辑',
        'author' => '作者',
        'contributor' => '投稿者',
        'subscriber' => '订阅者',
        String r when r.isNotEmpty => r,
        _ => '',
      };

  factory WpUser.fromJson(Map<String, dynamic> json) {
    final avatars = json['avatar_urls'];
    final String? avatar = avatars is Map ? (avatars['96'] as String?) : null;
    final caps = json['capabilities'];
    final Set<String>? capSet = caps is Map
        ? caps.entries
            .where((e) => e.value == true)
            .map((e) => '${e.key}')
            .toSet()
        : null;
    final rolesRaw = json['roles'];
    return WpUser(
      id: (json['id'] as num?)?.toInt() ?? 0,
      login: (json['slug'] as String?) ?? (json['username'] as String?) ?? '',
      displayName: _clean(json['name']),
      nickname: _clean(json['nickname']),
      email: _clean(json['email']),
      avatarUrl: avatar,
      roles: rolesRaw is List
          ? rolesRaw.map((e) => '$e').toList(growable: false)
          : const <String>[],
      capabilities: capSet ?? const <String>{},
      capabilitiesKnown: capSet != null,
    );
  }

  /// 仅从 JWT 令牌响应（无 id / 头像）构造的最小用户，用于兜底展示。
  factory WpUser.fromJwt({
    required String displayName,
    String? email,
    String? nicename,
  }) {
    return WpUser(
      id: 0,
      login: (nicename ?? displayName).trim(),
      displayName: displayName.trim().isEmpty ? nicename : displayName,
      email: email,
    );
  }

  static String? _clean(Object? v) =>
      v is String ? v.trim() : null;
}

/// 投稿 / 发布的返回结果。
class PublishResult {
  const PublishResult._({
    required this.ok,
    required this.status,
    this.link,
    this.message,
    this.statusCode,
    this.downgraded = false,
  });

  /// 成功（HTTP 200/201）。
  const PublishResult.success({required this.status, required this.link})
      : ok = true,
        message = null,
        statusCode = null,
        downgraded = false;

  /// 失败：[message] 为面向用户的说明，含服务端返回的原始原因。
  const PublishResult.failure(this.message, {this.statusCode})
      : ok = false,
        status = '',
        link = null,
        downgraded = false;

  final bool ok;

  /// 文章最终状态：'publish' / 'draft' / 'pending'。
  final String status;

  /// 文章链接。
  final String? link;

  /// 失败原因（成功时为 null）。
  final String? message;

  final int? statusCode;

  /// 是否由「直接发布」自动降级成了「待审核」。
  final bool downgraded;

  /// 给用户看的结果提示语。
  String get notice => switch (status) {
        'pending' => '已提交审核，管理员通过后即可公开显示',
        'draft' => '已保存为草稿，可在后台继续编辑',
        'future' => '已设置为定时发布',
        _ => '已发布',
      };

  PublishResult copyWithDowngraded() => PublishResult._(
        ok: ok,
        status: status,
        link: link,
        message: message,
        statusCode: statusCode,
        downgraded: true,
      );
}

/// 鉴权方式。
enum WpAuthMethod {
  /// JWT 插件令牌（Bearer），本站已安装并配置。
  jwt,

  /// WordPress 核心「应用密码」（Basic Auth），无需插件。
  basic,
}

/// 登录失败的原因分类。
///
/// 以前 `_loginJwt` 遇到任何非 200 都 `return null`，UI 只能笼统提示
/// 「登录失败，请检查用户名与应用密码」——用户无法判断到底该改密码、
/// 该换网络，还是站点自己坏了。现在把服务端返回的 `code` / `message`
/// 解析出来，归到下面这几类，供 UI 给出可执行的提示。
enum WpLoginFailure {
  /// 网络不可达 / 超时 / TLS 握手失败（请求没到达服务端）。
  network,

  /// 用户名或密码不正确（服务端明确判定）。
  invalidCredentials,

  /// 服务端限制：人机验证码、防火墙 / 风控、频率限制、403 拒绝等。
  serverRestricted,

  /// 同一来源短时间内失败次数过多，被站点的登录闸门临时拒绝。
  /// （站点 `wp-content/mu-plugins/ybh-audit.php` L754-776 的
  /// `ybh_audit_gate_login`：10 分钟窗口内同一 IP 失败 ≥10 次就拒绝登录，
  /// 返回 `ybh_login_throttled`。**这段时间内换正确密码同样登不进**，
  /// 用户必须等窗口过去 —— 所以要和「密码错」区分开，否则用户会一直重试、
  /// 把闸门越推越远。）
  loginThrottled,

  /// 服务端 5xx 或返回了无法解析的内容。
  serverError,

  /// 其它未归类的情况。
  unknown,
}

/// [WpAuth.login] 的结果：是否成功，以及失败时可直接展示给用户的原因。
class WpLoginResult {
  const WpLoginResult.success(
    this.method, {
    this.recoveredByFallback = false,
  })  : ok = true,
        failure = null,
        userMessage = null,
        serverCode = null,
        statusCode = null;

  const WpLoginResult.failure({
    required this.failure,
    required this.userMessage,
    this.serverCode,
    this.statusCode,
    this.recoveredByFallback = false,
  })  : ok = false,
        method = null;

  /// 是否登录成功。
  final bool ok;

  /// 成功时使用的鉴权方式。
  final WpAuthMethod? method;

  /// 失败原因分类（成功时为 null）。
  final WpLoginFailure? failure;

  /// 面向用户的中文失败说明（已去掉 HTML 标签）。
  final String? userMessage;

  /// 服务端返回的原始错误 code，如 `[jwt_auth] invalid_username`。
  final String? serverCode;

  /// 服务端返回的 HTTP 状态码。
  final int? statusCode;

  /// 是否因为命中站点的「验证码吞错误」缺陷，自动改走表单编码重试才成功。
  final bool recoveredByFallback;
}

/// 一次鉴权尝试的中间结果（内部使用）。
class _LoginAttempt {
  _LoginAttempt({
    this.token,
    this.user,
    this.failure,
    this.message,
    this.code,
    this.statusCode,
    this.method,
  });

  /// 成功时使用的鉴权方式。
  final WpAuthMethod? method;

  /// 成功时的凭据（JWT 令牌或 Basic base64）。
  final String? token;

  /// 成功时解析到的用户；可能为空（令牌拿到了但资料没拉全）。
  WpUser? user;

  final WpLoginFailure? failure;

  /// 面向用户的失败说明（已去 HTML）。
  final String? message;

  /// 服务端原始错误 code。
  final String? code;

  final int? statusCode;

  /// 是否为「先失败、改走表单编码后成功」的自动恢复。
  bool recoveredByFallback = false;

  bool get ok => token != null;

  /// 是否命中站点主题验证码钩子的「空错误」指纹。
  ///
  /// 站点主题在 `authenticate` 过滤器上注册了 `CAPTCHA_CHECK`，其
  /// `empty($_POST)` 分支会 `return new WP_Error()` —— 一个既没有 code、
  /// 也没有 message 的空错误。该空错误会覆盖认证链上所有真实结果
  /// （连「密码正确」都会被吞掉）。jwt-auth 插件随后把它拼成
  /// `{"code":"[jwt_auth] ","message":"","data":{"status":403}}`。
  ///
  /// 原生 App 发送 JSON body 时 PHP 永远填不进 `$_POST`，因此**每次**
  /// 登录都会稳定命中。发现这个指纹就改用表单编码 + 主题提供的
  /// `skip_captcha_check=1` 放行位重试。
  bool get looksLikeEmptyErrorFingerprint {
    if (ok) return false;
    if (statusCode != 403) return false;
    final stripped = (code ?? '').replaceAll('[jwt_auth]', '').trim();
    final msg = message?.trim() ?? '';
    return stripped.isEmpty && msg.isEmpty;
  }
}

/// WordPress 账号鉴权。
///
/// 登录优先级：
/// 1. **JWT**（默认，最友好）：用「用户名 + 账号密码」向 jwt-auth 令牌接口换取
///    Bearer 令牌，再用该令牌请求 /users/me 拿到用户资料。
/// 2. **应用密码（Basic Auth）兜底**：若 JWT 接口不可用（插件未装 / 未配置），
///    退回到 WordPress 核心自带的应用密码方式（用户名 + 应用密码）。
///
/// 【整站登录态同步】实测发现本站服务端只信任「真实浏览器指纹」的
/// wp-login PHP 会话：应用内 dart HttpClient 提交的登录虽然会收到
/// 302 + Set-Cookie，但服务端不会落库会话，拿到的是无效凭据。
/// 因此 App 登录成功后，由「整站」WebView 用 [webLoginCredentials]
/// （仅内存暂存、绝不持久化的最近一次登录凭据）在 WebView 内完成
/// 真实表单登录；退出登录时清除凭据并清空 WebView Cookie。
class WpAuth {
  WpAuth._();

  /// 全局单例，供外壳与各个页面共享登录态。
  static final WpAuth instance = WpAuth._();

  static const String _tokenKey = 'ybh_wp_token';
  static const String _userKey = 'ybh_wp_user';
  static const String _methodKey = 'ybh_wp_method';
  static const Duration _timeout = Duration(seconds: 25);

  String? _token;
  WpUser? _user;
  WpAuthMethod _method = WpAuthMethod.basic;

  /// 最近一次成功登录的凭据（仅内存，供「整站」WebView 自动登录）。
  (String, String)? _webLoginCredentials;

  /// App 内登录/退出事件通知（「整站」WebView 监听后执行
  /// 自动登录 / 清理会话）。
  final ValueNotifier<int> webLoginRequested = ValueNotifier<int>(0);

  /// 供「整站」WebView 自动登录使用的凭据；退出登录后为 null。
  (String, String)? get webLoginCredentials => _webLoginCredentials;

  /// 原始凭据（JWT 时为 Bearer 令牌，Basic 时为 base64 凭据）。
  String? get token => _token;

  /// 当前鉴权方式。
  WpAuthMethod get method => _method;

  /// 当前登录用户；未登录为 null。
  WpUser? get user => _user;

  bool get isLoggedIn => _token != null && _token!.isNotEmpty;

  /// 写操作所需的请求头；未登录返回空，调用方应先判断 [isLoggedIn]。
  Map<String, String> get authHeaders {
    if (_token == null) return const {};
    return switch (_method) {
      WpAuthMethod.jwt => {'Authorization': 'Bearer $_token'},
      WpAuthMethod.basic => {'Authorization': 'Basic $_token'},
    };
  }

  /// 从本地存储恢复登录态（应用启动时调用一次）。
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _token = prefs.getString(_tokenKey);
      final rawMethod = prefs.getString(_methodKey);
      _method = rawMethod == 'jwt' ? WpAuthMethod.jwt : WpAuthMethod.basic;
      final raw = prefs.getString(_userKey);
      if (raw != null) {
        _user = WpUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {
      // 忽略：当作未登录。
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    if (_token == null) {
      await prefs.remove(_tokenKey);
      await prefs.remove(_userKey);
      await prefs.remove(_methodKey);
      await prefs.remove('ybh_wp_cookies');
    } else {
      await prefs.setString(_tokenKey, _token!);
      await prefs.setString(_userKey, jsonEncode(_user!.toJson()));
      await prefs.setString(
        _methodKey,
        _method == WpAuthMethod.jwt ? 'jwt' : 'basic',
      );
    }
  }

  /// 用「用户名 + 密码」登录。
  ///
  /// 优先尝试 JWT（账号密码），失败则回退到应用密码（Basic Auth）。
  /// 登录成功后凭据暂存于内存（[webLoginCredentials]），供「整站」
  /// WebView 自动登录；同时通知 [webLoginRequested]。
  ///
  /// 返回 [WpLoginResult]：成功时带鉴权方式，失败时带**可展示的具体原因**
  /// （网络 / 账号密码错 / 站点限制 / 服务端故障），不再像以前那样把
  /// 服务端返回的 code 与 message 全部丢掉。
  Future<WpLoginResult> login(String username, String password) async {
    final user = username.trim();
    final pass = password.replaceAll(' ', '');
    if (user.isEmpty || pass.isEmpty) {
      return const WpLoginResult.failure(
        failure: WpLoginFailure.invalidCredentials,
        userMessage: '请输入用户名和密码',
      );
    }

    // 1) JWT 优先。
    final jwtAttempt = await _loginJwt(user, pass);
    final _LoginAttempt chosen;
    if (jwtAttempt.ok) {
      chosen = jwtAttempt;
    } else {
      // 2) 应用密码兜底。JWT 失败的真实原因比 Basic 的更具体
      //    （Basic 只会说 401），所以失败时优先展示 JWT 那次的原因。
      final basicAttempt = await _loginBasic(user, pass);
      if (basicAttempt.ok) {
        chosen = basicAttempt;
      } else {
        if (kDebugMode) {
          debugPrint('[wp_auth] 登录失败：'
              'jwt(${jwtAttempt.statusCode}/${jwtAttempt.code}) '
              'basic(${basicAttempt.statusCode}/${basicAttempt.code})');
        }
        return _pickFailure(jwtAttempt, basicAttempt);
      }
    }

    _method = chosen.method ?? WpAuthMethod.basic;
    _token = chosen.token;
    _user = chosen.user ??
        WpUser.fromJwt(displayName: user, nicename: user);
    _webLoginCredentials = (user, pass);
    webLoginRequested.value++;

    await _persist();
    return WpLoginResult.success(
      _method,
      recoveredByFallback: chosen.recoveredByFallback,
    );
  }

  /// 两次尝试都失败时，挑一条对用户最有用的原因。
  ///
  /// 按「信息量」排序取更具体的一侧。顺序不是随便定的：
  /// 1. [WpLoginFailure.loginThrottled] —— 意味着「此刻换任何密码都没用」，
  ///    误报成密码错会让用户一直重试、把限流窗口不断续期；
  /// 2. [WpLoginFailure.invalidCredentials] —— 明确该改密码/账号；
  /// 3. [WpLoginFailure.serverRestricted] —— 站点把真实原因吞了（本 bug 的指纹）；
  /// 4. [WpLoginFailure.serverError] / [WpLoginFailure.network]；
  /// 5. [WpLoginFailure.unknown]。
  ///
  /// 曾经的实现只用 `failure != serverRestricted` 判断「JWT 是否更具体」，
  /// 结果 JWT 侧拿到根因 403（空错误指纹）、Basic 侧恰好 502 时，
  /// 会把 502 当成结论展示给用户 —— 掩盖了真正的登录故障。真机联调时实际撞到。
  WpLoginResult _pickFailure(_LoginAttempt jwt, _LoginAttempt basic) {
    int rank(WpLoginFailure? f) => switch (f) {
          WpLoginFailure.loginThrottled => 0,
          WpLoginFailure.invalidCredentials => 1,
          WpLoginFailure.serverRestricted => 2,
          WpLoginFailure.serverError => 3,
          WpLoginFailure.network => 4,
          WpLoginFailure.unknown || null => 5,
        };

    // 只有真的发出过请求（statusCode 非空）的那一侧才算数。
    final jwtRank = jwt.statusCode == null ? 99 : rank(jwt.failure);
    final basicRank = basic.statusCode == null ? 99 : rank(basic.failure);
    final src = jwtRank <= basicRank ? jwt : basic;

    return WpLoginResult.failure(
      failure: src.failure ?? WpLoginFailure.unknown,
      userMessage: src.message ?? '登录失败，请稍后重试',
      serverCode: src.code,
      statusCode: src.statusCode,
    );
  }

  /// 用已拿到的 Authorization 头拉取自己的资料。
  ///
  /// 优先请求 `?context=edit`——只有它才会返回 `roles` 与 `capabilities`，
  /// 用于判断「投稿者是否能直接发布」。若站点安全插件屏蔽了该 context，
  /// 退回普通请求（此时拿不到能力，[WpUser.canPublish] 乐观视为可发布，
  /// 由发布接口的服务端错误兜底）。
  Future<WpUser?> _fetchMe(String authorization) async {
    for (final withEdit in <bool>[true, false]) {
      final uri = Uri.parse('${AppConfig.apiBase}/users/me').replace(
        queryParameters: withEdit ? {'context': 'edit'} : null,
      );
      try {
        final response = await http
            .get(uri, headers: {'Authorization': authorization})
            .timeout(_timeout);
        if (response.statusCode != 200) continue;
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! Map<String, dynamic>) continue;
        final me = WpUser.fromJson(decoded);
        if (!withEdit || me.capabilitiesKnown) return me;
        // context=edit 通了但没返回能力字段，继续尝试普通请求拿别的兜底。
      } catch (_) {
        // 网络异常：尝试下一种。
      }
    }
    return null;
  }

  /// JWT 登录：换取令牌并拉取用户资料。
  ///
  /// 两步走：
  /// 1. 先按 WordPress REST 惯例发 JSON body（`Content-Type: application/json`）。
  /// 2. 若服务端返回的是「空错误」指纹（见
  ///    [_LoginAttempt.looksLikeEmptyErrorFingerprint]），说明请求撞上了站点
  ///    主题的验证码钩子，改用表单编码 + `skip_captcha_check=1` 重试。
  ///
  /// 第 2 步是**不依赖服务端修复**的自愈路径：站点主题
  /// `SakurairoYBH/functions.php` 的 `CAPTCHA_CHECK` 在 `$_POST` 为空时
  /// `return new WP_Error();`，把认证结果整条吞成空错误；而 PHP 不会把
  /// JSON body 填进 `$_POST`，所以 JSON 请求每次必中。主题同时提供了
  /// `skip_captcha_check=1` 的放行口（同一文件 L3260-L3262）。
  Future<_LoginAttempt> _loginJwt(String user, String pass) async {
    // 第 1 次：标准 JSON 请求（服务端修好后这条路就是最优路径）。
    final jsonAttempt = await _postToken(
      body: jsonEncode({'username': user, 'password': pass}),
      contentType: 'application/json',
    );
    if (jsonAttempt.ok) return jsonAttempt;
    if (!jsonAttempt.looksLikeEmptyErrorFingerprint) return jsonAttempt;

    if (kDebugMode) {
      debugPrint('[wp_auth] 命中服务端验证码钩子的空错误指纹，'
          '改用表单编码 + skip_captcha_check=1 重试');
    }

    // 第 2 次：表单编码（PHP 会填 $_POST）+ 主题的验证码放行位。
    final formAttempt = await _postToken(
      body: 'username=${Uri.encodeQueryComponent(user)}'
          '&password=${Uri.encodeQueryComponent(pass)}'
          '&skip_captcha_check=1',
      contentType: 'application/x-www-form-urlencoded',
    );
    formAttempt.recoveredByFallback = formAttempt.ok;
    if (formAttempt.ok || formAttempt.looksLikeEmptyErrorFingerprint) {
      return formAttempt;
    }
    // 表单重试拿到了更具体的原因，优先返回它。
    return formAttempt;
  }

  /// 向 JWT 令牌端点发一次 POST，并把结果解析成 [_LoginAttempt]。
  Future<_LoginAttempt> _postToken({
    required String body,
    required String contentType,
  }) async {
    final http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(AppConfig.jwtTokenUrl),
            headers: {'Content-Type': contentType},
            body: body,
          )
          .timeout(_timeout);
    } catch (e) {
      if (kDebugMode) debugPrint('[wp_auth] JWT 请求异常: $e');
      return _LoginAttempt(
        failure: WpLoginFailure.network,
        message: '无法连接服务器，请检查网络后重试',
        statusCode: 0,
      );
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(resp.bodyBytes, allowMalformed: true));
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON 响应（例如被 WAF 拦截返回 HTML）：保留原始状态码。
    }

    if (kDebugMode) {
      debugPrint('[wp_auth] JWT 状态码: ${resp.statusCode}');
    }

    if (resp.statusCode == 200) {
      final token = _asString(json?['token']);
      if (token == null || token.isEmpty) {
        return _LoginAttempt(
          failure: WpLoginFailure.serverError,
          message: '服务器返回的登录凭据为空，请稍后重试',
          statusCode: resp.statusCode,
        );
      }
      final me = await _fetchMe('Bearer $token');
      final display = _asString(json?['user_display_name']) ??
          _asString(json?['user_nicename']) ??
          '';
      final attempt = _LoginAttempt(
        token: token,
        user: me ??
            WpUser.fromJwt(
              displayName: display.isEmpty ? '已登录用户' : display,
              email: _asString(json?['user_email']),
              nicename: _asString(json?['user_nicename']),
            ),
        method: WpAuthMethod.jwt,
        statusCode: resp.statusCode,
      );
      if (me == null) {
        // 令牌拿到了但 /users/me 没通：账号是有效的，算登录成功
        // （写操作会再各自校验），只是资料不全。
        attempt.user = WpUser.fromJwt(
          displayName: display.isEmpty ? '已登录用户' : display,
          email: _asString(json?['user_email']),
          nicename: _asString(json?['user_nicename']),
        );
      }
      return attempt;
    }

    return _classifyFailure(
      statusCode: resp.statusCode,
      json: json,
      fallbackText: utf8.decode(resp.bodyBytes, allowMalformed: true),
    );
  }

  /// 把非 200 响应翻译成「原因分类 + 用户能看懂的说明」。
  _LoginAttempt _classifyFailure({
    required int statusCode,
    required Map<String, dynamic>? json,
    required String fallbackText,
  }) {
    final code = _asString(json?['code']);
    final rawMessage = _stripHtml(_asString(json?['message']) ?? '');
    // jwt-auth 插件把错误码拼成 `[jwt_auth] xxx`，去掉前缀后再比对。
    final codeBody = (code ?? '').replaceAll('[jwt_auth]', '').trim();
    final lowerCode = codeBody.toLowerCase();

    // 站点主题验证码钩子的「空错误」指纹：
    //   {"code":"[jwt_auth] ","message":"","data":{"status":403}}
    final emptyFingerprint = statusCode == 403 &&
        codeBody.isEmpty &&
        rawMessage.isEmpty;

    if (emptyFingerprint) {
      return _LoginAttempt(
        failure: WpLoginFailure.serverRestricted,
        message: '服务器拒绝了登录请求（站点返回了不含原因的空错误）',
        code: code,
        statusCode: statusCode,
      );
    }

    // 登录闸门限流：站点自研的 ybh_audit_gate_login（mu-plugins/ybh-audit.php
    // L754-776）。这条必须排在「凭据错误」前面判断 —— 闸门触发时**密码对不对
    // 都会被拒**，若误判成密码错，用户会继续重试，把 10 分钟窗口不断续期。
    if (lowerCode.contains('ybh_login_throttled') ||
        rawMessage.contains('已暂时拒绝登录')) {
      return _LoginAttempt(
        failure: WpLoginFailure.loginThrottled,
        message: rawMessage.isEmpty
            ? '该网络近 10 分钟内登录失败次数过多，已暂时拒绝登录，请约 10 分钟后再试'
            : rawMessage,
        code: code,
        statusCode: statusCode,
      );
    }

    // 明确指向凭据问题。
    const credentialCodes = <String>{
      'invalid_username',
      'incorrect_password',
      'invalid_email',
      'invalid_username_or_password',
      'empty_username',
      'empty_password',
      'authentication_failed',
    };
    if (credentialCodes.any(lowerCode.contains) ||
        rawMessage.contains('密码不正确') ||
        rawMessage.contains('未在本站点注册') ||
        rawMessage.contains('未知用户名') ||
        rawMessage.contains('incorrect password') ||
        rawMessage.contains('not registered')) {
      return _LoginAttempt(
        failure: WpLoginFailure.invalidCredentials,
        message: rawMessage.isEmpty ? '用户名或密码不正确' : rawMessage,
        code: code,
        statusCode: statusCode,
      );
    }

    // 人机验证 / 风控 / 频率限制。
    const blockedMarkers = <String>[
      'prooffail',
      'captcha',
      '验证码',
      '频繁',
      '限制',
      'blocked',
      'forbidden',
      'rate',
      'too many',
    ];
    if (blockedMarkers.any(lowerCode.contains) ||
        blockedMarkers.any(rawMessage.toLowerCase().contains)) {
      return _LoginAttempt(
        failure: WpLoginFailure.serverRestricted,
        message: rawMessage.isEmpty
            ? '站点启用了验证码或风控限制，暂时无法登录'
            : rawMessage,
        code: code,
        statusCode: statusCode,
      );
    }

    if (statusCode >= 500) {
      return _LoginAttempt(
        failure: WpLoginFailure.serverError,
        message: '服务器暂时不可用（HTTP $statusCode），请稍后重试',
        code: code,
        statusCode: statusCode,
      );
    }

    return _LoginAttempt(
      failure: WpLoginFailure.unknown,
      message: rawMessage.isNotEmpty
          ? rawMessage
          : (fallbackText.trim().isEmpty
              ? '登录失败（HTTP $statusCode）'
              : '登录失败（HTTP $statusCode）'),
      code: code,
      statusCode: statusCode,
    );
  }

  /// 应用密码（Basic Auth）登录：用「用户名 + 应用密码」请求 /users/me。
  Future<_LoginAttempt> _loginBasic(String user, String appPassword) async {
    final basic = base64Encode(utf8.encode('$user:$appPassword'));
    try {
      final response = await http.get(
        Uri.parse('${AppConfig.apiBase}/users/me')
            .replace(queryParameters: const {'context': 'edit'}),
        headers: {'Authorization': 'Basic $basic'},
      ).timeout(_timeout);
      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is Map<String, dynamic>) {
          return _LoginAttempt(
            token: basic,
            user: WpUser.fromJson(decoded),
            method: WpAuthMethod.basic,
            statusCode: 200,
          );
        }
      }
      return _classifyFailure(
        statusCode: response.statusCode,
        json: _decodeMap(response.bodyBytes),
        fallbackText: utf8.decode(response.bodyBytes, allowMalformed: true),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[wp_auth] Basic 登录异常: $e');
      return _LoginAttempt(
        failure: WpLoginFailure.network,
        message: '无法连接服务器，请检查网络后重试',
        statusCode: 0,
      );
    }
  }

  static Map<String, dynamic>? _decodeMap(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 去掉服务端错误信息里的 HTML 标签（WordPress 会返回 `<strong>` 与 `<a>`）。
  static String _stripHtml(String input) {
    if (input.isEmpty) return input;
    return input
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#039;', "'")
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .trim();
  }

  /// 重新拉取当前用户资料（角色变更或需要刷新能力时调用）。
  Future<WpUser?> refreshMe() async {
    if (!isLoggedIn) return null;
    final me = await _fetchMe(authHeaders.values.first);
    if (me == null) return null;
    _user = me;
    unawaited(_persist());
    return me;
  }

  /// 服务端返回的是不是「登录态已失效」（JWT 过期 / 令牌无效）。
  ///
  /// 站点用的是 `jwt-authentication-for-wp-rest-api`，令牌有有效期。过期之后
  /// **所有**写操作都会以 `{"code":"jwt_auth_expired_token","message":"Expired token"}`
  /// 被拒；而这句英文原文直接甩给用户是没法理解的（真机验收时实际撞到过）。
  static bool isSessionExpiredMessage(String? msg) {
    if (msg == null) return false;
    final m = msg.toLowerCase();
    if (m.contains('expired token')) return true;
    if (m.contains('invalid token')) return true;
    if (m.contains('jwt_auth_')) return true;
    if (m.contains('token') && (m.contains('expire') || m.contains('过期'))) {
      return true;
    }
    return false;
  }

  /// 给「登录态失效」的统一文案（同时清掉本地会话，让 UI 回到未登录态）。
  static const String sessionExpiredHint = '登录状态已过期，请回到「我的」重新登录后再试';

  /// 若服务端报的是登录态失效，清掉本地会话并返回 true。
  Future<bool> _handleIfSessionExpired(String? serverMessage) async {
    if (!isSessionExpiredMessage(serverMessage)) return false;
    await logout();
    return true;
  }

  Future<void> logout() async {
    _token = null;
    _user = null;
    _method = WpAuthMethod.basic;
    _webLoginCredentials = null;
    webLoginRequested.value++;
    await _persist();
  }

  /// 校验「当前密码」是否正确（改密码前用；与站点「必须验当前密码」口径一致）。
  ///
  /// 做法：拿旧凭据走一次 JWT 登录 —— 成功即正确。**不落任何状态**：
  /// 既不更新 [_token]（那会把当前会话换成新令牌，倒也无害但没必要），
  /// 也不写 [webLoginCredentials]。
  Future<bool> verifyPassword(String password) async {
    final user = _user?.login ?? '';
    if (user.isEmpty || password.isEmpty) return false;
    try {
      final resp = await http
          .post(
            Uri.parse(AppConfig.jwtTokenUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': user, 'password': password}),
          )
          .timeout(_timeout);
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 拉取「我的文章」列表（当前登录用户，含草稿 / 待审核）。
  ///
  /// 会带上「草稿 / 待审核」一起拉，方便投稿者看到自己刚提交的内容；
  /// 若站点不接受该参数（老版本 WP 或权限限制），自动退回只拉已发布。
  ///
  /// 0.0.27：带认证的请求会顺带要 `context=edit`（拿 `content.raw`，编辑时
  /// 才能拿到未经 `the_content` 过滤的原文）；并按 `X-WP-TotalPages` 翻页拉全
  /// —— 之前只拉第一页 20 篇，发文多的作者（编辑 / 管理员）第 21 篇起永远看不到。
  Future<List<PostSummary>> fetchMyPosts({int page = 1, int perPage = 20}) async {
    if (!isLoggedIn) return const [];
    // JWT 但未能拿到用户 id（极少见的兜底情况）：不按作者过滤会拉全站，
    // 这里直接返回空，避免误展示他人文章。
    if (_user == null || _user!.id == 0) return const [];

    /// [withEditContext] 为 true 时带 `context=edit`（拿 raw 正文）。
    /// 失败（部分安全插件会拦）自动退回普通请求。
    Future<List<PostSummary>> request(
      List<String> statuses, {
      bool withEditContext = false,
      int totalPages = 1,
    }) async {
      final all = <PostSummary>[];
      for (var p = 1; p <= totalPages; p++) {
        final query = <String, String>{
          'per_page': '$perPage',
          'page': '$p',
          'author': '${_user!.id}',
          '_embed': '1',
          'orderby': 'date',
          'order': 'desc',
          'status': statuses.join(','),
        };
        if (withEditContext) query['context'] = 'edit';
        final uri = Uri.parse('${AppConfig.apiBase}/posts')
            .replace(queryParameters: query);
        final response =
            await http.get(uri, headers: authHeaders).timeout(_timeout);
        if (response.statusCode != 200) {
          throw StateError('HTTP ${response.statusCode}');
        }
        // 从响应头读总页数（仅首页时能拿到；翻页循环的次数以首页为准）。
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        if (decoded is! List) break;
        all.addAll(decoded
            .whereType<Map<String, dynamic>>()
            .map(PostSummary.fromJson)
            .toList());
        if (p == 1) {
          final tp = int.tryParse(response.headers['x-wp-totalpages'] ?? '');
          if (tp != null && tp > 1 && totalPages == 1 && tp <= 10) {
            return request(
              statuses,
              withEditContext: withEditContext,
              totalPages: tp,
            );
          }
        }
      }
      return all;
    }

    try {
      return await request(const ['publish', 'draft', 'pending', 'future'],
          withEditContext: true);
    } catch (_) {
      try {
        return await request(const ['publish', 'draft', 'pending', 'future']);
      } catch (_) {
        return request(const ['publish']);
      }
    }
  }

  /// 更新已有文章（App 内编辑）。
  ///
  /// 权限与站点 `/write/`（`ybh_front_save`）完全同一套：
  ///   · 服务端 `current_user_can('edit_post', id)` 裁决 —— 自己的文章都能改
  ///     （主题已给投稿者补了 `edit_published_posts`）；
  ///   · **已发布文章 + 无 `publish_posts`** ⇒ 改动后退回「待审核」二次审核
  ///     —— 服务端会强制这样做，这里提前在本地完成同样的降级并如实告知，
  ///     避免用户以为"改完还是已发布"。
  ///   · 请求 'publish' 被服务端 403 拒绝时（能力未知的情况），用 pending 重试一次。
  ///
  /// [status] 只接受 publish / draft / pending；null 表示不改变状态。
  Future<PublishResult> updatePost({
    required int postId,
    String? title,
    String? content,
    bool contentIsHtml = false,
    String? status,
    List<int>? categories,
  }) async {
    if (!isLoggedIn) {
      return const PublishResult.failure('尚未登录，请先登录后再编辑');
    }
    // 与新建投稿同一层保护：无发布权 + 原文已发布 ⇒ 主动降级为待审核。
    String? effective = status;
    if (status == 'publish' && !(_user?.canPublish ?? true)) {
      effective = 'pending';
    }
    final first = await _patchPost(
      postId: postId,
      title: title,
      content: content,
      contentIsHtml: contentIsHtml,
      status: effective,
      categories: categories,
    );
    if (first.ok) return first;
    // 第二层：能力未知导致被 403 拒 ⇒ 用待审核重试一次。
    if (status == 'publish' &&
        effective == 'publish' &&
        first.statusCode == 403) {
      final retry = await _patchPost(
        postId: postId,
        title: title,
        content: content,
        contentIsHtml: contentIsHtml,
        status: 'pending',
        categories: categories,
      );
      if (retry.ok) return retry.copyWithDowngraded();
      return retry;
    }
    return first;
  }

  Future<PublishResult> _patchPost({
    required int postId,
    String? title,
    String? content,
    required bool contentIsHtml,
    String? status,
    List<int>? categories,
  }) async {
    final body = <String, dynamic>{
      ?title: title,
      if (content != null)
        'content': contentIsHtml ? content : _wrapParagraphs(content),
      ?status: status,
      if (categories != null && categories.isNotEmpty) 'categories': categories,
    };
    if (body.isEmpty) {
      return const PublishResult.failure('没有需要保存的修改');
    }
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('${AppConfig.apiBase}/posts/$postId'),
            headers: {
              ...authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      return PublishResult.failure('网络异常：$e');
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON 响应（如网关返回 HTML 错误页）。
    }

    if (response.statusCode == 200 || response.statusCode == 201) {
      final link = json?['link'] as String?;
      return PublishResult.success(
        status: (json?['status'] as String?) ?? (status ?? ''),
        link: (link == null || link.isEmpty) ? AppConfig.blogUrl : link,
      );
    }
    // 令牌过期时顺手清掉本地会话，让「我的」页回到未登录态，用户才知道要重新登录
    await _handleIfSessionExpired(json?['message'] as String?);
    return PublishResult.failure(
      _serverMessage(json, response.statusCode),
      statusCode: response.statusCode,
    );
  }

  /// 拉取标签（编辑器给「已发布文章」补标签用；按名称搜索，空 [search] 返回热门标签）。
  Future<List<({int id, String name})>> fetchTags({String search = ''}) async {
    if (!isLoggedIn) return const [];
    final query = <String, String>{
      'per_page': '20',
      'orderby': 'count',
      'order': 'desc',
    };
    if (search.trim().isNotEmpty) query['search'] = search.trim();
    final uri =
        Uri.parse('${AppConfig.apiBase}/tags').replace(queryParameters: query);
    try {
      final response = await http.get(uri, headers: authHeaders).timeout(_timeout);
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((t) => (
                id: (t['id'] as num?)?.toInt() ?? 0,
                name: (t['name'] as String?) ?? '',
              ))
          .where((t) => t.id > 0 && t.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 发布 / 投稿 / 存草稿。
  ///
  /// [content] 为正文。[contentIsHtml] 为 true 时按 **HTML 原样提交**
  /// （富文本编辑器走这条）；为 false 时按纯文本处理：按空行分段、转义后包 `<p>`
  /// （保留给只输入纯文本的调用方）。
  ///
  /// 服务端会按当前账号能力做 `wp_kses_post` 过滤：没有 `unfiltered_html`
  /// 的账号（投稿者/作者）无法写入脚本等危险标签，但 `<p> <h2> <strong> <em>
  /// <ul> <ol> <blockquote> <pre> <code> <a> <img> <figure>` 这些正常排版标签都会保留。
  ///
  /// [status] 取 'publish'、'draft' 或 'pending'（待审核）。
  ///
  /// **投稿者（contributor）没有 `publish_posts` 权限**，直接发布会被服务端
  /// 拒绝。这里做两层保护：
  ///   1. 已知不能发布时，主动把 'publish' 降级为 'pending'；
  ///   2. 若服务端仍以 403 拒绝（能力读取失败的情况），自动用 'pending'
  ///      重试一次，并在 [PublishResult.downgraded] 标记实际状态。
  Future<PublishResult> publishPost({
    required String title,
    required String content,
    bool contentIsHtml = false,
    String status = 'publish',
    List<int>? categories,
  }) async {
    if (!isLoggedIn) {
      return const PublishResult.failure('尚未登录，请先登录后投稿');
    }
    // 第一层：能力已知且不能直接发布时，主动降级为待审核。
    var effective = status;
    if (status == 'publish' && !(_user?.canPublish ?? true)) {
      effective = 'pending';
    }
    final first = await _createPost(
      title: title,
      content: content,
      contentIsHtml: contentIsHtml,
      status: effective,
      categories: categories,
    );
    if (first.ok) return first;

    // 第二层：能力未知导致直接发布被拒 → 用「待审核」重试一次。
    if (status == 'publish' &&
        effective == 'publish' &&
        first.statusCode == 403) {
      final retry = await _createPost(
        title: title,
        content: content,
        contentIsHtml: contentIsHtml,
        status: 'pending',
        categories: categories,
      );
      if (retry.ok) return retry.copyWithDowngraded();
      return retry;
    }
    return first;
  }

  Future<PublishResult> _createPost({
    required String title,
    required String content,
    required String status,
    bool contentIsHtml = false,
    List<int>? categories,
  }) async {
    final body = {
      'title': title,
      'content': contentIsHtml ? content : _wrapParagraphs(content),
      'status': status,
      if (categories != null && categories.isNotEmpty) 'categories': categories,
    };
    final http.Response response;
    try {
      response = await http
          .post(
            Uri.parse('${AppConfig.apiBase}/posts'),
            headers: {
              ...authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(_timeout);
    } catch (e) {
      return PublishResult.failure('网络异常：$e');
    }

    Map<String, dynamic>? json;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) json = decoded;
    } catch (_) {
      // 非 JSON 响应（如网关返回 HTML 错误页）。
    }

    if (response.statusCode == 201 || response.statusCode == 200) {
      final link = json?['link'] as String?;
      return PublishResult.success(
        status: (json?['status'] as String?) ?? status,
        link: (link == null || link.isEmpty) ? AppConfig.blogUrl : link,
      );
    }
    // 令牌过期时顺手清掉本地会话，让「我的」页回到未登录态，用户才知道要重新登录
    await _handleIfSessionExpired(json?['message'] as String?);
    return PublishResult.failure(
      _serverMessage(json, response.statusCode),
      statusCode: response.statusCode,
    );
  }

  /// 上传图片到媒体库，返回可插入正文的图片地址；失败返回 null。
  ///
  /// WordPress 的 `/wp/v2/media` 支持「原始字节 + `Content-Disposition` 文件名」，
  /// 因此不必构造 multipart。需要账号具备 `upload_files` 能力
  /// （投稿者默认没有，主题侧已放开：`YBH_ALLOW_CONTRIBUTOR_UPLOAD`）。
  Future<String?> uploadMedia({
    required List<int> bytes,
    required String filename,
    String? mimeType,
  }) async {
    if (!isLoggedIn) return null;
    final mime = mimeType ?? _guessMime(filename);
    try {
      final r = await http
          .post(
            Uri.parse('${AppConfig.apiBase}/media'),
            headers: {
              ...authHeaders,
              'Content-Type': mime,
              'Content-Disposition': 'attachment; filename="$filename"',
            },
            body: bytes,
          )
          .timeout(_timeout);
      if (r.statusCode != 201 && r.statusCode != 200) {
        final body = utf8.decode(r.bodyBytes, allowMalformed: true);
        debugPrint('[wp_auth] 图片上传失败 HTTP ${r.statusCode}: '
            '${body.length > 180 ? body.substring(0, 180) : body}');
        // 令牌过期时同样要清会话，否则用户会一直以为还登着
        Map<String, dynamic>? j;
        try {
          final d = jsonDecode(body);
          if (d is Map<String, dynamic>) j = d;
        } catch (_) {}
        await _handleIfSessionExpired(j?['message'] as String?);
        return null;
      }
      final json = jsonDecode(utf8.decode(r.bodyBytes));
      if (json is Map<String, dynamic>) return json['source_url'] as String?;
    } catch (e) {
      debugPrint('[wp_auth] 图片上传异常: $e');
    }
    return null;
  }

  static String _guessMime(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.heic')) return 'image/heic';
    return 'image/jpeg';
  }

  /// 把服务端返回的错误转成用户能看懂的话；带常见 403 的补充说明。
  static String _serverMessage(Map<String, dynamic>? json, int code) {
    final raw = json?['message'] as String?;
    // 登录态失效优先识别：直接把 "Expired token" 抛给用户等于没说
    if (isSessionExpiredMessage(raw)) return sessionExpiredHint;
    final base = (raw == null || raw.trim().isEmpty)
        ? '提交失败（HTTP $code）'
        : raw.trim();
    if (code != 403) return base;
    if (base.contains('publish') || base.contains('发布')) {
      return '$base\n当前账号可能没有直接发布权限，可改用「提交审核」。';
    }
    if (base.contains('category') || base.contains('分类')) {
      return '$base\n可能没有在所选分类下发文的权限，可尝试改为「未分类」。';
    }
    return base;
  }

  /// 纯文本按空行分段包成 HTML 段落，并转义特殊字符避免破坏排版。
  static String _wrapParagraphs(String text) {
    final blocks = text
        .split(RegExp(r'\n\s*\n'))
        .map((b) => b.replaceAll('\r', '').trim())
        .where((b) => b.isNotEmpty)
        .map((b) {
          final escaped = b
              .replaceAll('&', '&amp;')
              .replaceAll('<', '&lt;')
              .replaceAll('>', '&gt;');
          final withBreaks = escaped.replaceAll('\n', '<br>');
          return '<p>$withBreaks</p>';
        })
        .join('\n');
    return blocks;
  }

  static String? _asString(Object? v) => v is String ? v.trim() : null;
}

/// 调试/扩展用：WpUser 序列化。
extension WpUserX on WpUser {
  Map<String, dynamic> toJson() => {
        'id': id,
        'slug': login,
        'name': displayName,
        'nickname': nickname,
        'email': email,
        'avatar_urls': {'96': avatarUrl},
        'roles': roles,
        // 只持久化「能否发布」这一条结论，避免把整张能力表塞进本地存储。
        'capabilities': {'publish_posts': canPublish},
      };
}