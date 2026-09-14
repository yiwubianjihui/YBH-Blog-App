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
  /// WebView 自动登录；同时通知 [webLoginRequested]。返回 true 表示成功。
  Future<bool> login(String username, String password) async {
    final user = username.trim();
    final pass = password.replaceAll(' ', '');
    if (user.isEmpty || pass.isEmpty) return false;

    WpUser? loggedInUser;
    WpAuthMethod method;
    String? tok;

    // 1) JWT 优先。
    final jwtUser = await _loginJwt(user, pass);
    if (jwtUser != null) {
      method = WpAuthMethod.jwt;
      tok = jwtUser.$1;
      loggedInUser = jwtUser.$2;
    } else {
      // 2) 应用密码兜底。
      final basic = await _loginBasic(user, pass);
      if (basic == null) return false;
      method = WpAuthMethod.basic;
      tok = basic.$1;
      loggedInUser = basic.$2;
    }

    _method = method;
    _token = tok;
    _user = loggedInUser;
    _webLoginCredentials = (user, pass);
    webLoginRequested.value++;

    await _persist();
    return true;
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

  /// JWT 登录：换取令牌并拉取用户资料。任一步非 200 均返回 null。
  Future<(String, WpUser)?> _loginJwt(String user, String pass) async {
    final http.Response tokenResp;
    try {
      tokenResp = await http
          .post(
            Uri.parse(AppConfig.jwtTokenUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': user, 'password': pass}),
          )
          .timeout(_timeout);
    } catch (e) {
      if (kDebugMode) debugPrint('[wp_auth] JWT 请求异常: $e');
      return null;
    }
    if (kDebugMode) {
      debugPrint('[wp_auth] JWT 状态码: ${tokenResp.statusCode}');
    }
    if (tokenResp.statusCode != 200) return null;
    final tokenJson = jsonDecode(utf8.decode(tokenResp.bodyBytes));
    final jwt = tokenJson is Map ? (tokenJson['token'] as String?) : null;
    if (jwt == null || jwt.isEmpty) return null;

    // 用令牌拉取完整资料（含 id / 头像 / 角色 / 能力）。
    final me = await _fetchMe('Bearer $jwt');
    if (me != null) return (jwt, me);

    final display = _asString(tokenJson['user_display_name']) ??
        _asString(tokenJson['user_nicename']) ??
        user;
    final email = _asString(tokenJson['user_email']);
    final nicename = _asString(tokenJson['user_nicename']);
    return (jwt, WpUser.fromJwt(displayName: display, email: email, nicename: nicename));
  }

  /// 应用密码（Basic Auth）登录：用「用户名 + 应用密码」请求 /users/me。
  Future<(String, WpUser)?> _loginBasic(String user, String appPassword) async {
    final basic = base64Encode(utf8.encode('$user:$appPassword'));
    final me = await _fetchMe('Basic $basic');
    if (me == null) return null;
    return (basic, me);
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

  /// 拉取「我的文章」列表（当前登录用户）。
  ///
  /// 会带上「草稿 / 待审核」一起拉，方便投稿者看到自己刚提交的内容；
  /// 若站点不接受该参数（老版本 WP 或权限限制），自动退回只拉已发布。
  Future<List<PostSummary>> fetchMyPosts({int page = 1, int perPage = 20}) async {
    if (!isLoggedIn) return const [];
    // JWT 但未能拿到用户 id（极少见的兜底情况）：不按作者过滤会拉全站，
    // 这里直接返回空，避免误展示他人文章。
    if (_user == null || _user!.id == 0) return const [];

    Future<List<PostSummary>> request(List<String> statuses) async {
      final uri = Uri.parse('${AppConfig.apiBase}/posts').replace(
        queryParameters: {
          'per_page': '$perPage',
          'page': '$page',
          'author': '${_user!.id}',
          '_embed': '1',
          'orderby': 'date',
          'order': 'desc',
          'status': statuses.join(','),
        },
      );
      final response =
          await http.get(uri, headers: authHeaders).timeout(_timeout);
      if (response.statusCode != 200) {
        throw StateError('HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(PostSummary.fromJson)
          .toList();
    }

    try {
      return await request(const ['publish', 'draft', 'pending', 'future']);
    } catch (_) {
      return request(const ['publish']);
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