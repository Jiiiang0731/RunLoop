import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../app/config.dart';
import '../../models/planned_route.dart';
import '../device_id.dart';
import 'route_api_service.dart' show RouteApiException;

/// 一次成功重规划的完整结果（任务书 5.6 响应字段的客户端模型）。
///
/// 数据全部来自服务端真实高德步行规划——连接段折线/距离/步骤、
/// 合并后的剩余路线、诚实的剩余与预计总里程、容差达标标记。
class ReroutePlan {
  const ReroutePlan({
    required this.rerouteId,
    required this.connectorPolyline,
    required this.connectorM,
    required this.connectorDurationS,
    required this.connectorSteps,
    required this.rejoinAlongM,
    required this.skippedM,
    required this.mergedRemainingPolyline,
    required this.remainingM,
    required this.estimatedTotalM,
    required this.withinTolerance,
    required this.targetM,
    required this.tolM,
    required this.apiCalls,
    required this.elapsedS,
  });

  /// 本次偏航事件的请求/结果标识（与客户端请求锁配合，防过期结果接入）。
  final String rerouteId;

  /// 连接段折线（[lng, lat]，GCJ-02，真实步行道路）。
  final List<List<double>> connectorPolyline;
  final double connectorM;
  final double connectorDurationS;

  /// 连接段真实导航步骤（cumulative 从 0 起，接入方负责与原步骤合并）。
  final List<RouteStep> connectorSteps;

  /// 接回点在**请求时传入的参考路线**上的累计里程。
  final double rejoinAlongM;

  /// 接回点与偏航确认点之间被跳过的原路线长度（米，诚实口径）。
  final double skippedM;

  /// 合并后的新剩余路线（连接段 + 原剩余，[lng, lat]，GCJ-02）。
  final List<List<double>> mergedRemainingPolyline;

  /// 新剩余里程 = 连接段 + 原路线剩余（米）。
  final double remainingM;

  /// 新预计总里程 = 已完成 + 新剩余（米；超出目标时如实上报）。
  final double estimatedTotalM;

  /// 预计总里程是否仍在目标 ±tol 内（false = 如实展示新里程，5.5）。
  final bool withinTolerance;
  final double targetM;
  final double tolM;
  final int apiCalls;
  final double elapsedS;

  factory ReroutePlan.fromJson(Map<String, dynamic> j) {
    final Map<String, dynamic> conn =
        (j['connector'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    final Map<String, dynamic> rejoin =
        (j['rejoin'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    List<List<double>> poly(dynamic raw) => ((raw as List<dynamic>?) ?? <dynamic>[])
        .map<List<double>>((dynamic p) => <double>[
              (p[0] as num).toDouble(),
              (p[1] as num).toDouble(),
            ])
        .toList();
    return ReroutePlan(
      rerouteId: j['reroute_id'] as String? ?? '',
      connectorPolyline: poly(conn['polyline']),
      connectorM: (conn['distance_m'] as num?)?.toDouble() ?? 0,
      connectorDurationS: (conn['duration_s'] as num?)?.toDouble() ?? 0,
      connectorSteps: ((conn['steps'] as List<dynamic>?) ?? <dynamic>[])
          .map<RouteStep>(
              (dynamic s) => RouteStep.fromJson(s as Map<String, dynamic>))
          .toList(),
      rejoinAlongM: (rejoin['along_m'] as num?)?.toDouble() ?? 0,
      skippedM: (rejoin['skipped_m'] as num?)?.toDouble() ?? 0,
      mergedRemainingPolyline: poly(j['merged_remaining_polyline']),
      remainingM: (j['remaining_m'] as num?)?.toDouble() ?? 0,
      estimatedTotalM: (j['estimated_total_m'] as num?)?.toDouble() ?? 0,
      withinTolerance: j['within_tolerance'] == true,
      targetM: (j['target_m'] as num?)?.toDouble() ?? 0,
      tolM: (j['tol_m'] as num?)?.toDouble() ?? 500,
      apiCalls: (j['api_calls'] as num?)?.toInt() ?? 0,
      elapsedS: (j['elapsed_s'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 动态重规划客户端（任务书 5.6）。
///
/// POST /api/route/reroute；失败一律抛 [RouteApiException]：
/// - code=NETWORK：无网络/后端未启动/Tailscale 断开（5.7#9 断网回退入口）；
/// - code=NO_REJOIN：所有候选接回点不可达；
/// - code=AMAP_ERROR：上游限流；
/// - code=RATE_LIMITED/UPSTREAM_QUOTA：服务端防护（带 retryAfterS）。
class RerouteClient {
  RerouteClient({String? baseUrl, http.Client? client})
      : baseUrl = baseUrl ?? AppConfig.routeApiBaseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  static const Duration requestTimeout = Duration(seconds: 25);

  Future<ReroutePlan> request({
    required double lng,
    required double lat,
    required List<List<double>> polyline,
    required double alongM,
    required double targetM,
    required double completedM,
    double? headingDeg,
    double tolM = 500,
    int maxApiCalls = 5,
  }) async {
    if (baseUrl.isEmpty) {
      throw RouteApiException('未配置服务器地址，无法重新规划路线',
          code: 'NOT_CONFIGURED');
    }
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    try {
      final String dev = DeviceId.peek() ?? await DeviceId.get();
      if (dev.isNotEmpty) headers['X-Device-Id'] = dev;
    } catch (_) {
      // 设备 ID 不可用：服务端按 IP 兜底限流。
    }

    http.Response resp;
    try {
      resp = await _client
          .post(
            Uri.parse('$baseUrl/api/route/reroute'),
            headers: headers,
            body: jsonEncode(<String, dynamic>{
              'origin': <String, double>{'lng': lng, 'lat': lat},
              'polyline': polyline,
              'along_m': alongM,
              'target_m': targetM,
              'completed_m': completedM,
              'heading': ?headingDeg,
              'tol_m': tolM,
              'max_api_calls': maxApiCalls,
            }),
          )
          .timeout(requestTimeout);
    } on RouteApiException {
      rethrow;
    } catch (e) {
      throw RouteApiException('无法连接服务器（网络/后端/Tailscale）：$e',
          code: 'NETWORK');
    }

    Map<String, dynamic>? body;
    try {
      body = jsonDecode(resp.body) as Map<String, dynamic>?;
    } catch (_) {
      body = null;
    }
    if (resp.statusCode == 429 || resp.statusCode == 503) {
      final int retry = int.tryParse(resp.headers['retry-after'] ?? '') ?? 0;
      throw RouteApiException(
        body?['error'] as String? ?? '服务端限流保护中',
        code: body?['error_code'] as String? ??
            (resp.statusCode == 429 ? 'RATE_LIMITED' : 'UPSTREAM_QUOTA'),
        retryAfterS: retry,
      );
    }
    if (resp.statusCode != 200) {
      throw RouteApiException(
        body?['error'] as String? ?? '后端返回 HTTP ${resp.statusCode}',
        code: body?['error_code'] as String? ?? 'HTTP',
      );
    }
    if (body == null || body['success'] != true) {
      throw RouteApiException(
        body?['error'] as String? ?? '重规划失败',
        code: body?['error_code'] as String? ?? 'REROUTE_FAILED',
      );
    }
    return ReroutePlan.fromJson(body);
  }
}
