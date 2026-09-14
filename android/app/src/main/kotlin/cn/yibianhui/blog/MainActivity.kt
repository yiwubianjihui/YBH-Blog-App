package cn.yibianhui.blog

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * YBH 主 Activity。两条原生通道：
 *
 * **① 电池优化白名单**（T30 · 通知可达性）
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
 *
 * **② 图片选择**（富文本编辑器插图，见 `pickImage()`）
 * 用 `ACTION_GET_CONTENT`，零权限；选完把字节回给 Dart，上传走 WP REST API。
 */
class MainActivity : FlutterActivity() {

    private val powerChannel = "cn.yibianhui.blog/power"
    private val pickerChannel = "cn.yibianhui.blog/picker"

    /** 正在等待结果的图片选择请求（同一时刻只允许一个）。 */
    private var pendingPick: MethodChannel.Result? = null

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, pickerChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickImage" -> pickImage(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 图片选择（富文本编辑器插图用）。
     *
     * 用 `ACTION_GET_CONTENT` 而不是 `ACTION_PICK`：前者兼容相册、文件管理器、
     * 云盘等所有 provider，且**不需要任何存储权限**。选完直接把字节读出来回给
     * Dart，由 Dart 侧走 WP REST `/wp/v2/media` 上传（避免在这里拼 multipart）。
     */
    private fun pickImage(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "上一次选择还没有结束", null)
            return
        }
        pendingPick = result
        try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            startActivityForResult(Intent.createChooser(intent, "选择图片"), PICK_REQUEST)
        } catch (e: Exception) {
            pendingPick = null
            result.error("no_intent", e.message ?: "无法打开图片选择器", null)
        }
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingPick
        pendingPick = null
        if (result == null) return

        val uri = data?.data
        if (resultCode != RESULT_OK || uri == null) {
            result.success(null) // 用户取消
            return
        }
        try {
            val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes == null || bytes.isEmpty()) {
                result.error("read_failed", "无法读取所选图片", null)
                return
            }
            val payload = HashMap<String, Any>()
            payload["bytes"] = bytes
            payload["name"] = displayName(uri) ?: "upload-${System.currentTimeMillis()}.jpg"
            result.success(payload)
        } catch (e: Exception) {
            result.error("read_error", e.message ?: "读取图片失败", null)
        }
    }

    /** 从 content URI 取原始文件名（用于上传时带上正确的扩展名）。 */
    private fun displayName(uri: Uri): String? = try {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: Exception) {
        null
    }

    private companion object {
        const val PICK_REQUEST = 0x7B01
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
