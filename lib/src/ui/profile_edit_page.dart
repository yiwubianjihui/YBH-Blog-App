import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app_config.dart';
import '../data/app_i18n.dart';
import '../data/wp_auth.dart';
import '../shell/webview_tab.dart'
    if (dart.library.html) '../shell/webview_tab_stub.dart';
import '../shell/webview_ui_state.dart';

/// 个人资料页（0.0.29）：原生编辑「基本资料 + 修改密码」，
/// 头像 / 社交账号 / 站点偏好等**留在站点资料页**完成
/// （站点的 `/profile/` 有完整四分区 + 偏好，且社交字段是站点自建的
/// user_meta，REST 不暴露 —— 与其复制一套校验，不如把已验过的表单直接用）。
///
/// 数据来源：`GET /wp-json/wp/v2/users/me?context=edit`
/// 保存：`POST /wp-json/wp/v2/users/me`（JWT 应用密码均可）。
/// 修改密码：REST 的 `password` 参数**不验旧密码**（WP 核心行为），
/// 为了与站点「必须验当前密码」的口径一致，先用旧密码走一次 JWT 登录校验
/// （成功 = 旧密码正确），再提交新密码。
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  final _nameController = TextEditingController();
  final _nickController = TextEditingController();
  final _descController = TextEditingController();
  final _urlController = TextEditingController();

  final _oldPwdController = TextEditingController();
  final _newPwdController = TextEditingController();
  final _newPwd2Controller = TextEditingController();
  bool _obscureOld = true;
  bool _obscureNew = true;
  bool _obscureNew2 = true;

  bool _loading = true;
  bool _savingProfile = false;
  bool _savingPwd = false;
  String? _error;

  String _email = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nickController.dispose();
    _descController.dispose();
    _urlController.dispose();
    _oldPwdController.dispose();
    _newPwdController.dispose();
    _newPwd2Controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final resp = await http
          .get(
            Uri.parse('${AppConfig.apiBase}/users/me')
                .replace(queryParameters: {'context': 'edit'}),
            headers: wpAuth.authHeaders,
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw StateError('HTTP ${resp.statusCode}');
      }
      final map = jsonDecodeMap(utf8.decode(resp.bodyBytes));
      if (map == null) throw StateError('bad response');
      if (!mounted) return;
      setState(() {
        _nameController.text = (map['name'] as String?) ?? '';
        _nickController.text = (map['nickname'] as String?) ?? '';
        _descController.text = (map['description'] as String?) ?? '';
        _urlController.text = (map['url'] as String?) ?? '';
        _email = (map['email'] as String?) ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败：$e';
      });
    }
  }

  Future<void> _saveProfile() async {
    if (_savingProfile) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = L.t(context, '显示名不能为空'));
      return;
    }
    setState(() {
      _savingProfile = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'name': name,
      'nickname': _nickController.text.trim().isEmpty
          ? name
          : _nickController.text.trim(),
      'description': _descController.text.trim(),
      'url': _normalizeUrl(_urlController.text.trim()),
    };
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConfig.apiBase}/users/me'),
            headers: {
              ...wpAuth.authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        final msg = _serverMessage(utf8.decode(resp.bodyBytes, allowMalformed: true));
        throw StateError(msg);
      }
      // 刷新本地用户缓存（「我的」页头部显示的就是它）。
      await wpAuth.refreshMe();
      if (!mounted) return;
      setState(() => _savingProfile = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t(context, '已保存'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingProfile = false;
        _error = '$e';
      });
    }
  }

  Future<void> _changePassword() async {
    if (_savingPwd) return;
    final oldPwd = _oldPwdController.text;
    final newPwd = _newPwdController.text;
    final newPwd2 = _newPwd2Controller.text;
    if (oldPwd.isEmpty || newPwd.isEmpty) {
      setState(() => _error = L.t(context, '请填写当前密码与新密码'));
      return;
    }
    if (newPwd != newPwd2) {
      setState(() => _error = L.t(context, '两次输入的新密码不一致'));
      return;
    }
    if (newPwd.length < 8) {
      setState(() => _error = '新密码至少 8 位（站点应用密码规范）');
      return;
    }
    setState(() {
      _savingPwd = true;
      _error = null;
    });

    // 1) 验旧密码：拿旧凭据换一次 JWT。成功 = 旧密码正确。
    //    （站点口径：改密码必须验当前密码 —— REST 的 password 参数不验，
    //     所以这道闸在客户端先做。）
    final oldOk = await wpAuth.verifyPassword(oldPwd);
    if (!mounted) return;
    if (!oldOk) {
      setState(() {
        _savingPwd = false;
        _error = L.t(context, '当前密码不正确');
      });
      return;
    }

    // 2) 提交新密码。
    try {
      final resp = await http
          .post(
            Uri.parse('${AppConfig.apiBase}/users/me'),
            headers: {
              ...wpAuth.authHeaders,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'password': newPwd}),
          )
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200 && resp.statusCode != 201) {
        final msg = _serverMessage(utf8.decode(resp.bodyBytes, allowMalformed: true));
        throw StateError(msg);
      }
      if (!mounted) return;
      setState(() {
        _savingPwd = false;
        _oldPwdController.clear();
        _newPwdController.clear();
        _newPwd2Controller.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t(context, '密码已修改'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingPwd = false;
        _error = '$e';
      });
    }
  }

  /// 打开站点资料页的指定分区（头像/社交/偏好/安全）。
  void _openSiteTab(String tab) {
    final base = '${AppConfig.blogUrl}/profile/';
    final url = tab == 'profile' || tab.isEmpty ? base : '$base?ybh_tab=$tab';
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => BlogWebViewPage(
          initialUrl: url,
          loginReturnUrl: url,
          uiState: WebViewUiState(),
        ),
      ),
    );
  }

  static String _normalizeUrl(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    return 'https://$s';
  }

  static Map<String, dynamic>? jsonDecodeMap(String raw) {
    try {
      final v = jsonDecode(raw);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  static String _serverMessage(String raw) {
    final m = jsonDecodeMap(raw);
    final msg = m?['message'] as String?;
    if (msg != null && msg.trim().isNotEmpty) return msg.trim();
    return '保存失败';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t(context, '个人资料')),
        actions: [
          if (!_loading && !_savingProfile)
            TextButton.icon(
              onPressed: _saveProfile,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(L.t(context, '保存')),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                if (_error != null) ...[
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      _error!,
                      style: TextStyle(
                          color: colorScheme.onErrorContainer, fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                _Card(
                  children: [
                    Text(
                      L.t(context, '编辑资料'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: L.t(context, '显示名'),
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nickController,
                      decoration: InputDecoration(
                        labelText: L.t(context, '昵称'),
                        helperText: '留空则与显示名一致',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _descController,
                      maxLines: 3,
                      maxLength: 200,
                      decoration: InputDecoration(
                        labelText: L.t(context, '个人简介'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _urlController,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(
                        labelText: L.t(context, '个人网站'),
                        hintText: 'https://…',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                    if (_email.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.mail_outline,
                              size: 16, color: colorScheme.outline),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _email,
                              style: TextStyle(
                                  fontSize: 13, color: colorScheme.outline),
                            ),
                          ),
                          TextButton(
                            onPressed: () => _openSiteTab('security'),
                            child: const Text('更换邮箱'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                _Card(
                  children: [
                    Text(
                      L.t(context, '修改密码'),
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '需要验证当前密码（与网站口径一致）',
                      style: TextStyle(fontSize: 12, color: colorScheme.outline),
                    ),
                    const SizedBox(height: 12),
                    _PwdField(
                      controller: _oldPwdController,
                      label: L.t(context, '当前密码'),
                      obscure: _obscureOld,
                      onToggle: () =>
                          setState(() => _obscureOld = !_obscureOld),
                    ),
                    const SizedBox(height: 10),
                    _PwdField(
                      controller: _newPwdController,
                      label: L.t(context, '新密码'),
                      obscure: _obscureNew,
                      onToggle: () =>
                          setState(() => _obscureNew = !_obscureNew),
                    ),
                    const SizedBox(height: 10),
                    _PwdField(
                      controller: _newPwd2Controller,
                      label: L.t(context, '确认新密码'),
                      obscure: _obscureNew2,
                      onToggle: () =>
                          setState(() => _obscureNew2 = !_obscureNew2),
                      onSubmitted: (_) => _changePassword(),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _savingPwd ? null : _changePassword,
                        icon: _savingPwd
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5),
                              )
                            : const Icon(Icons.lock_reset_outlined, size: 18),
                        label: Text(L.t(context, '修改密码')),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _Card(
                  children: [
                    Text(
                      '站点设置（应用内网页，登录状态自动同步）',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: colorScheme.primary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '这些设置保存在网站服务器，网页端与 App 同步可见',
                      style: TextStyle(fontSize: 12, color: colorScheme.outline),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.account_circle_outlined),
                      title: const Text('头像'),
                      subtitle: const Text('上传新头像（≤2 MB，自动裁方）'),
                      trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                      onTap: () => _openSiteTab('avatar'),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.share_outlined),
                      title: const Text('社交账号'),
                      subtitle: const Text('GitHub / B站 / 知乎 / 微博 / Telegram 等'),
                      trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                      onTap: () => _openSiteTab('profile'),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.tune_outlined),
                      title: const Text('偏好'),
                      subtitle: const Text('后台配色、界面语言、编辑器选项'),
                      trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                      onTap: () => _openSiteTab('prefs'),
                    ),
                    const Divider(height: 1, indent: 56),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.mail_outline),
                      title: const Text('更换邮箱'),
                      subtitle: const Text('两步确认：新邮箱收信后点击链接生效'),
                      trailing: const Icon(Icons.chevron_right_outlined, size: 20),
                      onTap: () => _openSiteTab('security'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}

/// 修改密码用的密码框（可切明文）。
class _PwdField extends StatelessWidget {
  const _PwdField({
    required this.controller,
    required this.label,
    required this.obscure,
    required this.onToggle,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String label;
  final bool obscure;
  final VoidCallback onToggle;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      autofillHints: const [AutofillHints.password],
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
        suffixIcon: IconButton(
          icon: Icon(obscure ? Icons.visibility_off : Icons.visibility,
              size: 20),
          onPressed: onToggle,
        ),
      ),
      onSubmitted: onSubmitted,
    );
  }
}

/// 统一的分组卡片。
class _Card extends StatelessWidget {
  const _Card({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}
