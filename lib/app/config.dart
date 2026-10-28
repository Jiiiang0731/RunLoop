/// 应用配置。
///
/// 注意：这里只放「Android 地图 SDK Key」（绑定包名+SHA1，随 APK 分发，非私密凭证）。
/// Web 服务 Key（用于路径规划）属私密凭证，严禁写在这里，应从后端或 --dart-define 注入。
class AppConfig {
  AppConfig._();

  /// 高德 Android 平台 SDK Key（地图 + 定位）。
  ///
  /// 通过 `--dart-define=AMAP_ANDROID_KEY=...` 在构建时注入，避免密钥入库；
  /// 同值同时写入 android/amap_key.properties（已 gitignore）供 manifest 占位符注入。
  static const String amapAndroidKey =
      String.fromEnvironment('AMAP_ANDROID_KEY', defaultValue: '');

  /// iOS Key（预留，暂未申请）。
  static const String amapIosKey =
      String.fromEnvironment('AMAP_IOS_KEY', defaultValue: '');

  /// 定位采集间隔（毫秒）。
  static const int locationIntervalMs = 2000;

  /// 路线规划后端地址（可配置为局域网或公网 HTTPS）。
  ///
  /// 构建时用 `--dart-define=ROUTE_API_BASE_URL=http://<电脑局域网IP>:8000` 覆盖；
  /// 后续可切换为公网 HTTPS 地址。
  static const String routeApiBaseUrl = String.fromEnvironment(
    'ROUTE_API_BASE_URL',
    defaultValue: 'http://192.168.1.100:8000',
  );
}
