package cn.yibianhui.blog

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * YBH 主 Activity。
 *
 * 只加了一件事：**电池优化白名单**（T30 · 通知可达性）。
 *
 * 为什么需要：
 *   新文章/审核通过提醒靠 WorkManager 周期任务投递。华为等国产 ROM 的省电策略会把
 *   「未加入电池优化白名单」的应用在后台冻结甚至杀掉，任务就不再执行 ——
 *   表现就是「通知渠道建好了、权限也给了，但收不到」。
 *   系统白名单只能由用户手动确认，因此 App 只能做「检测 + 引导跳转」。
 *
 * 用的是官方 API：
 *   · isIgnoringBatteryOptimizations(pkg)      —— 是否已在白名单
 *   · ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS —— 弹系统对话框申请
 * 注意：部分 ROM 会忽略该 Intent；调用失败时返回 false，由 Dart 侧提示用户
 * 去「设置 → 电池 → 应用启动管理」手动放行，不阻塞任何流程。
 */
class MainActivity : FlutterActivity() {

    private val powerChannel = "cn.yibianhui.blog/power"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, powerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> result.success(isIgnoring())
                    "requestIgnoreBatteryOptimizations" -> result.success(requestIgnore())
                    else -> result.notImplemented()
                }
            }
    }

    private fun isIgnoring(): Boolean = try {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        pm.isIgnoringBatteryOptimizations(packageName)
    } catch (e: Exception) {
        false
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnore(): Boolean = try {
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        true
    } catch (e: Exception) {
        // ROM 不支持该 Intent：退回「应用详情页」，让用户自己找电池设置。
        try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
            )
            true
        } catch (e2: Exception) {
            false
        }
    }
}
