import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一个已安装 TTS 引擎的概要。
class TtsEngineInfo {
  const TtsEngineInfo({required this.label, required this.pkg});

  final String label;
  final String pkg;
}

/// 单引擎探测/真实朗读测试结果（任务书二/四：必须验证「真的播了」）。
class TtsProbeResult {
  const TtsProbeResult({
    required this.ok,
    required this.stage,
    this.error,
    this.initMs,
    this.zhAvailableCode,
    this.setLanguageCode,
    this.zhVoices = const <Map<String, dynamic>>[],
    this.speakStartLatencyMs,
    this.totalMs,
  });

  final bool ok;

  /// probed / spoke / init / timeout / speakError / speakTimeout / stopped / speakRejected
  final String stage;
  final String? error;
  final int? initMs;

  /// TextToSpeech.isLanguageAvailable：-1 缺失，0 可用，1 国家变体，2 近似，-2 异常。
  final int? zhAvailableCode;
  final int? setLanguageCode;
  final List<Map<String, dynamic>> zhVoices;
  final int? speakStartLatencyMs;
  final int? totalMs;

  bool get zhSupported => (zhAvailableCode ?? -2) >= 0;

  bool get hasEmbeddedZh => zhVoices.any(
      (Map<String, dynamic> v) => (v['embedded'] as bool?) == true);

  bool get hasNetworkZh =>
      zhVoices.any((Map<String, dynamic> v) => (v['network'] as bool?) == true);

  /// 面向用户的中文摘要。
  String describe() {
    final StringBuffer sb = StringBuffer();
    sb.write(ok ? '✔ ' : '✘ ');
    switch (stage) {
      case 'spoke':
        sb.write('真实朗读成功（首响 ${speakStartLatencyMs}ms / 全程 ${totalMs}ms）');
      case 'probed':
        sb.write('初始化 ${initMs}ms；zh-CN ${zhSupported ? '可用' : '不可用'}'
            '（code=$zhAvailableCode）');
        if (zhVoices.isNotEmpty) {
          sb.write('；中文 Voice ${zhVoices.length} 个'
              '${hasEmbeddedZh ? '，含离线' : ''}${hasNetworkZh ? '，含网络' : ''}');
        }
      case 'init':
      case 'timeout':
      case 'speakError':
      case 'speakTimeout':
      case 'stopped':
      case 'speakRejected':
        sb.write('失败[$stage]：${error ?? '未知'}');
      default:
        sb.write('状态[$stage] ${error ?? ''}');
    }
    return sb.toString();
  }

  static TtsProbeResult fromMap(Map<dynamic, dynamic> m) {
    final List<Map<String, dynamic>> voices =
        ((m['zhVoices'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic v) => Map<String, dynamic>.from(v as Map))
            .toList();
    return TtsProbeResult(
      ok: (m['ok'] as bool?) ?? false,
      stage: (m['stage'] as String?) ?? '?',
      error: m['error'] as String?,
      initMs: (m['initMs'] as num?)?.toInt(),
      zhAvailableCode: (m['zhAvailableCode'] as num?)?.toInt(),
      setLanguageCode: (m['setLanguageCode'] as num?)?.toInt(),
      zhVoices: voices,
      speakStartLatencyMs: (m['speakStartLatencyMs'] as num?)?.toInt(),
      totalMs: (m['totalMs'] as num?)?.toInt(),
    );
  }

  static const TtsProbeResult unsupported = TtsProbeResult(
    ok: false,
    stage: 'unsupported',
    error: '当前平台不支持原生诊断（仅 Android）',
  );
}

/// 设备信息快照。
class DevicePowerInfo {
  const DevicePowerInfo(this.map);

  final Map<String, dynamic> map;

  String get model => '${map['manufacturer'] ?? '?'} ${map['model'] ?? '?'}';
  String get android =>
      'Android ${map['androidRelease'] ?? '?'} (API ${map['sdkInt'] ?? '?'})';
  String? get defaultEnginePkg => map['defaultEnginePkg'] as String?;
  bool get batteryWhitelisted =>
      (map['ignoringBatteryOptimizations'] as bool?) ?? false;
  bool get idleMode => (map['deviceIdleMode'] as bool?) ?? false;
  bool get powerSave => (map['powerSaveMode'] as bool?) ?? false;

