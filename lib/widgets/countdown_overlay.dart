import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/nav/tts_service.dart';
import '../services/nav/voice_log.dart';

/// 开始跑步前的三秒环形倒计时覆盖层（阶段 L 模块 C，规范 4.1；
/// 阶段 M-B：语音倒计时 + 数字重叠修复）。
///
/// - 3 → 2 → 1 → GO!，环形进度顺时针消减；
/// - **语音同步**（任务书 3.1）：「三」「二」「一」「开始跑步」逐秒播报，
///   全部 flush 模式——上一句立即被打断清空，语音绝不重叠；「开始跑步」
///   在 [onGo] 之前下发，onGo 里排队的出发播报（QUEUE_ADD）自然接在其后；
///   TTS 为 fire-and-forget，完成回调绝不延迟正式开始时刻；
/// - **数字不重叠**（任务书 3.2）：单一 Text + 缩放脉冲转场——旧数字在同一帧
///   彻底移除、新数字缩放进入，结构上不存在两个数字并存的可能；
///   数字固定于圆环中心，固定尺寸容器，无宽度跳动；
/// - 每秒切换轻微震动（系统 HapticFeedback，不新增依赖）；
/// - 「取消」按钮随时退出：停止剩余语音队列，绝不触发 [onGo]；
/// - [onGo] 在倒计时结束的准确时刻触发（跑步计时从这一刻开始）；
/// - [onComplete] 在 GO 展示完毕后触发（父级此时移除覆盖层）。
class CountdownOverlay extends StatefulWidget {
  const CountdownOverlay({
    super.key,
    required this.onGo,
    required this.onCancelled,
    required this.onComplete,
    this.seconds = 3,
    this.engine,
  });

  /// GO 时刻（倒计时结束瞬间）。
  final VoidCallback onGo;

  /// 用户点「取消」。
  final VoidCallback onCancelled;

  /// GO 展示完毕（约 0.7 秒后），父级移除本覆盖层。
  final VoidCallback onComplete;

  final int seconds;

  /// 语音引擎（可注入；null = 纯视觉倒计时，语音不可用时静默降级）。
  final SpeechEngine? engine;

  @override
  State<CountdownOverlay> createState() => _CountdownOverlayState();
}

class _CountdownOverlayState extends State<CountdownOverlay>
    with TickerProviderStateMixin {
  static const Duration _goDisplay = Duration(milliseconds: 700);

  /// 中文数字（支持 seconds ≤ 10）。
  static const List<String> _zhDigits = <String>[
    '零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'
  ];

  late final AnimationController _controller;

  /// 数字缩放脉冲（单一 Text 的进入动画——不与旧数字并存）。
  late final AnimationController _digitPulse;
  int _pulseFor = -1;

  int _lastVibrated = -1;
  int _lastSpoken = -1;
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
    _digitPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _controller.addListener(_onTick);
    _controller.forward();
  }

  void _speak(String text) {
    final SpeechEngine? e = widget.engine;
    if (e == null || _cancelled) return;
    VoiceLog.instance.log(VoiceLogKind.system, 'countdown', text: text);
    // flush：打断并清空队列——倒计时语音之间绝不重叠（任务书 3.1#3）。
    // 不 await：TTS 完成与否绝不阻塞倒计时推进（任务书 3.1#5）。
    e.speak(text, flush: true).catchError((Object err) {
      VoiceLog.instance
          .log(VoiceLogKind.error, 'countdown', text: text, detail: '$err');
    });
  }

  void _onTick() {
    if (!mounted) return;
    final int d = _display;
    if (d > 0 && d != _lastVibrated) {
      _lastVibrated = d;
      HapticFeedback.lightImpact(); // 每秒轻微震动
    }
    // 数字切换 → 缩放脉冲（单一 Text：旧数字同帧消失，结构上无重叠）
    if (d != _pulseFor) {
      _pulseFor = d;
      _digitPulse.forward(from: 0);
    }
    // 每秒语音：在数字切换的同一帧播报（声画同步，任务书 3.1）
    if (d > 0 && d != _lastSpoken && !_cancelled) {
      _lastSpoken = d;
      _speak(d <= _zhDigits.length - 1 ? _zhDigits[d] : '$d');
    }
    if (d == 0 && !_goFired && !_cancelled) {
      _goFired = true;
      HapticFeedback.mediumImpact();
      // 先播「开始跑步」（flush 清尾），再触发 onGo——onGo 里 attach 的
      // 出发播报是 QUEUE_ADD，自然排在「开始跑步」之后，互不打断。
      _speak('开始跑步');
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
    _digitPulse.dispose();
    // 注意：不在这里 stop 语音——GO 后覆盖层移除时「开始跑步」仍在播。
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
                // 固定尺寸容器 + 单一 Text：数字恒在圆环中心，
                // 无宽度跳动，无前后数字叠加（任务书 3.2）。
                child: Center(
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.35, end: 1.0).animate(
                      CurvedAnimation(
                          parent: _digitPulse, curve: Curves.easeOutCubic),
                    ),
                    child: Text(
                      isGo ? 'GO!' : '$_display',
                      textAlign: TextAlign.center,
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
                        // 任务书 3.1#7：取消必须清空剩余语音队列，
                        // 且绝不触发正式开始。
                        widget.engine?.stop();
                        VoiceLog.instance.log(VoiceLogKind.system, 'countdown',
                            detail: '用户取消倒计时，语音队列已清空');
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
