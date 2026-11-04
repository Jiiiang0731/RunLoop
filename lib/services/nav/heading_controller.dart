import 'dart:math' as math;

/// Heading-Up 相机的方向源仲裁与平滑（阶段 L 模块 D；阶段 L2 增补磁力计辅助）。
///
/// 方向源优先级（磁力计**只作辅助**——跑步摆臂/环境磁干扰不可靠，
/// 绝不能把手机朝向等同为跑步方向，规范四.5）：
/// 1. 高德 GPS 运动方向（仅 locationType==1 时原生层给值）：
///    速度 ≥ [minSpeedGps] 且精度 ≤ [maxAccuracyM] 时采用；
/// 2. 路线投影方位角（窗口化匹配点的路线切线方向）：低速但在路线上时采用，
///    静止起步/慢走也稳定（比磁力计可靠，故排在磁力计之前）；
/// 3. 磁力计（[compassBearing]）：仅当**静止**（速度 < [compassMaxSpeed]）
///    且以上两源都不可用时采用（例如起步前站在岔路口看地图），
///    用慢时间常数 [compassTauSeconds] 平滑，防磁抖；
/// 4. 都不满足：**冻结**当前方向——停止时不做无意义旋转（规范 5.2 明确）。
///
/// 平滑：最短弧 + 指数趋近（时间常数 [tauSeconds]），显式处理 0°/360°
/// 环绕；小角度直接吸附防抖。输出供相机 bearing 与屏幕箭头使用。
class HeadingController {
  HeadingController({
    this.tauSeconds = 0.8,
    this.minSpeedGps = 1.2,
    this.minSpeedRoute = 0.4,
    this.maxAccuracyM = 40,
    this.compassMaxSpeed = 0.6,
    this.compassTauSeconds = 2.0,
  });

  /// 指数平滑时间常数（秒）。越大转向越柔和。
  final double tauSeconds;

  /// 采用 GPS 方向的最低速度（米/秒，约 4.3 km/h 以上才可信）。
  final double minSpeedGps;

  /// 采用路线投影方向的最低速度（米/秒）。
  final double minSpeedRoute;

  /// 采用 GPS 方向的最大定位精度半径（米）。
  final double maxAccuracyM;

  /// 采用磁力计辅助的最高速度（米/秒）：仅在静止时采纳（规范四.2/5）。
  final double compassMaxSpeed;

  /// 磁力计辅助的慢平滑时间常数（秒）：磁抖大，转向要更钝。
  final double compassTauSeconds;

  double? _heading;

  /// 当前平滑后的方向角（度，0=正北，顺时针）；null=尚无可信方向。
  double? get heading => _heading;

  /// 输入一帧状态，返回平滑后的方向角（无更新时返回当前值/ null）。
  ///
  /// [gpsBearing] 仅当定位源为 GPS 时传入（LocationResult 已按 locationType 把关）；
  /// [routeBearing] 为当前匹配点处规划路线切线方位角（RoutePath.at(along).bearing）；
  /// [compassBearing] 为磁力计航向（辅助源，仅静止时采纳）。
  double? update({
    required double speed,
    required double accuracy,
    double? gpsBearing,
    double? routeBearing,
    double? compassBearing,
    required double dtSeconds,
  }) {
    double? target;
    double tau = tauSeconds;
    if (speed >= minSpeedGps &&
        accuracy <= maxAccuracyM &&
        _isValidBearing(gpsBearing)) {
      target = gpsBearing;
    } else if (speed >= minSpeedRoute && _isValidBearing(routeBearing)) {
      target = routeBearing;
    } else if (speed < compassMaxSpeed && _isValidBearing(compassBearing)) {
      // 辅助源：静止且 GPS/路线都不可用（起步前看地图、偏航驻足）
      target = compassBearing;
      tau = compassTauSeconds;
    }
    if (target == null) return _heading; // 冻结：静止/低速/精度差时不旋转

    if (_heading == null) {
      _heading = _normalize(target);
      return _heading;
    }
    if (dtSeconds <= 0) return _heading;

    final double delta = shortestDelta(_heading!, target);
    if (delta.abs() < 0.5) {
      _heading = _normalize(target); // 吸附，消除残差抖动
      return _heading;
    }
    final double alpha = 1 - math.exp(-dtSeconds / tau);
    _heading = _normalize(_heading! + delta * alpha);
    return _heading;
  }

  /// 回到起点/重新开始跟随时重置（下一次可信输入直接定向，不做旋转动画）。
  void reset() => _heading = null;

  /// 强制设定方向（如恢复跑步进程时）。
  void snapTo(double degrees) => _heading = _normalize(degrees);

  static bool _isValidBearing(double? b) => b != null && b >= 0 && b < 360;

  /// 最短角差（-180, 180]：350°→10° 为 +20 而非 -340。
  static double shortestDelta(double from, double to) =>
      ((to - from) % 360 + 540) % 360 - 180;

  /// 归一化到 [0, 360)。
  static double _normalize(double deg) => deg % 360 < 0 ? deg % 360 + 360 : deg % 360;
}