  bool get isVivoLike {
    final String m = ((map['manufacturer'] as String?) ?? '').toLowerCase();
    final String b = ((map['brand'] as String?) ?? '').toLowerCase();
    return m.contains('vivo') || b.contains('vivo') || b.contains('iqoo');
  }
}

/// 原生 TTS 诊断通道封装（MethodChannel `runloop/tts_diag`，见 TtsDiag.kt）。
///
/// 非 Android 平台 / 通道异常一律返回明确失败——诊断功能自身绝不静默。
class NativeTtsDiagnostics {
  NativeTtsDiagnostics({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('runloop/tts_diag');

  final MethodChannel _channel;

  /// 任务书四节指定的测试语句。
  static const String testText = '你好，欢迎使用环跑。前方五十米右转。';

  Future<DevicePowerInfo?> deviceInfo() async {
    try {
      final Map<dynamic, dynamic>? m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('deviceInfo');
      return m == null ? null : DevicePowerInfo(Map<String, dynamic>.from(m));
    } on PlatformException catch (e) {
      debugPrint('tts_diag deviceInfo failed: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// 轻量电源/锁屏状态（不枚举引擎）：供跑步心跳日志区分「锁屏中」。
  Future<Map<String, dynamic>> powerState() async {
    try {
      final Map<dynamic, dynamic>? m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('powerState');
      return Map<String, dynamic>.from(m ?? const <dynamic, dynamic>{});
    } on PlatformException catch (e) {
      return <String, dynamic>{'error': e.message ?? '$e'};
    } on MissingPluginException {
      return <String, dynamic>{'error': 'unsupported'};
    }
  }

  Future<(List<TtsEngineInfo>, String? defaultPkg, String via)>
      listEngines() async {
    try {
      final Map<dynamic, dynamic>? m =
          await _channel.invokeMethod<Map<dynamic, dynamic>>('listEngines');
      if (m == null) return (const <TtsEngineInfo>[], null, 'none');
      final List<TtsEngineInfo> engines =
          ((m['engines'] as List<dynamic>?) ?? const <dynamic>[])
              .map((dynamic e) {
        final Map<dynamic, dynamic> em = e as Map<dynamic, dynamic>;
        return TtsEngineInfo(
          label: (em['label'] as String?) ?? '?',
          pkg: (em['pkg'] as String?) ?? '?',
        );
      }).toList();
      return (
        engines,
        m['defaultPkg'] as String?,
        (m['via'] as String?) ?? '?'
      );
    } on PlatformException catch (e) {
      debugPrint('tts_diag listEngines failed: $e');
      return (const <TtsEngineInfo>[], null, 'error: ${e.message}');
    } on MissingPluginException {
      return (const <TtsEngineInfo>[], null, 'unsupported');
    }
  }

  Future<TtsProbeResult> probeEngine(String? pkg) async {
    try {
      final Map<dynamic, dynamic>? m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('probeEngine', <String, dynamic>{
        'pkg': pkg,
      });
      return m == null
          ? TtsProbeResult.unsupported
          : TtsProbeResult.fromMap(m);
    } on PlatformException catch (e) {
      return TtsProbeResult(
          ok: false, stage: 'channel', error: e.message ?? '$e');
    } on MissingPluginException {
      return TtsProbeResult.unsupported;
    }
  }

  Future<TtsProbeResult> testSpeak(String? pkg, {String text = testText}) async {
    try {
      final Map<dynamic, dynamic>? m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('testSpeak', <String, dynamic>{
        'pkg': pkg,
        'text': text,
      });
      return m == null
          ? TtsProbeResult.unsupported
          : TtsProbeResult.fromMap(m);
    } on PlatformException catch (e) {
      return TtsProbeResult(
          ok: false, stage: 'channel', error: e.message ?? '$e');
    } on MissingPluginException {
      return TtsProbeResult.unsupported;
    }
  }

  /// 跳转电池白名单（未白名单时直接弹系统确认框）。
  Future<Map<String, dynamic>> openBatterySettings() async {
    try {
      final Map<dynamic, dynamic>? m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('openBatterySettings');
      return Map<String, dynamic>.from(m ?? const <dynamic, dynamic>{});
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }

  /// 跳转 Vivo/iQOO 自启动与后台耗电管理（best-effort）。
  Future<Map<String, dynamic>> openAutostartSettings() async {
    try {
      final Map<dynamic, dynamic>? m = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('openAutostartSettings');
      return Map<String, dynamic>.from(m ?? const <dynamic, dynamic>{});
    } catch (e) {
      return <String, dynamic>{'ok': false, 'error': '$e'};
    }
  }
}
