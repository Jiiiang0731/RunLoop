import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app/config.dart';
import '../../models/planned_route.dart';
import '../device_id.dart';

/// 路线规划 API 异常。
class RouteApiException implements Exception {
  final String message;
  final String? code;

  /// 服务端建议的重试等待秒数（限流/熔断时非 0）。
  final int retryAfterS;

  RouteApiException(this.message, {this.code, this.retryAfterS = 0});

  @override
  String toString() => message;
}

/// 调用后端路线规划服务的客户端。
///
/// 阶段 K：所有请求携带 X-Device-Id（轻量设备标识，供服务端每客户端限流）；
/// 429/503 解析 Retry-After 转为可展示的等待提示；后端地址未配置时立即抛
/// NOT_CONFIGURED（离线优先模式，绝不静默失败）。
class RouteApiService {
  RouteApiService({String? baseUrl})
      : baseUrl = baseUrl ?? AppConfig.routeApiBaseUrl;

  final String baseUrl;

  Future<Map<String, String>> _headers() async {
    final Map<String, String> h = <String, String>{
      'Content-Type': 'application/json',
    };
    String dev = '';
    try {
      dev = DeviceId.peek() ?? await DeviceId.get();
    } catch (_) {
      // 设备 ID 不可用：不带请求头继续（服务端按 IP 兜底限流）。
    }
    if (dev.isNotEmpty) {
      h['X-Device-Id'] = dev;
    }
    return h;
  }

  void _ensureConfigured() {
    if (baseUrl.isEmpty) {
      throw RouteApiException(
        '未配置服务器地址：正式版需注入 Tailscale HTTPS 地址后重新构建，'
        '当前仅离线功能可用（已保存的路线不受影响）。',
        code: 'NOT_CONFIGURED',
      );
    }
  }

  /// 把非 200 响应转为带用户可读信息的异常（限流/熔断/繁忙带等待秒数）。
  RouteApiException _httpError(http.Response resp) {
    final int retry = int.tryParse(resp.headers['retry-after'] ?? '') ?? 0;
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      body = null;
    }
    final String? code = body?['error_code'] as String?;
    final String msg = (body?['error'] as String?) ??
        '后端返回 HTTP ${resp.statusCode}';
    switch (resp.statusCode) {
      case 429:
        return RouteApiException(
          retry > 0 ? '$msg（约 ${_humanWait(retry)} 后可再试）' : msg,
          code: code ?? 'RATE_LIMITED',
          retryAfterS: retry,
        );
      case 503:
        return RouteApiException(
          retry > 0 ? '$msg（约 ${_humanWait(retry)} 后自动恢复）' : msg,
          code: code ?? 'UPSTREAM_QUOTA',
          retryAfterS: retry,
        );
      default:
        return RouteApiException(msg, code: code ?? 'HTTP', retryAfterS: retry);
    }
  }

  static String _humanWait(int s) {
    if (s < 60) {
      return '$s 秒';
    }
    if (s < 3600) {
      return '${(s / 60).ceil()} 分钟';
    }
    return '${(s / 3600).ceil()} 小时';
  }

  /// 生成闭合路线。
  Future<RouteGenResult> generate({
    required double lng,
    required double lat,
    required double targetM,
    double tolM = 500,
    List<int> seeds = const <int>[1, 2, 3],
    int points = 0, // 0 = 后端按目标距离自适应（阶段 I/J 调优）
    int maxCandidates = 1,
    int? maxApiCalls, // null = 用服务端默认（800，质量优先）
    bool fixDetours = true, // 阶段 K：无效绕行识别替换
  }) async {
    _ensureConfigured();
    final Uri uri = Uri.parse('$baseUrl/api/route/generate');
    http.Response resp;
    try {
      resp = await http
          .post(
            uri,
            headers: await _headers(),
            body: jsonEncode(<String, dynamic>{
              'origin': <String, double>{'lng': lng, 'lat': lat},
              'target_m': targetM.round(),
              'tol_m': tolM.round(),
              'seeds': seeds,
              'points': points,
              'max_candidates': maxCandidates,
              if (maxApiCalls != null) 'max_api_calls': maxApiCalls,
              'fix_detours': fixDetours,
            }),
          )
          .timeout(AppConfig.generateTimeout);
    } catch (e) {
      throw RouteApiException(
        '无法连接服务器（后端未启动 / Tailscale 未连接 / 地址错误）：$e',
        code: 'NETWORK',
      );
    }

    if (resp.statusCode != 200) {
      throw _httpError(resp);
    }

    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if (data['success'] != true) {
      throw RouteApiException(
        '${data['error'] ?? '路线生成失败'}',
        code: data['error_code'] as String?,
      );
    }
    final List<dynamic> raw = (data['candidates'] as List<dynamic>?) ?? <dynamic>[];
    final List<PlannedRoute> routes = raw
        .where((dynamic c) => (c as Map<String, dynamic>)['ok'] == true)
        .map((dynamic c) => PlannedRoute.fromJson(c as Map<String, dynamic>))
        .toList();
    if (routes.isEmpty) {
      throw RouteApiException('没有可用的候选路线', code: 'EMPTY');
    }
    final Map<String, dynamic> rawStage =
        (data['stage_times'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return RouteGenResult(
      routes: routes,
      elapsedS: (data['elapsed_s'] as num?)?.toDouble() ?? 0,
      apiCalls: (data['total_api_calls'] as num?)?.toInt() ?? 0,
      stageTimes: rawStage.map(
        (String k, dynamic v) => MapEntry<String, double>(
          k,
          (v as num?)?.toDouble() ?? 0,
        ),
      ),
    );
  }

  /// 按路线累计里程查询沿途真实 POI（后端采样 + 缓存）。
  Future<List<Map<String, dynamic>>> queryPois({
    required List<List<double>> polyline,
    int intervalM = 1000,
    int radius = 500,
    int limit = 3,
  }) async {
    _ensureConfigured();
    final Uri uri = Uri.parse('$baseUrl/api/route/pois');
    final http.Response resp = await http
        .post(
          uri,
          headers: await _headers(),
          body: jsonEncode(<String, dynamic>{
            'polyline': polyline,
            'interval_m': intervalM,
            'radius': radius,
            'limit': limit,
          }),
        )
        .timeout(const Duration(seconds: 90));
    if (resp.statusCode != 200) {
      throw _httpError(resp);
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    return ((data['results'] as List<dynamic>?) ?? <dynamic>[])
        .map((dynamic e) => e as Map<String, dynamic>)
        .toList();
  }

  /// 拉取远程配置（阶段 K 规范⑦：BASE_URL 单源 + 远程配置机制）。
  /// 失败静默返回 null——远程配置是增强而非依赖，离线不影响已缓存值。
  Future<Map<String, dynamic>?> fetchClientConfig() async {
    if (baseUrl.isEmpty) {
      return null;
    }
    try {
      final http.Response r = await http
          .get(Uri.parse('$baseUrl/api/client-config'), headers: await _headers())
          .timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> data = jsonDecode(r.body) as Map<String, dynamic>;
      if (data['success'] == true) {
        return data['config'] as Map<String, dynamic>?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 健康检查（用于连通性测试）。
  Future<bool> ping() async {
    if (baseUrl.isEmpty) {
      return false;
    }
    try {
      final http.Response r = await http
          .get(Uri.parse('$baseUrl/api/health'), headers: await _headers())
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
