import 'dart:async';

import 'package:flutter_compass/flutter_compass.dart';

/// 磁力计航向源——**仅作辅助**（阶段 L2 规范四.5）。
///
/// 使用铁律：只有「静止（速度低于阈值）且无路线切线方向」时才会被
/// HeadingController 采纳（且用 2s 慢时间常数平滑）。跑动中摆臂/身位
/// 会严重干扰磁力计，绝不能把手机朝向等同为跑步方向（规范四.2/5）。
///
/// 无传感器或通道失败的机型自动降级：heading 恒为 null，主流程不受影响。
class CompassSource {
  CompassSource({
    Stream<CompassEvent>? Function()? eventsProvider,
    DateTime Function()? clock,
  })  : _eventsProvider = eventsProvider ?? _defaultEvents,
        _clock = clock ?? DateTime.now;

  static Stream<CompassEvent>? _defaultEvents() => FlutterCompass.events;

  final Stream<CompassEvent>? Function() _eventsProvider;
  final DateTime Function() _clock;

  /// 数据过期时间：磁力计事件通常 ~5-20Hz，2 秒无数据视为不可用。
  static const Duration expireAfter = Duration(seconds: 2);

  StreamSubscription<CompassEvent>? _sub;
  double? _heading;
  DateTime? _lastAt;
  bool _failed = false;

  /// 最近一次有效航向（0-360，正北顺时针）；过期或不可用返回 null。
  double? get heading {
    final double? h = _heading;
    final DateTime? t = _lastAt;
    if (h == null || t == null) return null;
    if (_clock().difference(t) > expireAfter) return null;
    return h;
  }

  /// 通道是否已失败（无传感器机型）：仅用于诊断，不影响功能。
  bool get failed => _failed;

  void start() {
    if (_sub != null || _failed) return;
    final Stream<CompassEvent>? s = _eventsProvider();
    if (s == null) {
      _failed = true;
      return;
    }
    _sub = s.listen(
      (CompassEvent e) {
        final double? h = e.heading;
        // 注意：e.accuracy 在 Android 上是硬编码近似值（见插件源码注释），
        // 故不做精度过滤，可靠性由 HeadingController 的静止门控保证。
        if (h == null || h < 0 || h >= 360) return;
        _heading = h;
        _lastAt = _clock();
      },
      onError: (Object _) {
        _failed = true;
        _heading = null;
        _lastAt = null;
      },
    );
  }

  void dispose() {
    unawaited(_sub?.cancel());
    _sub = null;
    _heading = null;
    _lastAt = null;
  }
}
