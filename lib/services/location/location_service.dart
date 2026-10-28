import 'dart:async';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';

import '../../app/config.dart';
import '../../models/location_result.dart';

/// 定位状态。
enum LocationStatus { idle, waiting, success, failed, timeout }

/// 高德定位封装（单例）。
///
/// 关键修复：必须先订阅 [start] 内的 `onLocationChanged()`，再 `setLocationOption`。
/// 否则原生 client 创建时 sink 为 null，定位结果会被丢弃（表现为一直「定位中」）。
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  final AMapFlutterLocation _location = AMapFlutterLocation();
  final StreamController<LocationResult> _controller =
      StreamController<LocationResult>.broadcast();
  StreamSubscription<Map<String, Object>>? _subscription;
  bool _started = false;

  // ---- 诊断状态 ----
  LocationStatus status = LocationStatus.idle;
  LocationResult? lastResult;
  DateTime? requestStartTime;
  DateTime? lastCallbackAt;
  String? errorDetail;

  static void init() {
    AMapFlutterLocation.updatePrivacyShow(true, true);
    AMapFlutterLocation.updatePrivacyAgree(true);
    AMapFlutterLocation.setApiKey(AppConfig.amapAndroidKey, AppConfig.amapIosKey);
  }

  Stream<LocationResult> get stream => _controller.stream;
  bool get isStarted => _started;

  /// 开始持续定位。
  void start({int intervalMs = AppConfig.locationIntervalMs}) {
    if (_started) {
      // 已开始：只重置状态并重新请求。
      status = LocationStatus.waiting;
      requestStartTime = DateTime.now();
      return;
    }
    status = LocationStatus.waiting;
    requestStartTime = DateTime.now();
    lastCallbackAt = null;
    errorDetail = null;

    // 1) 先订阅事件流（触发原生 onListen 注册 EventSink），必须早于 client 创建。
    _subscription = _location.onLocationChanged().listen((Map<String, Object> map) {
      final LocationResult result = LocationResult.fromMap(map);
      lastCallbackAt = DateTime.now();
      if (result.hasError) {
        status = LocationStatus.failed;
        errorDetail = 'errorCode=${result.errorCode}, errorInfo=${result.errorInfo}';
      } else {
        status = LocationStatus.success;
        lastResult = result;
        errorDetail = null;
      }
      _controller.add(result);
    });

    // 2) 设置定位参数（此时创建 locationClient，会拿到已注册的 EventSink）。
    _location.setLocationOption(AMapLocationOption(
      locationInterval: intervalMs,
      needAddress: false,
      onceLocation: false,
      locationMode: AMapLocationMode.Hight_Accuracy,
    ));

    // 3) 开始定位。
    _location.startLocation();
    _started = true;
  }

  /// 停止定位（不销毁实例，可再次 start）。
  void stop() {
    _location.stopLocation();
    _started = false;
  }

  /// 彻底销毁（页面永久退出时调用）。
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _controller.close();
    _location.destroy();
    _started = false;
  }
}
