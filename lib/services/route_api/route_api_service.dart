import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app/config.dart';
import '../../models/planned_route.dart';

/// 路线规划 API 异常。
class RouteApiException implements Exception {
  final String message;
  final String? code;
  RouteApiException(this.message, {this.code});

  @override
  String toString() => message;
}

/// 调用后端路线规划服务的客户端。
class RouteApiService {
  RouteApiService({String? baseUrl}) : baseUrl = baseUrl ?? AppConfig.routeApiBaseUrl;

  final String baseUrl;

  /// 生成闭合路线。
  Future<RouteGenResult> generate({
    required double lng,
    required double lat,
    required double targetM,
    double tolM = 500,
    List<int> seeds = const <int>[1, 2, 3],
    int points = 10,
    int maxCandidates = 1,
    int maxApiCalls = 600,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/route/generate');
    http.Response resp;
    try {
      resp = await http
          .post(
            uri,
            headers: <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, dynamic>{
              'origin': <String, double>{'lng': lng, 'lat': lat},
              'target_m': targetM.round(),
              'tol_m': tolM.round(),
              'seeds': seeds,
              'points': points,
              'max_candidates': maxCandidates,
              'max_api_calls': maxApiCalls,
            }),
          )
          .timeout(const Duration(seconds: 180));
    } catch (e) {
      throw RouteApiException('网络请求失败（后端未启动或地址错误）：$e', code: 'NETWORK');
    }

    if (resp.statusCode != 200) {
      throw RouteApiException('后端返回 HTTP ${resp.statusCode}：${resp.body}', code: 'HTTP');
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

  /// 查询关键点附近真实 POI（带后端缓存）。
  Future<Map<String, List<Map<String, dynamic>>>> queryPois({
    required List<List<double>> points,
    int radius = 250,
    int limit = 3,
  }) async {
    final Uri uri = Uri.parse('$baseUrl/api/route/pois');
    final http.Response resp = await http
        .post(
          uri,
          headers: <String, String>{'Content-Type': 'application/json'},
          body: jsonEncode(<String, dynamic>{
            'points': points,
            'radius': radius,
            'limit': limit,
          }),
        )
        .timeout(const Duration(seconds: 20));
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final Map<String, List<Map<String, dynamic>>> out =
        <String, List<Map<String, dynamic>>>{};
    for (final dynamic item in (data['results'] as List<dynamic>?) ?? <dynamic>[]) {
      final Map<String, dynamic> m = item as Map<String, dynamic>;
      final String key = '${(m['lng'] as num).toStringAsFixed(5)},${(m['lat'] as num).toStringAsFixed(5)}';
      out[key] = ((m['pois'] as List<dynamic>?) ?? <dynamic>[])
          .map((dynamic p) => p as Map<String, dynamic>)
          .toList();
    }
    return out;
  }

  /// 健康检查（用于连通性测试）。
  Future<bool> ping() async {
    try {
      final http.Response r = await http
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
