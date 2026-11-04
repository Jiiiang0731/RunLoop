import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 屏幕固定的居中导航箭头（阶段 L2 整改，规范三）。
///
/// 为什么不用 AMap Marker：真机观察证实普通 Marker 会随地图 bearing 一起
/// 旋转（rotateAngle 语义无法在所有 ROM 上保证「屏幕恒朝上」），违反
/// 「箭头始终指向屏幕正上方」的第一原则。本组件是普通 Flutter widget，
/// 渲染在地图 Stack 的正中央（IgnorePointer 不挡手势），与相机旋转完全
/// 解耦：
/// - Heading-Up 跟随：[screenRotationDegrees] 恒为 0 → 箭头永远指屏幕正上，
///   「转的是地图」；相机中心=GPS 坐标 ⇒ 箭头位置=真实定位点；
/// - 北朝上模式：传入平滑航向 → 箭头在屏幕上顺时针转到行进方向；
/// - [showDirection]=false（北朝上且暂无航向）：退化为无方向圆点，
///   宁可不指也不错指。
///
/// 旋转动画按最短弧展开（350°→10° 走 +20°，绝不倒转 340°），
/// 展开逻辑为纯函数 [unwrapNext]，可单测。
class RunnerArrow extends StatefulWidget {
  const RunnerArrow({
    super.key,
    required this.screenRotationDegrees,
    this.showDirection = true,
    this.size = 46,
    this.color = const Color(0xFF1565C0),
  });

  /// 箭头相对屏幕上方需要顺时针旋转的角度（0=指屏幕正上方）。
  final double screenRotationDegrees;
  final bool showDirection;
  final double size;
  final Color color;

  /// 最短弧展开：把目标角换算成与当前累计角连续的值。
  /// currentUnwrapped 可以是任意实数（跨圈累计），返回同连续系的新目标。
  static double unwrapNext(double currentUnwrapped, double targetDeg) {
    final double base = ((currentUnwrapped % 360) + 360) % 360;
    final double d = ((targetDeg - base) % 360 + 540) % 360 - 180; // (-180,180]
    return currentUnwrapped + d;
  }

  @override
  State<RunnerArrow> createState() => _RunnerArrowState();
}

class _RunnerArrowState extends State<RunnerArrow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  late double _unwrapped;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _unwrapped = widget.screenRotationDegrees;
    _animation = AlwaysStoppedAnimation<double>(_unwrapped);
  }

  @override
  void didUpdateWidget(RunnerArrow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double target =
        RunnerArrow.unwrapNext(_unwrapped, widget.screenRotationDegrees);
    if ((target - _unwrapped).abs() < 0.05) return; // 死区：不重启动画
    _animation = Tween<double>(begin: _unwrapped, end: target).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );
    _unwrapped = target;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose(); // 无残留定时器
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        return Transform.rotate(
          angle: _animation.value * math.pi / 180, // Flutter：顺时针为正
          child: child,
        );
      },
      child: CustomPaint(
        size: Size.square(widget.size),
        painter: _ArrowPainter(
          color: widget.color,
          showDirection: widget.showDirection,
        ),
      ),
    );
  }
}

/// 导航箭头绘制：白描边 + 蓝色锥形箭（类似专业导航车标），带轻投影；
/// 无方向时退化为白环蓝点。尺寸适中（默认 46px），不遮挡前方道路。
class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({required this.color, required this.showDirection});

  final Color color;
  final bool showDirection;

  @override
  void paint(Canvas canvas, Size size) {
    final double s = size.width;
    final Offset c = Offset(s / 2, s / 2);

    if (!showDirection) {
      canvas.drawCircle(
          c, s * 0.34, Paint()..color = const Color(0x33000000));
      canvas.drawCircle(c, s * 0.30, Paint()..color = Colors.white);
      canvas.drawCircle(c, s * 0.21, Paint()..color = color);
      return;
    }

    // 锥形导航箭：顶点在上边，底部带内凹 notch
    final Path arrow = Path()
      ..moveTo(s * 0.5, s * 0.06)
      ..lineTo(s * 0.86, s * 0.86)
      ..lineTo(s * 0.5, s * 0.68)
      ..lineTo(s * 0.14, s * 0.86)
      ..close();

    // 轻投影（先偏移画一层半透明黑）
    canvas.save();
    canvas.translate(0, s * 0.035);
    canvas.drawPath(arrow, Paint()..color = const Color(0x40000000));
    canvas.restore();

    // 白描边（任何底图上都清晰）
    canvas.drawPath(
      arrow,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = s * 0.09
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(arrow, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.showDirection != showDirection;
}
