import 'package:flutter/material.dart';

import '../data/notification_background.dart';
import '../data/notification_prefs.dart';
import '../data/notification_service.dart';
import '../data/power_guard.dart';

/// 通知设置页：总开关、检查频率、提醒类型。
class NotificationSettingsPage extends StatefulWidget {
  const NotificationSettingsPage({super.key});

  @override
  State<NotificationSettingsPage> createState() =>
      _NotificationSettingsPageState();
}

class _NotificationSettingsPageState extends State<NotificationSettingsPage> {
  NotificationPrefs _prefs = const NotificationPrefs();
  bool _loading = true;
  bool _testing = false;

  /// 是否已在系统「电池优化白名单」里；null = 无法判定（非 Android / 查询失败）。
  bool? _ignoringBattery;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await NotificationPrefs.load();
    final ignoring = await PowerGuard.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _ignoringBattery = ignoring;
      _loading = false;
    });
  }

  /// 申请加入电池优化白名单；回来后再查一次状态。
  Future<void> _requestBatteryWhitelist() async {
    final opened = await PowerGuard.requestIgnoreBatteryOptimizations();
    if (!mounted) return;
    if (!opened) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这台设备不支持一键跳转，请到「设置 → 电池 → 应用启动管理」里手动允许后台运行'),
        ),
      );
      return;
    }
    // 用户可能在系统界面里点了「允许」或返回，稍后再查一次。
    await Future<void>.delayed(const Duration(seconds: 2));
    final ignoring = await PowerGuard.isIgnoringBatteryOptimizations();
    if (!mounted) return;
    setState(() => _ignoringBattery = ignoring);
  }

  Future<void> _save(NotificationPrefs next) async {
    setState(() => _prefs = next);
    await NotificationPrefs.save(next);
    await NotificationScheduler.schedule();
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    // 请求权限（若还没给）+ 发一条测试通知。
    await NotificationService.requestPermission();
    await NotificationService.show(
      id: 9999,
      title: '通知已开启 ✓',
      body: '这是一条测试通知，新文章和审核通过后会在这里提醒你。',
    );
    if (!mounted) return;
    setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('通知设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SwitchListTile(
            title: const Text('接收通知'),
            subtitle: const Text('新文章发布、投稿审核通过提醒'),
            value: _prefs.enabled,
            onChanged: (v) => _save(_prefs.copyWith(enabled: v)),
          ),
          if (_prefs.enabled) ...[
            const Divider(height: 1),
            // ---- 后台可达性（T30）----
            // 国产 ROM（尤其华为）会把未加白名单的应用在后台冻结，WorkManager 停摆，
            // 表现就是「权限都给了却收不到通知」。这里做检测 + 一键引导。
            ListTile(
              contentPadding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              leading: Icon(
                _ignoringBattery == true
                    ? Icons.battery_saver_outlined
                    : Icons.battery_alert_outlined,
                color: _ignoringBattery == true ? colorScheme.primary : colorScheme.error,
              ),
              title: const Text('后台运行白名单'),
              subtitle: Text(
                _ignoringBattery == true
                    ? '已加入电池优化白名单，后台提醒可以正常送达'
                    : _ignoringBattery == null
                        ? '无法检测（非 Android 设备）。若收不到通知，请手动允许后台运行'
                        : '未加入。华为等机型会冻结后台任务，导致收不到提醒',
                style: const TextStyle(fontSize: 12.5, height: 1.5),
              ),
              trailing: _ignoringBattery == true
                  ? null
                  : TextButton(
                      onPressed: _requestBatteryWhitelist,
                      child: const Text('去设置'),
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Text(
                '后台检查频率',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.outline,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: DropdownButtonFormField<int>(
                initialValue: _prefs.frequencyMinutes,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 15, child: Text('每 15 分钟')),
                  DropdownMenuItem(value: 60, child: Text('每小时')),
                  DropdownMenuItem(value: 180, child: Text('每 3 小时')),
                  DropdownMenuItem(value: 0, child: Text('不后台检查')),
                ],
                onChanged: (v) {
                  if (v != null) {
                    _save(_prefs.copyWith(frequencyMinutes: v));
                  }
                },
              ),
            ),
            SwitchListTile(
              title: const Text('新文章提醒'),
              subtitle: const Text('站点发布新文章时通知'),
              value: _prefs.newPostEnabled,
              onChanged: (v) =>
                  _save(_prefs.copyWith(newPostEnabled: v)),
            ),
            SwitchListTile(
              title: const Text('投稿审核通过提醒'),
              subtitle: const Text('登录后，你的投稿从「待审核」变为「已发布」时通知'),
              value: _prefs.myPostEnabled,
              onChanged: (v) => _save(_prefs.copyWith(myPostEnabled: v)),
            ),
            const Divider(height: 1),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _testing ? null : _test,
              icon: _testing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.notifications_active_outlined, size: 18),
              label: const Text('发送测试通知'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(46),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '提示：后台检查通过系统任务调度，频率最低 15 分钟一次；'
              'App 正在使用时也会即时检查。首次开启时会请求系统通知权限。',
              style: TextStyle(fontSize: 12.5, height: 1.6, color: colorScheme.outline),
            ),
          ],
        ],
      ),
    );
  }
}
