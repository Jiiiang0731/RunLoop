import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:runloop/models/planned_route.dart';
import 'package:runloop/services/route_api/route_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 规范⑦「失败明确错误提示」+ F 项客户端侧证据：
/// RouteApiService 全部错误路径经 MockClient 实测（不打真实网络）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  const String base = 'https://unit-test.tail120f1d.ts.net';

  RouteApiService svcWith(http.Response Function(http.Request) handler) {
    return RouteApiService(
      baseUrl: base,
      client: MockClient((http.Request req) async => handler(req)),
    );
  }

  /// 中文 JSON 体必须带 charset——http.Response 无 content-type 时默认
  /// latin1，非 ASCII 会直接抛编码异常（真实服务端由 Flask 保证 UTF-8）。
  http.Response jsonResponse(String body, int code,
      {Map<String, String> extra = const <String, String>{}}) {
    return http.Response(body, code, headers: <String, String>{
      'content-type': 'application/json; charset=utf-8',
      ...extra,
    });
  }

  group('错误路径（用户可见的中文提示）', () {
    test('未配置地址 → NOT_CONFIGURED（离线优先模式，绝不静默）', () async {
      final RouteApiService svc = RouteApiService(
        baseUrl: '',
        client: MockClient((http.Request req) async => http.Response('{}', 200)),
      );
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 5000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NOT_CONFIGURED')
            .having((RouteApiException e) => e.message, 'message',
                contains('未配置服务器地址'))),
      );
    });

    test('502 非 JSON 体（Serve 后端宕机场景）→「后端返回 HTTP 502」', () async {
      // F 项真实场景：Tailscale Serve 在后端停止时回 502 空体/HTML
      final RouteApiService svc =
          svcWith((http.Request req) => http.Response('', 502));
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 5000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.message, 'message',
                '后端返回 HTTP 502')
            .having((RouteApiException e) => e.code, 'code', 'HTTP')),
      );
    });

    test('429 限流 → Retry-After 转人类可读等待', () async {
      final RouteApiService svc = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'error': '请求过于频繁，请稍后重试',
              'error_code': 'RATE_LIMITED',
            }),
            429,
            extra: <String, String>{'retry-after': '120'},
          ));
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 5000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'RATE_LIMITED')
            .having((RouteApiException e) => e.retryAfterS, 'retry', 120)
            .having((RouteApiException e) => e.message, 'message',
                allOf(contains('请求过于频繁'), contains('2 分钟')))),
      );
    });

    test('503 熔断 → UPSTREAM_QUOTA + 自动恢复提示', () async {
      final RouteApiService svc = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'error': '高德配额熔断保护中（上游限流），请稍后重试',
              'error_code': 'UPSTREAM_QUOTA',
            }),
            503,
            extra: <String, String>{'retry-after': '90'},
          ));
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 5000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'UPSTREAM_QUOTA')
            .having((RouteApiException e) => e.retryAfterS, 'retry', 90)
            .having((RouteApiException e) => e.message, 'message',
                contains('自动恢复'))),
      );
    });

    test('网络不可达 → NETWORK 中文兜底（含底层原因）', () async {
      final RouteApiService svc = RouteApiService(
        baseUrl: base,
        client: MockClient((http.Request req) async {
          throw http.ClientException('Failed host lookup');
        }),
      );
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 5000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NETWORK')
            .having((RouteApiException e) => e.message, 'message',
                allOf(contains('无法连接服务器'), contains('Failed host lookup')))),
      );
    });

    test('业务失败信封（success=false）→ 原样传递服务端中文错误', () async {
      final RouteApiService svc = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'success': false,
              'error': '所有种子均未达标（±500m），请调整目标距离或起点',
              'error_code': 'NO_CANDIDATE',
            }),
            200,
          ));
      await expectLater(
        svc.generate(lng: 114.087279, lat: 30.536395, targetM: 15000),
        throwsA(isA<RouteApiException>()
            .having((RouteApiException e) => e.code, 'code', 'NO_CANDIDATE')
            .having((RouteApiException e) => e.message, 'message',
                contains('所有种子均未达标'))),
      );
    });
  });

  group('成功路径与辅助端点', () {
    test('generate 200 → 解析候选（仅收 ok=true）', () async {
      final PlannedRoute full = const PlannedRoute(
        seed: 2,
        distanceM: 5120.5,
        errorM: 120.5,
        withinTolerance: true,
        closureM: 0.5,
        closureOk: true,
        score: 46.6,
        nPoints: 3,
        polyline: <List<double>>[
          <double>[114.087279, 30.536395],
          <double>[114.090100, 30.537200],
          <double>[114.087279, 30.536395],
        ],
        scoreComponents: <ScoreItem>[],
        steps: <RouteStep>[],
      );
      final Map<String, dynamic> cand =
          jsonDecode(jsonEncode(full.toJson())) as Map<String, dynamic>;
      cand['ok'] = true;
      final RouteApiService svc = svcWith((http.Request req) => http.Response(
            jsonEncode(<String, dynamic>{
              'success': true,
              'candidates': <dynamic>[cand],
              'elapsed_s': 12.3,
              'total_api_calls': 55,
              'target_m': 5000,
              'tol_m': 500,
            }),
            200,
          ));
      final RouteGenResult r = await svc.generate(
          lng: 114.087279, lat: 30.536395, targetM: 5000);
      expect(r.routes.length, 1);
      expect(r.routes.first.distanceM, 5120.5);
      expect(r.apiCalls, 55);
    });

    test('请求头带 X-Device-Id（服务端按设备配额）', () async {
      String? seen;
      final RouteApiService svc = RouteApiService(
        baseUrl: base,
        client: MockClient((http.Request req) async {
          seen = req.headers['X-Device-Id'];
          return http.Response('{"status":"ok"}', 200);
        }),
      );
      expect(await svc.ping(), isTrue);
      expect(seen, startsWith('rl-'));
    });

    test('ping：200 → true；异常 → false（不抛出）', () async {
      expect(
          await svcWith((http.Request req) => http.Response('{}', 200)).ping(),
          isTrue);
      final RouteApiService bad = RouteApiService(
        baseUrl: base,
        client: MockClient((http.Request req) async {
          throw http.ClientException('down');
        }),
      );
      expect(await bad.ping(), isFalse);
      expect(await RouteApiService(baseUrl: '').ping(), isFalse);
    });

    test('fetchClientConfig：成功返回 config；非 200/异常 → null（增强非依赖）',
        () async {
      final RouteApiService ok = svcWith((http.Request req) => jsonResponse(
            jsonEncode(<String, dynamic>{
              'success': true,
              'config': <String, dynamic>{
                'announcement': '维护通知',
                'generate': <String, dynamic>{'max_api_calls': 800},
              },
            }),
            200,
          ));
      final Map<String, dynamic>? cfg = await ok.fetchClientConfig();
      expect(cfg, isNotNull);
      expect(cfg!['announcement'], '维护通知');
      expect(
          await svcWith((http.Request req) => http.Response('', 500))
              .fetchClientConfig(),
          isNull);
      expect(await RouteApiService(baseUrl: '').fetchClientConfig(), isNull);
    });
  });
}
