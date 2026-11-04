import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// 中文 TTS 可用性状态（规范 2.5：缺失必须明确提示，不得静默失败）。
enum TtsAvailability {
  /// 尚未检测。
  unknown,

  /// 中文语音可用。
  ok,

  /// 系统没有任何 TTS 引擎。
  noEngine,

  /// 有引擎但中文语音数据未安装。
  languageNotInstalled,

  /// 引擎不支持 zh-CN。
  languageUnavailable,
}

/// 可用性诊断结果（状态 + 用户可读的中文指引）。
class TtsDiagnostic {
  final TtsAvailability availability;
  final String guidance;

  const TtsDiagnostic(this.availability, this.guidance);

  bool get ok => availability == TtsAvailability.ok;
}

/// 播报引擎抽象——NavAnnouncer 只依赖此接口，单测用 Fake 注入。
abstract class SpeechEngine {
  /// 播报一条语音。
  ///
  /// [flush]=true：立即打断当前播报并清空队列（转弯/偏航等时效性语音）；
  /// [flush]=false：排队到当前语音之后（公里配速等信息类语音）。
  Future<void> speak(String text, {required bool flush});

  /// 停止当前播报并清空队列（暂停/结束跑步）。
  Future<void> stop();

  /// 应用语速/音量设置。
  Future<void> configure({required double rate, required double volume});

  /// 检测中文语音可用性（含引擎缺失时的用户指引文案）。
  Future<TtsDiagnostic> diagnose();

  /// 当前是否正在播报。
  bool get isSpeaking;

  /// 一条语音播完（或被取消/出错）时的回调——队列调度用。
  void Function()? onIdle;
}

/// flutter_tts 实现（系统 TTS，无付费语音 API）。
///
/// Android 要点（规范 2.6）：
/// - `setAudioAttributesForNavigation()`：导航音频属性（USAGE_ASSISTANCE_
///   NAVIGATION_GUIDANCE）——系统按导航语义处理焦点，可与音乐共存
///   （音乐自动压低），并正确路由到扬声器/有线/蓝牙耳机；
/// - QUEUE_FLUSH / QUEUE_ADD 两种队列模式实现「转弯优先、信息排队」；
/// - 锁屏/后台：进程存活（前台服务保证）时系统 TTS 照常工作。
class FlutterTtsEngine implements SpeechEngine {
  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _speaking = false;

  @override
  bool get isSpeaking => _speaking;

  @override
  void Function()? onIdle;

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _tts.setCompletionHandler(_onIdle);
    _tts.setCancelHandler(_onIdle);
    _tts.setErrorHandler((Object? _) => _onIdle());
    _tts.setStartHandler(() => _speaking = true);
    try {
      await _tts.setAudioAttributesForNavigation();
    } catch (_) {
      // 老系统不支持导航属性时退回默认媒体流，不影响功能。
    }
    await _tts.setLanguage('zh-CN');
    _initialized = true;
  }

  void _onIdle() {
    _speaking = false;
    onIdle?.call();
  }

  @override
  Future<void> speak(String text, {required bool flush}) async {
    if (text.isEmpty) return;
    await _ensureInit();
    // Android：0=QUEUE_FLUSH（打断+清队列），1=QUEUE_ADD（排队）。
    await _tts.setQueueMode(flush ? 0 : 1);
    _speaking = true;
    // focus:true → 请求音频焦点（音乐自动 duck）。
    await _tts.speak(text, focus: true);
  }

  @override
  Future<void> stop() async {
    if (!_initialized) return;
    await _tts.stop();
    _speaking = false;
  }

  @override
  Future<void> configure({required double rate, required double volume}) async {
    await _ensureInit();
    await _tts.setSpeechRate(rate);
    await _tts.setVolume(volume);
  }

  @override
  Future<TtsDiagnostic> diagnose() async {
    try {
      await _ensureInit();
      final dynamic engines = await _tts.getEngines;
      final List<dynamic> engineList =
          engines is List ? engines : const <dynamic>[];
      if (engineList.isEmpty) {
        return const TtsDiagnostic(
          TtsAvailability.noEngine,
          '手机没有安装任何语音合成（TTS）引擎：请在系统设置 → 语言和输入法 → '
              '文字转语音输出 中安装语音引擎（如厂商语音服务或 Google 语音服务）后重试。',
        );
      }
      // Android 专有：中文语音数据是否已下载。
      bool? installed;
      try {
        installed = await _tts.isLanguageInstalled('zh-CN');
      } catch (_) {
        installed = null; // 平台不支持该检测时按 available 兜底
      }
      if (installed == false) {
        return const TtsDiagnostic(
          TtsAvailability.languageNotInstalled,
          '语音引擎缺少中文语音数据：请在系统设置 → 语言和输入法 → 文字转语音输出 → '
              '引擎设置 中下载「中文（普通话）」语音包后重试。',
        );
      }
      final bool available = await _tts.isLanguageAvailable('zh-CN');
      if (!available) {
        return const TtsDiagnostic(
          TtsAvailability.languageUnavailable,
          '当前语音引擎不支持普通话：请在系统设置 → 文字转语音输出 中更换支持中文的引擎。',
        );
      }
      return const TtsDiagnostic(TtsAvailability.ok, '中文普通话语音可用。');
    } catch (e) {
      debugPrint('TTS diagnose failed: $e');
      return TtsDiagnostic(
        TtsAvailability.noEngine,
        '语音服务初始化失败：$e',
      );
    }
  }

  /// 释放（跑步结束页面销毁时调用）。
  Future<void> dispose() async {
    await stop();
  }
}
