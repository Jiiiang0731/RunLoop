import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'route_api/route_api_service.dart';

/// 远程配置（阶段 K 规范⑦）：App 启动时尽力拉取一次 `/api/client-config`，
/// 缓存 24h；拉取失败沿用缓存/内置默认——远程配置是增强而非依赖。
///
/// 当前支持的键（服务端可调，无需重新发版）：
/// - `announcement`：首页公告文本（空 = 不显示）；
/// - `generate.max_api_calls` / `generate.sleep_s`：生成预算提示值；
/// - `pois.interval_m` / `pois.radius` / `pois.limit`：POI 采样默认值。
class ClientConfigService {
  ClientConfigService(this._api);

  static const String _prefKey = 'runloop_client_config_v1';
  static const Duration _ttl = Duration(hours: 24);

  final RouteApiService _api;
  Map<String, dynamic> _config = <String, dynamic>{};

  Map<String, dynamic> get current => _config;

  String get announcement {
    final Object? v = _config['announcement'];
    return v is String ? v : '';
  }

  int get poiIntervalM => _int('pois', 'interval_m', 1000);
  int get poiRadiusM => _int('pois', 'radius', 500);
  int get poiLimit => _int('pois', 'limit', 3);

  int _int(String section, String key, int fallback) {
    final Object? sec = _config[section];
    if (sec is Map<String, dynamic>) {
      final Object? v = sec[key];
      if (v is num) {
        return v.toInt();
      }
    }
    return fallback;
  }

  /// 启动时调用：先用缓存立即可用，TTL 过期则后台刷新。
  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_prefKey);
    int cachedAt = 0;
    if (raw != null && raw.isNotEmpty) {
      try {
        final Map<String, dynamic> envelope =
            jsonDecode(raw) as Map<String, dynamic>;
        _config = (envelope['config'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        cachedAt = (envelope['ts'] as num?)?.toInt() ?? 0;
      } catch (_) {
        _config = <String, dynamic>{};
      }
    }
    final bool fresh = DateTime.now().millisecondsSinceEpoch - cachedAt <
        _ttl.inMilliseconds;
    if (fresh) {
      return;
    }
    final Map<String, dynamic>? remote = await _api.fetchClientConfig();
    if (remote != null) {
      _config = remote;
      await prefs.setString(
        _prefKey,
        jsonEncode(<String, dynamic>{
          'ts': DateTime.now().millisecondsSinceEpoch,
          'config': remote,
        }),
      );
    }
  }
}

/// 全局远程配置单例：用户同意隐私政策后由 main 预热（尽力而为，不阻塞 UI）。
/// 未就绪时各 getter 返回内置默认值——远程配置是增强而非依赖。
final ClientConfigService appClientConfig =
    ClientConfigService(RouteApiService());
