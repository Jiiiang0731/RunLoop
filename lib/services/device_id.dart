import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// 轻量设备标识（阶段 K 规范⑨：每客户端配额）。
///
/// 隐私设计（规范⑩）：首次启动本地生成随机 ID 并持久化，不采集任何
/// 硬件序列号/IMEI/账号信息，不可反推设备身份；仅用于服务端限流计数
/// （服务端只存 sha256 前 8 位）。卸载重装会生成新 ID，属预期。
class DeviceId {
  DeviceId._();

  static const String _prefKey = 'runloop_device_id_v1';
  static String? _cached;

  /// 获取（首次生成并持久化）设备 ID，形如 `rl-<base36时间>-<20位随机>`。
  static Future<String> get() async {
    final String? memo = _cached;
    if (memo != null) {
      return memo;
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    String? id = prefs.getString(_prefKey);
    if (id == null || id.trim().isEmpty) {
      id = _generate();
      await prefs.setString(_prefKey, id);
    }
    _cached = id;
    return id;
  }

  /// 同步读取（App 启动时已 get() 过后可用；否则返回 null，调用方降级为
  /// 不带 X-Device-Id——服务端会按来源 IP 计数，功能不受影响）。
  static String? peek() => _cached;

  static String _generate() {
    final Random rnd = Random.secure();
    final String ts =
        DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final String rand = List<String>.generate(
      20,
      (_) => alphabet[rnd.nextInt(alphabet.length)],
    ).join();
    return 'rl-$ts-$rand';
  }

  /// 仅用于测试：重置内存缓存（不删除持久化值）。
  static void debugResetCache() => _cached = null;
}

/// base64url 小工具（离线缓存 key 等场景可用）。
String b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
