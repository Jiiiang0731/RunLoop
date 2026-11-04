import 'dart:math' as math;

import 'package:amap_flutter_base/amap_flutter_base.dart';

import 'heading_controller.dart' show HeadingController;

/// 20Hz 导航相机的一帧输出：应当下发的相机位姿。
class FollowCameraStep {
  const FollowCameraStep({
    required this.position,
    required this.bearing,
    required this.zoom,
  });

  final LatLng position;

  /// 屏幕上方对应的罗盘方向，[0,360) 顺时针（高德 CameraPosition.bearing 语义：
  /// 「可视区域指向的方向，从正北顺时针」——插件 ConvertUtil 直接透传给原生
  /// CameraPosition.Builder.bearing，因此 bearing=行进方向 ⇒ 行进方向在屏幕正上方）。
  final double bearing;

  final double zoom;
}

/// 导航相机插值模型（纯计算、可单测；阶段 L2 Heading-Up 整改核心）。
///
/// 设计动机：GPS/方向以 ~1Hz 更新，若每次更新直接 moveCamera，地图会
/// 每秒跳一格（旧实现的真机观感问题）。本模型把「目标位姿」（setGoal，
/// 1Hz）与「渲染位姿」（tick，~20Hz）分离：每帧向目标指数逼近，平移、
/// 旋转、缩放都连续平滑，像专业导航一样；死区内返回 null，调用方跳过
/// moveCamera（省原生桥调用、消除静止时的微抖）。
///
/// 角度处理与 HeadingController 同一套数学：最短弧 + [0,360) 归一化，
/// 359°→1° 走 +2° 而不是 -358°。
class FollowCamera {
  FollowCamera({
    this.posTauSeconds = 0.30,
    this.bearingTauSeconds = 0.25,
    this.zoomTauSeconds = 0.90,
    this.posDeadZoneM = 0.15,
    this.bearingDeadZoneDeg = 0.2,
    this.zoomDeadZone = 0.02,
  });

  /// 位置平滑时间常数（秒）。0.30s：4m/s 跑步时滞后 ≈1.2m，
  /// 视觉连续且每个新定位点到来后迅速收敛到真实坐标。
  final double posTauSeconds;
  final double bearingTauSeconds;
  final double zoomTauSeconds;
  final double posDeadZoneM;
  final double bearingDeadZoneDeg;
  final double zoomDeadZone;

  LatLng? _pos;
  double? _bearing;
  double? _zoom;

  LatLng? _goalPos;
  double? _goalBearing;
  double? _goalZoom;

  LatLng? get position => _pos;
  double? get bearing => _bearing;
  double? get zoom => _zoom;
  bool get hasPose => _pos != null;

  /// 1Hz 目标更新（不立即动相机；下一帧起由 [tick] 平滑逼近）。
  void setGoal({required LatLng target, double? bearing, double? zoom}) {
    _goalPos = target;
    if (bearing != null) _goalBearing = normalizeDeg(bearing);
    if (zoom != null) _goalZoom = zoom;
  }

  /// 直接落位（GO 首帧、回中、采纳用户捏合缩放）：跳过动画防「绕路」。
  /// 传 null 的分量保持当前值。
  void snap({LatLng? target, double? bearing, double? zoom}) {
    if (target != null) _pos = target;
    if (bearing != null) _bearing = normalizeDeg(bearing);
    if (zoom != null) _zoom = zoom;
  }

  /// 推进一帧。[dtSeconds] 为距上一帧的秒数。
  /// 返回 null 表示仍在死区内（调用方不要 moveCamera）。
  FollowCameraStep? tick(double dtSeconds) {
    final LatLng? gp = _goalPos;
    if (gp == null) return null;
    final double dt = dtSeconds <= 0 ? 1 / 60 : dtSeconds;

    if (_pos == null) {
      // 首帧：直接落位（起跑瞬间不做飞行动画；GO 过渡动画由调用方单独下发）。
      _pos = gp;
      _bearing ??= _goalBearing ?? 0;
      _zoom ??= _goalZoom ?? 17;
      return FollowCameraStep(position: _pos!, bearing: _bearing!, zoom: _zoom!);
    }

    bool changed = false;

    // ---- 位置：度空间线性插值（米级距离下与测地线差异可忽略） ----
    final double distM = haversine(_pos!, gp);
    if (distM > posDeadZoneM) {
      final double a = 1 - math.exp(-dt / posTauSeconds);
      _pos = LatLng(
        _pos!.latitude + (gp.latitude - _pos!.latitude) * a,
        _pos!.longitude + (gp.longitude - _pos!.longitude) * a,
      );
      if (haversine(_pos!, gp) <= posDeadZoneM) _pos = gp; // 收尾吸附
      changed = true;
    }

    // ---- 朝向：最短弧指数平滑 ----
    final double? gb = _goalBearing;
    if (gb != null) {
      final double d = HeadingController.shortestDelta(_bearing!, gb);
      if (d.abs() > bearingDeadZoneDeg) {
        final double a = 1 - math.exp(-dt / bearingTauSeconds);
        double nb = _bearing! + d * a;
        if (HeadingController.shortestDelta(nb, gb).abs() <= bearingDeadZoneDeg) {
          nb = gb; // 收尾吸附
        }
        _bearing = normalizeDeg(nb);
        changed = true;
      }
    }

    // ---- 缩放：慢时间常数，避免转弯加缩放的双重 distract ----
    final double? gz = _goalZoom;
    if (gz != null && (_zoom! - gz).abs() > zoomDeadZone) {
      final double a = 1 - math.exp(-dt / zoomTauSeconds);
      double nz = _zoom! + (gz - _zoom!) * a;
      if ((nz - gz).abs() <= zoomDeadZone) nz = gz;
      _zoom = nz;
      changed = true;
    }

    if (!changed) return null;
    return FollowCameraStep(position: _pos!, bearing: _bearing!, zoom: _zoom!);
  }

  static double normalizeDeg(double deg) => ((deg % 360) + 360) % 360;

  static double haversine(LatLng a, LatLng b) {
    const double R = 6371000.0;
    final double dLat = (b.latitude - a.latitude) * math.pi / 180;
    final double dLng = (b.longitude - a.longitude) * math.pi / 180;
    final double lat1 = a.latitude * math.pi / 180;
    final double lat2 = b.latitude * math.pi / 180;
    final double h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * R * math.asin(math.min(1.0, math.sqrt(h)));
  }
}
