package com.runloop.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var ttsDiag: TtsDiag? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 阶段 M · Vivo TTS 专项：原生语音引擎诊断通道
        val diag = TtsDiag(this)
        ttsDiag = diag
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result -> diag.handle(call, result) }
    }

    override fun onDestroy() {
        ttsDiag?.release()
        ttsDiag = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "runloop/tts_diag"
    }
}
