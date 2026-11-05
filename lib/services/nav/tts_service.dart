import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'voice_log.dart';

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
/// **单例**（阶段 M 任务书 2.2#10 与 Vivo 专项 8.7：倒计时、转弯提示、
/// 公里配速、目标完成、设置页试听共用同一实例）——多实例会互相覆盖
/// 原生回调（completionHandler 是原生单例上的单一挂载点），导致队列
/// 调度失灵甚至语音静默。
///
/// Android 要点（规范 2.6）：
/// - `setAudioAttributesForNavigation()`：导航音频属性（USAGE_ASSISTANCE_
///   NAVIGATION_GUIDANCE）——系统按导航语义处理焦点，可与音乐共存
///   （音乐自动压低），并正确路由到扬声器/有线/蓝牙耳机；
/// - `speak(focus:true)`：瞬时 duck 焦点，播完即归还（原生 onDone/onStop
///   里 releaseAudioFocus）——不会让音乐永久停止（任务书 2.2#12）；
/// - QUEUE_FLUSH / QUEUE_ADD 两种队列模式实现「转弯优先、信息排队」；
/// - 引擎选择持久化（Vivo 专项）：诊断页选定可用引擎后，初始化时
///   `setEngine(pkg)` 应用，不依赖用户去系统设置里手动切换；
/// - 每次 speak/start/done/cancel/error 写入 VoiceLog——锁屏语音问题
///   凭日志还原时间线（任务书 2.3）。
class FlutterTtsEngine implements SpeechEngine {
  /// 所有调用方共用同一实例（factory 保证）。
  factory FlutterTtsEngine() => shared;

  FlutterTtsEngine._();

  static final FlutterTtsEngine shared = FlutterTtsEngine._();

  /// 引擎选择持久化 key（与 NavSettings 分离：TTS 初始化可能早于设置加载）。
  static const String kEnginePrefKey = 'nav_tts_engine_pkg_v1';

  final FlutterTts _tts = FlutterTts();
  bool _initialized = false;
  bool _speaking = false;
  String? _enginePkg;
  DateTime? _lastSpeakAt;
  String _lastText = '';

  // ---- P0 锁屏诊断：区分「请求已提交 / 已开始出声 / 合成完成」----
  /// 已提交 speak 且尚未收到原生完成回调。
  bool _activeUtterance = false;
  Timer? _startWatchdog;
  Timer? _doneWatchdog;
  int _speakSeq = 0;

  @override
  bool get isSpeaking => _speaking;

  @override
  void Function()? onIdle;

  /// 当前已应用的引擎包名（null = 系统默认）。
  String? get enginePkg => _enginePkg;

  /// 预热（阶段 M-G）：在进入跑步页之前完成引擎初始化——倒计时「三。」
  /// 与第一条导航播报的首响延迟不再包含引擎冷启动开销。
  /// 失败不抛出也不影响功能：speak 时 _ensureInit 会重试。
  Future<void> warmUp() async {
    try {
      await _ensureInit();
    } catch (e) {
      VoiceLog.instance
          .log(VoiceLogKind.lifecycle, 'tts', detail: '预热失败(将重试): $e');
    }
  }

  Future<void> _ensureInit() async {
    if (_initialized) return;
    _tts.setCompletionHandler(() => _onNative('done'));
    _tts.setCancelHandler(() => _onNative('cancel'));
    _tts.setErrorHandler((Object? e) => _onNative('error', detail: '$e'));
    _tts.setStartHandler(() {
      _speaking = true;
      final DateTime? at = _lastSpeakAt;
      _onNative(
        'start',
        detail: at == null
            ? null
            : '首响 ${DateTime.now().difference(at).inMilliseconds}ms',
      );
    });
    try {
      await _tts.setAudioAttributesForNavigation();
    } catch (_) {
      // 老系统不支持导航属性时退回默认媒体流，不影响功能。
    }
    // 应用用户选定的引擎（Vivo 专项：诊断页「自动选择可用引擎」写入）。
    final String? wanted = await _readEnginePref();
    if (wanted != null && wanted.isNotEmpty) {
      await applyEngine(wanted, logSource: 'init');
    }
    try {
      await _tts.setLanguage('zh-CN');
    } catch (e) {
      VoiceLog.instance
          .log(VoiceLogKind.error, 'tts', detail: 'setLanguage 失败: $e');
    }
    _initialized = true;
    VoiceLog.instance.log(VoiceLogKind.system, 'tts',
        detail: '初始化完成 engine=${_enginePkg ?? "系统默认"}');
  }

