import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:runloop/services/route_api/reroute_api.dart';
import 'package:runloop/services/route_api/route_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 重规划客户端契约测试（阶段 M-D，任务书 5.6/5.7）——MockClient 离线驱动，
/// 绝不打真实网络；覆盖成功解析、失败错误码、限流、断网回退。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const String base = 'https://unit-test.your-tailnet.ts.net';

  RerouteClient svcWith(http.Response Function(http.Request) handler) {
    return RerouteClient(
      baseUrl: base,
      client: MockClient((http.Request req) async => handler(req)),
    );
  }

  http.Response jsonResponse(String body, int code,
          {Map<String, String> extra = const <String, String>{}}) =>
      http.Response(body, code, headers: <String, String>{
        'content-type': 'application/json; charset=utf-8',
        ...extra,
      });

  final Map<String, dynamic> okBody = <String, dynamic>{
    'success': true,
    'reroute_id': 'rr-abc1234567',
    'connector': <String, dynamic>{
      'polyline': <List<double>>[
        <double>[116.0035, 39.9006],
        <double>[116.004, 39.9],
      ],
      'distance_m': 123.4,
      'duration_s': 100.0,
      'steps': <Map<String, dynamic>>[
        <String, dynamic>{
          'instruction': '沿测试路东行，到达接回点',
          'text': '沿测试路东行',
          'road': '测试路',
          'distance_m': 123.4,
          'cumulative_m': 123.4,
          'action': 'end',
          'turn': 'end',
          'orientation': '',
          'junction': '',
          'polyline': <dynamic>[],
        },
      ],
    },
    'rejoin': <String, dynamic>{
      'lng': 116.004,
      'lat': 39.9,
      'along_m': 500.0,
      'skipped_m': 200.0,
    },
    'merged_remaining_polyline': <List<double>>[
      <double>[116.0035, 39.9006],
      <double>[116.004, 39.9],
      <double>[116.01, 39.9],
    ],
    'remaining_m': 900.0,
    'estimated_total_m': 1500.0,
    'target_m': 1500.0,
    'tol_m': 500.0,
    'within_tolerance': true,
    'candidates_evaluated': <dynamic>[],
    'api_calls': 3,
    'elapsed_s': 1.2,
  };

  Future<ReroutePlan> call(RerouteClient c) => c.request(
        lng: 116.0035,
        lat: 39.9006,
        polyline: <List<double>>[
          <double>[116.0, 39.9],
          <double>[116.01, 39.9],
        ],
        alongM: 300,
        targetM: 1500,
        completedM: 300,
        headingDeg: 90,
      );

  group('成功契约（5.6 响应字段全解析）', () {
    test('解析连接段/接回点/合并路线/诚实里程/容差标记', () async {
      Map<String, dynamic>? sentBody;
      final RerouteClient c = svcWith((http.Request req) {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return jsonResponse(jsonEncode(okBody), 200);
      });
      final ReroutePlan plan = await call(c);
      // ---- 请求体契约 ----
      expect(sentBody, isNotNull);
      expect(sentBody!['origin'], <String, double>{'lng': 116.0035, 'lat': 39.9006});
      expect(sentBody!['along_m'], 300);
      expect(sentBody!['target_m'], 1500);
      expect(sentBody!['completed_m'], 300);
      expect(sentBody!['heading'], 90);
      expect(sentBody!['tol_m'], 500);
      expect(sentBody!['max_api_calls'], 5);
      // ---- 响应解析 ----
      expect(plan.rerouteId, 'rr-abc1234567');
      expect(plan.connectorM, 123.4);
      expect(plan.connectorPolyline.length, 2);
      expect(plan.connectorSteps.single.road, '测试路');
      expect(plan.connectorSteps.single.cumulativeM, 123.4);
      expect(plan.rejoinAlongM, 500.0);
      expect(plan.skippedM, 200.0);
      expect(plan.mergedRemainingPolyline.length, 3);
      expect(plan.remainingM, 900.0);
      expect(plan.estimatedTotalM, 1500.0);
      expect(plan.withinTolerance, isTrue);
      expect(plan.apiCalls, 3);
      expect(plan.elapsedS, 1.2);
      // 旧响应没有前向字段 → 默认 legacy，不误判
      expect(plan.strategy, 'legacy');
      expect(plan.isForward, isFalse);
      expect(plan.forwardAcceptable, isTrue);
    });

    test('阶段 Q：前向请求体与响应字段完整解析', () async {
      Map<String, dynamic>? sentBody;
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final Map<String, dynamic> forwardBody = <String, dynamic>{
        ...okBody,
        'strategy': 'forward_rejoin',
        'request_id': 'req-7',
        'actual_along_m': 420.0,
        'heading_used': 88.0,
        'heading_source': 'recent_points',
        'heading_confidence': 0.9,
        'connector': <String, dynamic>{
          ...(okBody['connector'] as Map<String, dynamic>),
          'initial_angle_deg': 12.5,
          'forward_gain_m': 48.0,
          'backtrack_m': 0.0,
          'forward_ok': true,
        },
        'rejoin': <String, dynamic>{
          ...(okBody['rejoin'] as Map<String, dynamic>),
          'actual_along_m': 420.0,
          'forward_gain_m': 48.0,
          'backtrack_m': 0.0,
          'forward_ok': true,
        },
      };
      final RerouteClient c = svcWith((http.Request req) {
        sentBody = jsonDecode(req.body) as Map<String, dynamic>;
        return jsonResponse(jsonEncode(forwardBody), 200);
      });
      final ReroutePlan plan = await c.request(
        lng: 116.0035,
        lat: 39.9006,
        polyline: <List<double>>[
          <double>[116.0, 39.9],
          <double>[116.01, 39.9],
        ],
        alongM: 300,
        targetM: 1500,
        completedM: 300,
        headingDeg: 88,
        headingSource: 'recent_points',
        headingConfidence: 0.9,
        headingAgeMs: 120,
        speedMps: 3.1,
        accuracyM: 6,
        offsetM: 65,
        recentPoints: <List<double>>[
          <double>[116.0040, 39.9006, 6, 3.1, (nowMs - 4000).toDouble()],
          <double>[116.0045, 39.9006, 6, 3.1, nowMs.toDouble()],
        ],
        routeEnd: <double>[116.01, 39.9],
        originalTotalM: 938,
        forwardOnly: true,
        requestId: 'req-7',
        sentAtMs: nowMs,
        maxApiCalls: 6,
      );
      expect(sentBody!['forward_only'], isTrue);
      expect(sentBody!['heading_source'], 'recent_points');
      expect(sentBody!['heading_confidence'], 0.9);
      expect(sentBody!['heading_age_ms'], 120);
      expect(sentBody!['speed_mps'], 3.1);
      expect(sentBody!['accuracy_m'], 6);
      expect(sentBody!['offset_m'], 65);
      expect((sentBody!['recent_points'] as List<dynamic>).length, 2);
      expect(sentBody!['route_end'], <double>[116.01, 39.9]);
      expect(sentBody!['original_total_m'], 938);
      expect(sentBody!['request_id'], 'req-7');
      expect(sentBody!['max_api_calls'], 6);
      expect(plan.strategy, 'forward_rejoin');
      expect(plan.isForward, isTrue);
      expect(plan.requestId, 'req-7');
      expect(plan.actualAlongM, 420);
      expect(plan.headingSource, 'recent_points');
      expect(plan.headingConfidence, 0.9);
      expect(plan.connectorInitialAngleDeg, 12.5);
      expect(plan.connectorForwardGainM, 48);
      expect(plan.connectorBacktrackM, 0);
      expect(plan.connectorForwardOk, isTrue);
      expect(plan.rejoinForwardOk, isTrue);
      expect(plan.forwardAcceptable, isTrue);
    });

    test('阶段 Q：首段明显掉头/回退 → 客户端拒绝应用', () {
      final Map<String, dynamic> bad = <String, dynamic>{
        ...okBody,
        'strategy': 'forward_rejoin',
        'connector': <String, dynamic>{
          ...(okBody['connector'] as Map<String, dynamic>),
          'initial_angle_deg': 150.0,
          'backtrack_m': 40.0,
          'forward_ok': false,
        },
        'rejoin': <String, dynamic>{
          ...(okBody['rejoin'] as Map<String, dynamic>),
          'forward_ok': false,
        },
      };
      final ReroutePlan plan = ReroutePlan.fromJson(bad);
      expect(plan.isForward, isTrue);
      expect(plan.forwardAcceptable, isFalse);
    });
  });

  group('失败路径（5.7#9：断网/限流/无接入点全部显式）', () {
    test('success=false NO_REJOIN → RouteApiException(code=NO_REJOIN)', () async {
      final RerouteClient c = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'success': false,
              'error_code': 'NO_REJOIN',
              'error': '所有候选接回点均无法步行到达',
              'reroute_id': 'rr-x',
            }),
            200,
          ));
      await expectLater(
        call(c),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NO_REJOIN')
            .having((RouteApiException e) => e.message, 'message',
                contains('无法步行到达'))),
      );
    });

    test('429 限流 → RATE_LIMITED + retryAfterS', () async {
      final RerouteClient c = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'success': false,
              'error_code': 'RATE_LIMITED',
              'error': '请求过于频繁，请稍后重试',
            }),
            429,
            extra: <String, String>{'retry-after': '42'},
          ));
      await expectLater(
        call(c),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'RATE_LIMITED')
            .having((RouteApiException e) => e.retryAfterS, 'retry', 42)),
      );
    });

    test('连接异常（断网/Tailscale 断开）→ NETWORK', () async {
      final RerouteClient c = RerouteClient(
        baseUrl: base,
        client: MockClient(
            (http.Request req) async => throw http.ClientException('socket hang up')),
      );
      await expectLater(
        call(c),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NETWORK')
            .having((RouteApiException e) => e.message, 'message',
                contains('无法连接服务器'))),
      );
    });

    test('未配置后端地址 → NOT_CONFIGURED（绝不静默）', () async {
      final RerouteClient c = RerouteClient(
        baseUrl: '',
        client: MockClient((http.Request req) async => http.Response('{}', 200)),
      );
      await expectLater(
        call(c),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NOT_CONFIGURED')),
      );
    });

    test('502 非 JSON 体（后端宕机）→ HTTP + 状态码信息', () async {
      final RerouteClient c =
          svcWith((http.Request req) => http.Response('', 502));
      await expectLater(
        call(c),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'HTTP')
            .having(
                (RouteApiException e) => e.message, 'message', contains('502'))),
      );
    });
  });
}
