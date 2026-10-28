import '../../models/track_point.dart';
import '../../utils/geo.dart';

/// GPS 漂移 / 跳点 / 丢失的基本过滤。
class GpsFilter {
  /// 允许的最大定位精度（米），超过则丢弃。
  final double maxAccuracyMeters;

  /// 相邻两点允许的最大距离（米），超过视为跳点丢弃。
  final double maxJumpMeters;

  /// 判定为「移动」的最小速度（米/秒）。
  final double minMovingSpeed;

  const GpsFilter({
    this.maxAccuracyMeters = 50,
    this.maxJumpMeters = 100,
    this.minMovingSpeed = 0.5,
  });

  /// 判断该点是否应被接受（相对上一个点）。
  ///
  /// 返回 [GpsFilterDecision]，包含是否接受、与上一点距离、是否算移动。
  GpsFilterDecision evaluate(TrackPoint point, TrackPoint? previous) {
    // 精度太差 -> 丢弃
    if (point.accuracy > maxAccuracyMeters) {
      return const GpsFilterDecision(accepted: false);
    }
    if (previous == null) {
      return const GpsFilterDecision(accepted: true);
    }
    final double d = haversineMeters(
      previous.latitude,
      previous.longitude,
      point.latitude,
      point.longitude,
    );
    // 跳点 -> 丢弃
    if (d > maxJumpMeters) {
      return GpsFilterDecision(accepted: false, distanceMeters: d);
    }
    final double dt = point.timestamp.difference(previous.timestamp).inSeconds.toDouble();
    final double speed = dt > 0 ? d / dt : 0;
    return GpsFilterDecision(
      accepted: true,
      distanceMeters: d,
      isMoving: speed >= minMovingSpeed,
    );
  }
}

/// 过滤判定结果。
class GpsFilterDecision {
  final bool accepted;
  final double distanceMeters;
  final bool isMoving;

  const GpsFilterDecision({
    required this.accepted,
    this.distanceMeters = 0,
    this.isMoving = false,
  });
}
