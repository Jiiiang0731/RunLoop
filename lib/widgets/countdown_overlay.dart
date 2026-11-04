import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 开始跑步前的三秒环形倒计时覆盖层（阶段 L 模块 C，规范 4.1）。
///
/// - 3 → 2 → 1 → GO!，环形进度顺时针消减 + 中央数字缩放切换；
/// - 每秒切换轻微震动（系统 HapticFeedback，不新增依赖）；
/// - 「取消」按钮随时退出；取消/快速退出均无残留定时器（dispose 即销毁
///   AnimationController）；
/// - [onGo] 在倒计时结束的准确时刻触发（跑步计时从这一刻开始）；
/// - [onComplete] 在 GO 展示完毕后触发（父级此时移除覆盖层）。
class CountdownOverlay extends StatefulWidget {
  const CountdownOverlay({
    super.key,
    required this.onGo,
    required this.onCancelled,
    required this.onComplete,
    this.seconds = 3,
  });

  /// GO 时刻（倒计时结束瞬间）。
  final VoidCallback onGo;

  /// 用户点「取消」。
  final VoidCallback onCancelled;

  /// GO 展示完毕（约 0.7 秒后），父级移除本覆盖层。
  final VoidCallback onComplete;

  final int seconds;

  @override
  State<CountdownOverlay> createState() => _CountdownOverlayState();
}

class _CountdownOverlayState extends State<CountdownOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _goDisplay = Duration(milliseconds: 700);

  late final AnimationController _controller;
  int _lastVibrated = -1;
  bool _goFired = false;
  bool _cancelled = false;

  /// 已进行的倒计时秒数（0 → seconds，GO 阶段保持 seconds）。
  double get _elapsed =>
      math.min(_controller.value * _totalMs / 1000, widget.seconds.toDouble());

  double get _totalMs =>
      (widget.seconds * 1000 + _goDisplay.inMilliseconds).toDouble();

  /// 当前显示的数字：3/2/1；0 表示 GO 阶段。
  /// 减 1e-9 消除浮点边界（elapsed 恰为整数秒时 remain=2.0000000002
  /// 会错误显示上一秒）。
  int get _display {
    final double remain = widget.seconds - _elapsed;
    return remain <= 0 ? 0 : (remain - 1e-9).ceil();
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _totalMs.round()),
    );
    _controller.addListener(_onTick);
    _controller.forward();
  }

  void _onTick() {
    if (!mounted) return;
    final int d = _display;
    if (d > 0 && d != _lastVibrated) {
      _lastVibrated = d;
      HapticFeedback.lightImpact(); // 每秒轻微震动
    }
    if (d == 0 && !_goFired && !_cancelled) {
      _goFired = true;
      HapticFeedback.mediumImpact();
      widget.onGo(); // 倒计时结束的准确时刻（已取消则绝不触发）
    }
    if (_controller.status == AnimationStatus.completed ||
        _controller.value >= 1.0) {
      if (_goFired && !_cancelled) widget.onComplete();
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onTick);
    _controller.dispose(); // 快速退出：控制器销毁，无残留
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isGo = _display == 0;
    final double progress = (_elapsed / widget.seconds).clamp(0.0, 1.0);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.45),
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            SizedBox(
              width: 200,
              height: 200,
              child: CustomPaint(
                painter: _RingPainter(
                  progress: isGo ? 0.0 : progress,
                  color: isGo ? const Color(0xFF66BB6A) : Colors.white,
                ),
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (Widget child, Animation<double> anim) =>
                        ScaleTransition(scale: anim, child: child),
                    child: Text(
                      isGo ? 'GO!' : '$_display',
                      key: ValueKey<int>(_display),
                      style: TextStyle(
                        fontSize: isGo ? 54 : 72,
                        fontWeight: FontWeight.w800,
                        color: isGo ? const Color(0xFF66BB6A) : Colors.white,
                        height: 1,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 96,
              child: TextButton(
                onPressed: _goFired
                    ? null
                    : () {
                        _cancelled = true;
                        widget.onCancelled();
                      },
                child: const Text(
                  '取消',
                  style: TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 环形进度画笔：从顶部起顺时针消减（剩余比例弧）。
class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = color;
    final Rect rect = Rect.fromCircle(
      center: size.center(Offset.zero),
      radius: size.shortestSide / 2 - 8,
    );
    final double sweep = (1 - progress.clamp(0.0, 1.0)) * 2 * math.pi;
    if (sweep <= 0.001) return;
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.progress != progress || old.color != color;
}
