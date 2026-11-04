import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 语音导航设置（阶段 L 模块 A，规范 2.5）。
///
/// SharedPreferences 持久化 + ChangeNotifier 通知 UI。
/// 默认：普通话导航开、每公里配速播报开、提前提示 50m。
class NavSettings extends ChangeNotifier {
  NavSettings._();

  static final NavSettings instance = NavSettings._();

  static const String _kVoiceNav = 'nav_voice_enabled_v1';
  static const String _kKmPace = 'nav_km_pace_enabled_v1';
  static const String _kAnnounceM = 'nav_announce_distance_m_v1';
  static const String _kRate = 'nav_speech_rate_v1';
  static const String _kVolume = 'nav_volume_v1';

  /// 语音导航总开关（默认开）。
  bool voiceNavEnabled = true;

  /// 每公里配速播报开关（默认开）。
  bool kmPaceEnabled = true;

  /// 转弯提前提示距离（米），默认 50；可调 30/50/80/100。
  double announceDistanceM = 50;

  /// 语速（flutter_tts Android 语义：0.5=正常，范围约 0.0–1.0）。
  double speechRate = 0.5;

  /// 音量 0.0–1.0。
  double volume = 1.0;

  bool loaded = false;

  Future<void> load() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    voiceNavEnabled = p.getBool(_kVoiceNav) ?? true;
    kmPaceEnabled = p.getBool(_kKmPace) ?? true;
    announceDistanceM = (p.getDouble(_kAnnounceM) ?? 50).clamp(20.0, 150.0);
    speechRate = (p.getDouble(_kRate) ?? 0.5).clamp(0.1, 1.0);
    volume = (p.getDouble(_kVolume) ?? 1.0).clamp(0.0, 1.0);
    loaded = true;
    notifyListeners();
  }

  Future<void> setVoiceNavEnabled(bool v) => _save(() => voiceNavEnabled = v, _kVoiceNav, v);
  Future<void> setKmPaceEnabled(bool v) => _save(() => kmPaceEnabled = v, _kKmPace, v);
  Future<void> setAnnounceDistanceM(double v) {
    final double clamped = v.clamp(20.0, 150.0);
    return _save(() => announceDistanceM = clamped, _kAnnounceM, clamped);
  }

  Future<void> setSpeechRate(double v) {
    final double clamped = v.clamp(0.1, 1.0);
    return _save(() => speechRate = clamped, _kRate, clamped);
  }

  Future<void> setVolume(double v) {
    final double clamped = v.clamp(0.0, 1.0);
    return _save(() => volume = clamped, _kVolume, clamped);
  }

  Future<void> _save(VoidCallback mutate, String key, Object value) async {
    mutate();
    notifyListeners();
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (value is bool) {
      await p.setBool(key, value);
    } else if (value is double) {
      await p.setDouble(key, value);
    }
  }

  @visibleForTesting
  static void debugResetForTest() {
    instance
      ..voiceNavEnabled = true
      ..kmPaceEnabled = true
      ..announceDistanceM = 50
      ..speechRate = 0.5
      ..volume = 1.0
      ..loaded = false;
  }
}
