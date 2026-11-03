import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;

/// 应用配置（阶段 K：单一来源 BASE_URL + DEBUG/PRODUCTION 环境分离）。
///
/// 密钥边界：这里只放「Android 地图 SDK Key」（绑定包名+SHA1，随 APK 分发，
/// 非私密凭证）。高德 Web 服务 Key（路径规划）属私密凭证，只存在后端电脑
/// （RUNLOOP_AMAP_KEY 或 config/amap_key.local），严禁进 APK/Git/日志。
///
/// 后端地址解析优先级（[routeApiBaseUrl] 单一来源，全 App 只从这里取）：
/// 1. release 构建：仅认 `--dart-define=TAILNET_BASE_URL=https://<机器>.<尾网>.ts.net`
///    （Tailscale Serve 的真实 MagicDNS HTTPS 地址，装机验证后注入；
///    **绝不编造、绝不回落局域网**——未注入则 [isServerConfigured]=false，
///    App 进入离线优先模式并明确提示，而不是假装能联网）。
/// 2. debug 构建：`--dart-define=ROUTE_API_BASE_URL=...` 显式覆盖 >
///    TAILNET_BASE_URL（便于 debug 包联调 Tailnet）> 局域网默认值。
class AppConfig {
  AppConfig._();

  /// 高德 Android 平台 SDK Key（地图 + 定位），构建时注入避免入库。
  static const String amapAndroidKey =
      String.fromEnvironment('AMAP_ANDROID_KEY', defaultValue: '');

  /// iOS Key（预留，暂未申请）。
  static const String amapIosKey =
      String.fromEnvironment('AMAP_IOS_KEY', defaultValue: '');

  /// 定位采集间隔（毫秒）。
  static const int locationIntervalMs = 2000;

  // ---------------- 后端地址（DEBUG / PRODUCTION 双配置，便于切换） ----------------

  /// 局域网调试地址（仅 debug 构建可达；电脑端需 RUNLOOP_HOST=0.0.0.0 起服务）。
  static const String lanBaseUrl = String.fromEnvironment(
    'LAN_BASE_URL',
    defaultValue: 'http://192.168.1.100:8000',
  );

  /// Tailscale Serve HTTPS 地址（正式版唯一合法来源）。
  /// 默认空 = 未配置：装机验证拿到真实 MagicDNS 地址后由构建命令注入。
  static const String tailnetBaseUrl =
      String.fromEnvironment('TAILNET_BASE_URL', defaultValue: '');

  /// 显式覆盖（仅 debug 构建生效；release 忽略，防止把局域网地址带进正式版）。
  static const String _overrideBaseUrl =
      String.fromEnvironment('ROUTE_API_BASE_URL', defaultValue: '');

  /// 单一来源：全 App 一律通过此 getter 取后端地址。
  static String get routeApiBaseUrl {
    if (kReleaseMode) {
      return _validTailnet(tailnetBaseUrl) ? tailnetBaseUrl : '';
    }
    if (_overrideBaseUrl.isNotEmpty) {
      return _overrideBaseUrl;
    }
    if (_validTailnet(tailnetBaseUrl)) {
      return tailnetBaseUrl;
    }
    return kDebugMode ? lanBaseUrl : '';
  }

  /// 后端地址是否可用（false → 离线优先模式：已存路线可用，生成功能明确报错）。
  static bool get isServerConfigured => routeApiBaseUrl.isNotEmpty;

  /// 正式地址必须是 Tailscale HTTPS（ts.net 域或任意 https），拒绝
  /// http://、localhost、回环与私有网段——从源头杜绝「局域网冒充正式版」。
  static bool _validTailnet(String url) {
    if (url.isEmpty || !url.startsWith('https://')) {
      return false;
    }
    final String host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty ||
        host == 'localhost' ||
        host.startsWith('127.') ||
        host.startsWith('10.') ||
        host.startsWith('192.168.')) {
      return false;
    }
    return true;
  }

  // ---------------- 跑步判定阈值（决策#6：集中配置） ----------------

  /// 偏航判定距离（米）。GPS 漂移经验值，未做长距离实跑标定；
  /// 调大→少误报但真偏航发现晚，调小→反之。改动请同步跑 Dart 测试。
  static const double offRouteMeters = 120;

  /// 投影匹配窗口（米）：GPS 点在路线上的最近点搜索半径（前后各此距离）。
  static const double matchWindowM = 250;

  // ---------------- 生成请求默认值（与服务端默认保持一致） ----------------

  /// 单次生成允许的服务端高德调用预算（质量优先，阶段 K 决策#2）。
  static const int defaultMaxApiCalls = 800;

  /// 生成请求客户端超时（服务端最坏路径：3 seed × 变体 × 绕行重校 ≈ 3 分钟）。
  static const Duration generateTimeout = Duration(seconds: 240);
}