  static Future<String?> _readEnginePref() async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      return p.getString(kEnginePrefKey);
    } catch (_) {
      return null;
    }
  }

  /// 切换并持久化 TTS 引擎（pkg 为 null/空 = 恢复系统默认）。
  /// 原生 setEngine 会重建 TextToSpeech 并自动重挂 utterance 监听器。
  Future<void> applyEngine(String? pkg, {String logSource = 'diag'}) async {
    try {
      if (pkg == null || pkg.isEmpty) {
        _enginePkg = null;
      } else {
        await _tts.setEngine(pkg);
        _enginePkg = pkg;
      }
      // setEngine 重建实例后需重设语言。
      await _tts.setLanguage('zh-CN');
      final SharedPreferences p = await SharedPreferences.getInstance();
      if (pkg == null || pkg.isEmpty) {
        await p.remove(kEnginePrefKey);
      } else {
        await p.setString(kEnginePrefKey, pkg);
      }
      VoiceLog.instance.log(VoiceLogKind.system, logSource,
          detail: '引擎已切换: ${pkg ?? '系统默认'}');
    } catch (e) {
      VoiceLog.instance.log(VoiceLogKind.error, logSource,
          detail: '引擎切换失败 ${pkg ?? '默认'}: $e');
      rethrow;
    }
  }

  void _onNative(String event, {String? detail}) {
    if (event == 'start') {
      // 已提交 → 引擎真的开始出声。取消“未开始”看门狗，改挂“未完成”看门狗。
      _startWatchdog?.cancel();
      _startWatchdog = null;
      VoiceLog.instance.log(
        VoiceLogKind.start,
        'tts',
        text: _lastText,
        detail: detail,
      );
      _doneWatchdog?.cancel();
      _doneWatchdog = Timer(const Duration(seconds: 20), () {
        if (!_activeUtterance) return;
        _activeUtterance = false;
        _speaking = false;
        VoiceLog.instance.log(VoiceLogKind.error, 'tts',
            text: _lastText,
            detail: '看门狗：已收到 onStart，但 20s 内没有 onDone——'
                '音频输出/引擎可能被系统中断');
        onIdle?.call();
      });
      return;
    }

    _startWatchdog?.cancel();
    _startWatchdog = null;
    _doneWatchdog?.cancel();
    _doneWatchdog = null;
    if (!_activeUtterance) {
      // 看门狗已判定超时/已停止后才到达的迟到回调：只记录，不重复调度。
      VoiceLog.instance.log(
        event == 'done'
            ? VoiceLogKind.done
            : event == 'cancel'
                ? VoiceLogKind.cancel
                : VoiceLogKind.error,
        'tts',
        text: _lastText,
        detail: '迟到回调${detail == null ? '' : '：$detail'}',
      );
      return;
    }
    _activeUtterance = false;
    _speaking = false;
    VoiceLog.instance.log(
      event == 'done'
          ? VoiceLogKind.done
          : event == 'cancel'
              ? VoiceLogKind.cancel
              : VoiceLogKind.error,
      'tts',
      text: _lastText,
      detail: detail,
    );
    onIdle?.call();
  }

  /// 看门狗兜底：speak 已提交但原生层完全没有回调（锁屏/厂商冻结的典型表现）。
  void _onStartWatchdog(int seq) {
    if (seq != _speakSeq || !_activeUtterance) return;
    _activeUtterance = false;
    _speaking = false;
    VoiceLog.instance.log(VoiceLogKind.error, 'tts',
        text: _lastText,
        detail: '看门狗：speak 请求已提交，但 6s 内未收到 onStart——'
            '引擎未合成/被系统冻结（此时用户一定听不到声音）');
    onIdle?.call();
    // 尝试重新初始化一次，排除“引擎已被系统回收”的瞬时故障。
    _initialized = false;
    unawaited(_ensureInit().then((_) {
      VoiceLog.instance
          .log(VoiceLogKind.system, 'tts', detail: '看门狗后引擎重初始化完成');
    }).catchError((Object e) {
      VoiceLog.instance
          .log(VoiceLogKind.error, 'tts', detail: '看门狗后重初始化失败: $e');
    }));
  }

  @override
  Future<void> speak(String text, {required bool flush}) async {
    if (text.isEmpty) return;
    await _ensureInit();
    // Android：0=QUEUE_FLUSH（打断+清队列），1=QUEUE_ADD（排队）。
    await _tts.setQueueMode(flush ? 0 : 1);
    _startWatchdog?.cancel();
    _doneWatchdog?.cancel();
    final int seq = ++_speakSeq;
    _activeUtterance = true;
    _speaking = true;
    _lastText = text;
    _lastSpeakAt = DateTime.now();
    VoiceLog.instance.log(VoiceLogKind.speak, 'tts',
        text: text, detail: flush ? 'flush' : 'queue');
    _startWatchdog = Timer(const Duration(seconds: 6), () {
      _onStartWatchdog(seq);
    });
    try {
      // focus:true → 请求音频焦点（音乐自动 duck，播完归还）。
      await _tts.speak(text, focus: true);
    } catch (e) {
      _startWatchdog?.cancel();
      _startWatchdog = null;
      _activeUtterance = false;
      VoiceLog.instance
          .log(VoiceLogKind.error, 'tts', text: text, detail: 'speak 异常: $e');
      _speaking = false;
      onIdle?.call(); // 失败也要释放队列调度，绝不无限卡住
    }
  }

  @override
  Future<void> stop() async {
    _startWatchdog?.cancel();
    _startWatchdog = null;
    _doneWatchdog?.cancel();
    _doneWatchdog = null;
    _activeUtterance = false;
    if (!_initialized) return;
    try {
      await _tts.stop();
    } catch (_) {}
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
          '手机没有安装任何语音合成（TTS）引擎：请打开「语音引擎诊断」页查看系统'
              '实际提供的引擎，或到系统设置 → 语言和输入法 → 文字转语音输出 中安装。',
        );
      }
      // Android 专有：中文语音数据是否已下载。
      // 注意：部分厂商引擎（如 Vivo）此检测会误报 false，因此仅作为
      // 提示参考——真实可用性以「语音引擎诊断」页的朗读测试为准。
      bool? installed;
      try {
        installed = await _tts.isLanguageInstalled('zh-CN');
      } catch (_) {
        installed = null; // 平台不支持该检测时按 available 兜底
      }
      final bool available = await _tts.isLanguageAvailable('zh-CN');
      if (!available) {
        if (installed == false) {
          return const TtsDiagnostic(
            TtsAvailability.languageNotInstalled,
            '当前引擎缺少中文语音数据：请打开「语音引擎诊断」页自动选择可用引擎，'
                '或到系统设置 → 文字转语音输出 → 引擎设置 下载「中文（普通话）」语音包。',
          );
        }
        return const TtsDiagnostic(
          TtsAvailability.languageUnavailable,
          '当前语音引擎不支持普通话：请打开「语音引擎诊断」页自动选择可用引擎。',
        );
      }
      if (installed == false) {
        // isLanguageAvailable 说可用但 installed 说没数据：厂商引擎常见的
        // 矛盾读数（网络合成引擎居多）。不武断报错，提示做一次真实测试。
        return const TtsDiagnostic(
          TtsAvailability.ok,
          '中文可用（引擎报告缺少离线语音数据，可能依赖网络合成）。'
              '建议在「语音引擎诊断」页做一次朗读测试确认，并留意锁屏断网场景。',
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

  /// 兼容旧调用（页面销毁）：单例只停止播报，不销毁共享实例。
  Future<void> dispose() async {
    await stop();
  }
}
