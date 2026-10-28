import 'dart:async';

import 'package:amap_flutter_location/amap_flutter_location.dart';
import 'package:amap_flutter_location/amap_location_option.dart';

import '../../app/config.dart';
import '../../models/location_result.dart';

/// 高德定位封装（单例）。
///
/// - 坐标系：高德 GCJ-02，与 amap_flutter_map 一致，无需转换。
/// - 通过 [stream] 对外广播定位结果，可供地图显示与跑步记录同时订阅。
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  final AMapFlutterLocation _location = AMapFlutterLocation();
  final StreamController<LocationResult> _controller =
      StreamController<LocationResult>.broadcast();
  StreamSubscription<Map<String, Object>>? _subscription;
  bool _started = false;

  /// 必须在调用定位前执行一次（隐私合规 + 设置 Key）。
  static void init() {
    AMapFlutterLocation.updatePrivacyShow(true, true);
    AMapFlutterLocation.updatePrivacyAgree(true);
    AMapFlutterLocation.setApiKey(AppConfig.amapAndroidKey, AppConfig.amapIosKey);
  }

  /// 定位结果流。
  Stream<LocationResult> get stream => _controller.stream;

  /// 是否已开始定位。
  bool get isStarted => _started;

  /// 开始持续定位。
  void start({int intervalMs = AppConfig.locationIntervalMs}) {
    if (_started) return;
    final option = AMapLocationOption(
      locationInterval: intervalMs,
      needAddress: false,
      onceLocation: false,
      locationMode: AMapLocationMode.Hight_Accuracy,
    );
    _location.setLocationOption(option);
    _subscription = _location.onLocationChanged().listen((Map<String, Object> map) {
      _controller.add(LocationResult.fromMap(map));
    });
    _location.startLocation();
    _started = true;
  }

  /// 停止定位（不销毁实例，可再次 start）。
  void stop() {
    _location.stopLocation();
    _started = false;
  }

  /// 彻底销毁（页面退出时调用）。
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _controller.close();
    _location.destroy();
    _started = false;
  }
}
