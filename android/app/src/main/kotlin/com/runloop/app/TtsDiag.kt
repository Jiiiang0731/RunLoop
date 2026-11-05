package com.runloop.app

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID

/**
 * 语音引擎原生诊断通道（阶段 M · Vivo TTS 专项）。
 *
 * 职责（任务书第二/三/七节）：
 * - 用 Android TextToSpeech API 枚举全部已安装引擎与默认引擎；
 * - 逐引擎探测：初始化状态、isLanguageAvailable(zh-CN)、getVoices()
 *   的中文 Voice 及其网络/离线属性；
 * - **真实合成测试**：对指定引擎实际 speak 一句普通话，回报
 *   onStart/onDone/onError 与延迟——「真正播放了」而不是「初始化成功」；
 * - 电池白名单 / Vivo 自启动设置页跳转（锁屏存活保障引导）；
 * - 全部结果只含设备型号、引擎包名与测试状态，不含账号、Key 等隐私。
 *
 * 单飞（single-flight）设计：同一时刻只允许一个探测/测试实例，
 * 新请求先 shutdown 旧实例——绝不产生重复 TTS 实例（任务书 2.2#10）。
 */
class TtsDiag(private val context: Context) {

    private val main = Handler(Looper.getMainLooper())
    private var active: TextToSpeech? = null
    private var activeTimeout: Runnable? = null

    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo())
            "powerState" -> result.success(powerState())
            "listEngines" -> listEngines(result)
            "probeEngine" -> probeEngine(call.argument<String>("pkg"), null, result)
            "testSpeak" -> probeEngine(
                call.argument<String>("pkg"),
                call.argument<String>("text") ?: DEFAULT_TEST_TEXT,
                result,
            )
            "openBatterySettings" -> result.success(openBatterySettings())
            "openAutostartSettings" -> result.success(openAutostartSettings())
            else -> result.notImplemented()
        }
    }

    fun release() {
        cancelActive()
    }

    private fun cancelActive() {
        activeTimeout?.let { main.removeCallbacks(it) }
        activeTimeout = null
        active?.let {
            try {
                it.stop()
                it.shutdown()
            } catch (_: Exception) {
            }
        }
        active = null
    }

    // ---------- 设备与电源状态 ----------

    private fun deviceInfo(): Map<String, Any?> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "brand" to Build.BRAND,
            "model" to Build.MODEL,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "defaultEnginePkg" to Settings.Secure.getString(
                context.contentResolver, Settings.Secure.TTS_DEFAULT_SYNTH,
            ),
            "ignoringBatteryOptimizations" to
                pm.isIgnoringBatteryOptimizations(context.packageName),
            "deviceIdleMode" to pm.isDeviceIdleMode,
            "powerSaveMode" to pm.isPowerSaveMode,
            "screenOn" to pm.isInteractive,
        )
    }

    private fun powerState(): Map<String, Any?> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return mapOf(
            "ignoringBatteryOptimizations" to
                pm.isIgnoringBatteryOptimizations(context.packageName),
            "deviceIdleMode" to pm.isDeviceIdleMode,
            "powerSaveMode" to pm.isPowerSaveMode,
            "screenOn" to pm.isInteractive,
        )
    }

    // ---------- 引擎枚举 ----------

    /**
     * 通过一次性 TextToSpeech 实例调用官方 getEngines()/defaultEngine
     * （任务书二.1/2）。初始化超时（5s）时回退 PackageManager 查询
     * TTS_SERVICE——两种途径数据同源，保证任何机型都能给出列表。
     */
    private fun listEngines(result: MethodChannel.Result) {
        var settled = false
        val finish = { payload: Any ->
            if (!settled) {
                settled = true
                main.post { result.success(payload) }
            }
        }
        main.post {
            cancelActive()
            var ref: TextToSpeech? = null
            val timeout = Runnable {
                ref?.let {
                    try {
                        it.shutdown()
                    } catch (_: Exception) {
                    }
                }
                finish(mapOf("engines" to pmQueryEngines(), "defaultPkg" to defaultPkg(),
                    "via" to "packageManager(fallback)"))
            }
            ref = TextToSpeech(context) { status ->
                main.removeCallbacks(timeout)
                if (status != TextToSpeech.SUCCESS || ref == null) {
                    finish(mapOf("engines" to pmQueryEngines(), "defaultPkg" to defaultPkg(),
                        "via" to "packageManager(fallback)"))
                    try {
                        ref?.shutdown()
                    } catch (_: Exception) {
                    }
                    return@TextToSpeech
                }
                val engines = try {
                    ref!!.engines.map {
                        mapOf(
                            "label" to it.label,
                            "pkg" to it.name,
                            "icon" to false,
                        )
                    }
                } catch (e: Exception) {
                    pmQueryEngines()
                }
                val def = try {
                    ref!!.defaultEngine
                } catch (_: Exception) {
                    defaultPkg()
                }
                finish(mapOf("engines" to engines, "defaultPkg" to def, "via" to "textToSpeechApi"))
                try {
                    ref!!.shutdown()
                } catch (_: Exception) {
                }
            }
            active = ref
            activeTimeout = timeout
            main.postDelayed(timeout, 5000)
        }
    }

    private fun defaultPkg(): String? =
        Settings.Secure.getString(context.contentResolver, Settings.Secure.TTS_DEFAULT_SYNTH)

    /** PackageManager 兜底枚举（与 TextToSpeech.getEngines 同源查询）。 */
    private fun pmQueryEngines(): List<Map<String, Any?>> {
        val intent = Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE)
        val services = context.packageManager.queryIntentServices(intent, 0)
        return services.map {
            mapOf(
                "label" to (it.loadLabel(context.packageManager)?.toString() ?: it.`package`),
                "pkg" to it.`package`,
            )
        }
    }

    // ---------- 单引擎探测 + 真实合成测试 ----------

    /**
     * @param pkg 目标引擎包名；null = 系统默认引擎。
     * @param text 非空时在探测后执行**真实朗读测试**（任务书二.9/四）。
     */
    private fun probeEngine(pkg: String?, text: String?, result: MethodChannel.Result) {
        var settled = false
        val startedAt = System.currentTimeMillis()
        var speakStartedAt = 0L
        val finish = { payload: Map<String, Any?> ->
            if (!settled) {
                settled = true
                main.post {
                    cancelActive()
                    result.success(payload)
                }
            }
        }
        main.post {
            cancelActive()
            val timeout = Runnable {
                finish(mapOf(
                    "ok" to false,
                    "stage" to "timeout",
                    "error" to if (text != null) "初始化或合成超时（12s）" else "引擎初始化超时（12s）",
                    "totalMs" to (System.currentTimeMillis() - startedAt),
                ))
            }
            var tts: TextToSpeech? = null
            tts = if (pkg.isNullOrEmpty()) {
                TextToSpeech(context, makeListener(finish, timeout, text, startedAt, { speakStartedAt }, { v -> speakStartedAt = v }))
            } else {
                TextToSpeech(context, makeListener(finish, timeout, text, startedAt, { speakStartedAt }, { v -> speakStartedAt = v }), pkg)
            }
            active = tts
            activeTimeout = timeout
            main.postDelayed(timeout, 12000)
        }
    }

    private fun makeListener(
        finish: (Map<String, Any?>) -> Unit,
        timeout: Runnable,
        text: String?,
        startedAt: Long,
        speakStartGetter: () -> Long,
        speakStartSetter: (Long) -> Unit,
    ): TextToSpeech.OnInitListener {
        return TextToSpeech.OnInitListener { status ->
            main.removeCallbacks(timeout)
            val tts = active
            if (status != TextToSpeech.SUCCESS || tts == null) {
                finish(mapOf(
                    "ok" to false, "stage" to "init",
                    "error" to "引擎初始化失败（status=$status，可能引擎不存在/被系统限制）",
                    "totalMs" to (System.currentTimeMillis() - startedAt),
                ))
                return@OnInitListener
            }
            val zhAvail = try {
                tts.isLanguageAvailable(Locale.SIMPLIFIED_CHINESE)
            } catch (e: Exception) {
                -2
            }
            val zhVoices = try {
                tts.voices.orEmpty()
                    .filter { it.locale.language == "zh" }
                    .take(8)
                    .map { v ->
                        mapOf(
                            "name" to v.name,
                            "locale" to v.locale.toLanguageTag(),
                            "network" to v.features.contains(TextToSpeech.Engine.KEY_FEATURE_NETWORK_SYNTHESIS),
                            "embedded" to v.features.contains(TextToSpeech.Engine.KEY_FEATURE_EMBEDDED_SYNTHESIS),
                        )
                    }
            } catch (e: Exception) {
                emptyList()
            }
            val setResult = try {
                tts.setLanguage(Locale.SIMPLIFIED_CHINESE)
            } catch (e: Exception) {
                -2
            }
            val base = mapOf(
                "ok" to true,
                "stage" to "probed",
                "initMs" to (System.currentTimeMillis() - startedAt),
                "zhAvailableCode" to zhAvail, // -1 缺失 / 0 可用 / 1 国家变体 / 2 近似
                "setLanguageCode" to setResult,
                "zhVoices" to zhVoices,
            )
            if (text == null) {
                finish(base)
                return@OnInitListener
            }
            // ---- 真实合成测试：必须收到 onStart→onDone 才算「真的播了」 ----
            val utteranceId = "diag-" + UUID.randomUUID()
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(id: String?) {
                    if (id == utteranceId) speakStartSetter(System.currentTimeMillis())
                }

                override fun onDone(id: String?) {
                    if (id != utteranceId) return
                    val s = speakStartGetter()
                    finish(base + mapOf(
                        "stage" to "spoke",
                        "speakStartLatencyMs" to if (s > 0) s - startedAt else -1,
                        "totalMs" to (System.currentTimeMillis() - startedAt),
                    ))
                }

                @Deprecated("API 21 compat")
                override fun onError(id: String?) {
                    if (id != utteranceId) return
                    finish(base + mapOf(
                        "ok" to false, "stage" to "speakError",
                        "error" to "合成/播放失败（onError）——引擎可能缺中文语音数据或被系统拦截",
                        "totalMs" to (System.currentTimeMillis() - startedAt),
                    ))
                }

                override fun onError(id: String?, errorCode: Int) {
                    if (id != utteranceId) return
                    finish(base + mapOf(
                        "ok" to false, "stage" to "speakError",
                        "error" to "合成/播放失败（errorCode=$errorCode）",
                        "totalMs" to (System.currentTimeMillis() - startedAt),
                    ))
                }

                override fun onStop(id: String?, interrupted: Boolean) {
                    if (id != utteranceId) return
                    finish(base + mapOf(
                        "ok" to false, "stage" to "stopped",
                        "error" to "播放被中断（interrupted=$interrupted）",
                        "totalMs" to (System.currentTimeMillis() - startedAt),
                    ))
                }
            })
            val speakCode = try {
                tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
            } catch (e: Exception) {
                -1
            }
            if (speakCode != TextToSpeech.SUCCESS) {
                finish(base + mapOf(
                    "ok" to false, "stage" to "speakRejected",
                    "error" to "speak() 被引擎拒绝（code=$speakCode）",
                    "totalMs" to (System.currentTimeMillis() - startedAt),
                ))
            }
            // speak 阶段单独兜底超时（合成可能永远不回调）
            val speakTimeout = Runnable {
                finish(base + mapOf(
                    "ok" to false, "stage" to "speakTimeout",
                    "error" to "朗读 10 秒内未完成回调（网络引擎断网/引擎无响应）",
                    "totalMs" to (System.currentTimeMillis() - startedAt),
                ))
            }
            activeTimeout = speakTimeout
            main.postDelayed(speakTimeout, 10000)
        }
    }

    // ---------- 设置页跳转（锁屏存活保障引导） ----------

    private fun openBatterySettings(): Map<String, Any?> {
        // 未白名单 → 直接弹系统「忽略电池优化」确认框（需
        // REQUEST_IGNORE_BATTERY_OPTIMIZATIONS 权限，Manifest 已声明）。
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (!pm.isIgnoringBatteryOptimizations(context.packageName)) {
            try {
                val intent = Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:" + context.packageName),
                )
                context.startActivity(intent)
                return mapOf("ok" to true, "target" to "requestIgnoreBatteryOptimizations")
            } catch (_: Exception) {
            }
        }
        // 已白名单或弹窗不可用 → 打开电池优化列表 / 应用详情
        return try {
            context.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            mapOf("ok" to true, "target" to "batteryOptimizationList")
        } catch (_: Exception) {
            try {
                context.startActivity(Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:" + context.packageName),
                ))
                mapOf("ok" to true, "target" to "appDetails")
            } catch (e: Exception) {
                mapOf("ok" to false, "target" to "none", "error" to e.message)
            }
        }
    }

    /** Vivo/iQOO 自启动与后台耗电管理页（best-effort，逐机型组件尝试）。 */
    private fun openAutostartSettings(): Map<String, Any?> {
        val candidates = listOf(
            "自启动管理" to ComponentName("com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
            "后台高耗电" to ComponentName("com.vivo.abe",
                "com.vivo.applicationbehaviorengine.ui.ExcessivePowerManagerActivity"),
            "i管家自启动" to ComponentName("com.iqoo.secure",
                "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
            "后台弹出界面" to ComponentName("com.vivo.permissionmanager",
                "com.vivo.permissionmanager.activity.PurviewTabActivity"),
        )
        for ((label, comp) in candidates) {
            try {
                val intent = Intent().setComponent(comp)
                context.startActivity(intent)
                return mapOf("ok" to true, "target" to label)
            } catch (_: Exception) {
            }
        }
        return try {
            context.startActivity(Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + context.packageName),
            ))
            mapOf("ok" to true, "target" to "appDetails(未找到 Vivo 专用页，请在「权限/电池」中手动放行自启动与后台运行)")
        } catch (e: Exception) {
            mapOf("ok" to false, "target" to "none", "error" to e.message)
        }
    }

    companion object {
        const val DEFAULT_TEST_TEXT = "你好，欢迎使用环跑。前方五十米右转。"
    }
}
