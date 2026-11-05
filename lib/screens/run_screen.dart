import 'dart:async';

import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:amap_flutter_map/amap_flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app/config.dart';
import '../models/km_split.dart';
import '../models/planned_route.dart';
import '../models/run_record.dart';
import '../models/track_point.dart';
import '../services/nav/compass_source.dart';
import '../services/nav/follow_camera.dart';
import '../services/nav/foreground_run_service.dart';
import '../services/nav/heading_controller.dart';
import '../services/nav/nav_announcer.dart';
import '../services/nav/nav_settings.dart';
import '../services/nav/nav_state.dart';
import '../services/nav/tts_service.dart';
import '../services/nav/voice_log.dart';
import '../services/route_api/reroute_api.dart';
import '../services/run_recorder/run_recorder.dart';
import '../utils/dual_track.dart';
import '../utils/geo.dart' hide haversineMeters;
import '../utils/map_icons.dart';
import '../utils/route_path.dart';
import '../utils/route_style.dart';
import '../utils/turn_annotations.dart' show metersPerPixel;
import '../widgets/countdown_overlay.dart';
import '../widgets/runner_arrow.dart';
import 'run_summary_screen.dart';

/// 地图朝向模式（阶段 L 模块 D）：预览固定北朝上；跑步开始后默认 Heading-Up。
enum MapOrientation { headingUp, northUp }

/// 跑步中页面（阶段 L 全面升级；阶段 L2 Heading-Up 重构）：
/// - 开始前三秒环形倒计时，GO 时刻才启动计时（模块 C）；
/// - 导航相机（L2 重构）：GO 后自动放大至导航构图；跑者=屏幕中央固定
///   箭头（永不随地图旋转）；地图 bearing=平滑航向 ⇒ 前进方向恒在屏幕
///   正上方；目标位姿 1Hz 更新 + 20Hz 插值渲染（连续平移/旋转/缩放，
///   无逐秒跳动）；GPS course → 路线切线 → 静止时磁力计辅助 → 冻结；
///   手动平移解除跟随（一键回中）、捏合缩放采纳新级别（模块 D/规范一二三）；
/// - 语音导航：真实 steps + 窗口化匹配里程驱动播报（模块 A）；
/// - 每公里分段：完成时轻提示 + 播报（模块 B）；
/// - 视觉融合：已跑段低权重蓝灰、剩余段渐变主线、GPS 橙轨在上（模块 E）；
/// - 布局：顶部转弯信息 + 距离，中部地图，底部数据面板与按钮（模块 F）；
/// - 前台服务：GO 时启动 location 型 FGS，锁屏/后台持续（模块 8）。
class RunScreen extends StatefulWidget {
  const RunScreen({super.key, this.plannedRoute, this.targetM});

  final PlannedRoute? plannedRoute;
  final double? targetM;

  @override
  State<RunScreen> createState() => _RunScreenState();
}

class _RunScreenState extends State<RunScreen> with WidgetsBindingObserver {
  /// 偏航判定阈值（米）：集中配置于 AppConfig（决策#6）。
  static const double _offRouteMeters = AppConfig.offRouteMeters;

  /// 投影搜索窗口（米）：只在上次里程 ±250m 内找最近点，避免吸附到重叠的另一条腿。
  static const double _matchWindowM = AppConfig.matchWindowM;

  final RunRecorder _recorder = RunRecorder();
  final FlutterTtsEngine _tts = FlutterTtsEngine();
  final HeadingController _heading = HeadingController();

  /// 磁力计辅助源（阶段 L2 规范四.5：仅静止且无路线方向时采纳）。
  final CompassSource _compass = CompassSource();

  /// 20Hz 相机插值模型（阶段 L2：目标位姿 1Hz 更新，渲染位姿每帧逼近，
  /// 平移/旋转/缩放全部连续平滑——替代旧的 1Hz animated moveCamera 跳动）。
  final FollowCamera _cam = FollowCamera();
  Timer? _camTimer;

  /// 最近一次「程序下发」的相机位姿：用于在 onCameraMoveEnd 中区分
  /// 用户手势（平移→解除跟随；捏合缩放→采纳新级别）与自己下发的移动。
  LatLng? _lastCommandedTarget;
  double? _lastCommandedZoom;

  /// 用户捏合缩放后采纳的基础缩放（本次跑步内覆盖设置值）。
  double? _zoomOverride;

  /// 手势让位（阶段 L2）：用户正在拖动/捏合时暂停 20Hz 下发，
  /// 避免「手指 vs 跟随」打架；onCameraMoveEnd 后恢复。
  bool _gestureHold = false;

  /// 程序动画（GO 过渡/回中/转向）结束时刻（毫秒）：窗口内的相机事件
  /// 是自己的动画，不判为手势。
  double _animUntilMs = 0;

  late final NavAnnouncer _announcer = NavAnnouncer(
    engine: _tts,
    config: _SettingsVoiceConfig(),
  );

  bool _ending = false;

  // ---- 阶段 N：实时导航 tick（锁屏/后台可用）----
  /// 旧实现把「地图匹配 / 偏航状态机 / 语音播报 / 公里分段 / 目标播报」
  /// 全部放在 build() 里；而 Flutter 在 AppLifecycleState.paused 时
  /// `SchedulerBinding.framesEnabled=false`（flutter/packages/flutter/lib/src/
  /// scheduler/binding.dart:424-426, :947），锁屏后不再出帧、build 不执行，
  /// 导致「GPS 在记录但完全没有语音」。现在改由 recorder 监听 + 1s 兜底
  /// 定时器驱动（事件循环不受帧影响），build 只做渲染。
  RouteProjection? _lastProj;
  bool _lastOffRoute = false;
  Timer? _navTickTimer;
  DateTime? _lastNavTickAt;
  int _heartbeatSec = 0;

  // ---- 倒计时（模块 C）----
  bool _showCountdown = true;
  bool _started = false; // GO 已触发（计时已开始）

  // ---- 相机（模块 D）----
  AMapController? _controller;
  bool _followCamera = true;
  MapOrientation _orientation = MapOrientation.headingUp;
  double? _lastHeadingAtMs; // 方向平滑的 dt 计算（毫秒时间戳）

  // ---- 路线与匹配 ----
  RoutePath? _plannedPath;
  List<LatLng> _plannedPts = const <LatLng>[];
  double? _lastAlong; // 上次投影里程（map-matching 提示）
  bool _hasFix = false; // 已成功匹配过一次
  double _alongForDraw = 0; // 驱动完成/剩余折线拆分

  // ---- 阶段 M-G 性能层：增量缓存 + 节流更新 ----
  // 原则：记录数据绝不丢失（recorder 保存全量点、精度、分段）；这里只
  // 削减 UI 重建时的重复 O(N) 拷贝与地图插件的重复原生序列化。

  /// 轨迹 LatLng 增量缓存：只追加；recorder 重启清空时整体重置。
  final List<LatLng> _trackLatLngs = <LatLng>[];
  int _trackPtsSeen = 0;

  /// 轨迹折线节流（2s）：缓存的 Polyline 对象原样复用，插件深比较相等
  /// 即跳过原生更新——长跑 7000+ 点时轨迹折线是最大的每帧序列化开销。
  DateTime? _trackPolyAt;
  Set<Polyline> _trackLineCache = <Polyline>{};
  static const Duration _trackPolyInterval = Duration(seconds: 2);

  /// completed/remaining 切片缓存：along 前进 ≥5m 或路线代数变化才重切
  ///（5m 在缩放 18.5 下约 7px，且分界点就在跑者箭头正下方，不可感知）。
  double _slicedAlong = -1;
  int _slicedGen = -1;
  int _routeGen = 0;
  Set<Polyline> _routeLineCache = <Polyline>{};
  Set<Polyline> _connectorLineCache = <Polyline>{};
  Polyline? _canonicalRefLine;

  /// 阶段 N：当前切片下的「剩余路线」点列（供双轨/箭头复算，只读）。
  List<LatLng> _slicedRemaining = const <LatLng>[];

  // ---- 阶段 N 视觉：导航页方向箭头 + 转弯标记图标 ----
  BitmapDescriptor? _arrowIcon;
  BitmapDescriptor? _turnLeftIcon;
  BitmapDescriptor? _turnRightIcon;
  BitmapDescriptor? _turnUTurnIcon;

  // ---- 动态重规划（阶段 M-D/E，任务书 5.1–5.8） ----
  /// 当前导航基准路径：初始 = 规划路线；重规划成功后原子切换为
  /// 「连接段 + 原剩余」合并路线。原规划折线 [_plannedPts] 永不修改
  ///（已跑部分与 GPS 轨迹绝不覆盖，5.4#2/#3）。
  RoutePath? _activePath;
  List<LatLng> _activePts = const <LatLng>[];

  /// 当前有效 steps（重规划后 = 连接段 steps + 原剩余 steps 重定基）。
  List<RouteStep> _activeSteps = const <RouteStep>[];

  final NavStateMachine _navState = NavStateMachine();
  final RerouteClient _rerouteClient = RerouteClient();

  /// 已消费的定位点时间戳（同一 GPS 点绝不重复投票）。
  DateTime? _lastNavSampleAt;

  /// 在飞请求锁 + 请求 ID（5.7#5/#6：一次偏航事件只允许一个请求，
  /// 过期结果按 ID 丢弃）。
  bool _rerouteInFlight = false;
  int _rerouteReqId = 0;
  int _rerouteAutoAttempts = 0;
  DateTime? _rerouteCooldownUntil;
  Timer? _rerouteRetryTimer;
  static const int _maxAutoRerouteAttempts = 2;
  static const Duration _rerouteCooldown = Duration(seconds: 30);

  /// 已应用的连接段折线（琥珀色绘制，视觉上与原路线明显区分）。
  List<LatLng>? _connectorPts;

  /// 连接段终点（=接回点）在**新** active 路径上的里程：越过即播
  /// 「已重新接回原定路线」（5.8）。
  double? _rejoinAlongActive;
  bool _rejoinAnnounced = false;

  /// 容差告警（5.5：新总里程超出原目标时如实展示，可关闭）。
  String? _rerouteWarning;

  // ---- 公里提示（模块 B）----
  int _lastCompletedKm = 0;
  KmSplit? _toastSplit;
  Timer? _toastTimer;

  // ---- 目标距离完成（阶段 M-C）----
  bool _goalReached = false;
  bool _goalDismissed = false;

  // ---- TTS 诊断（模块 A，绝不静默失败）----
  String? _ttsProblem;

  BitmapDescriptor? _runnerIcon;
  BitmapDescriptor? _startIcon;
  BitmapDescriptor? _dotIcon;

  @override
  void initState() {
    super.initState();
    final PlannedRoute? route = widget.plannedRoute;
    if (route != null && route.polyline.length >= 2) {
      _plannedPts =
          route.polyline.map((List<double> p) => LatLng(p[1], p[0])).toList();
      _plannedPath = RoutePath.fromPoints(_plannedPts);
      _activePath = _plannedPath;
      _activePts = _plannedPts;
      _activeSteps = route.steps;
    }
    // 注意：不在这里 start()——倒计时 GO 时刻才开始计时（规范 4.2）。
    // 相机目标由 build 中的 _onMatched 驱动（1Hz），渲染由 _camTimer（20Hz）驱动。
    WidgetsBinding.instance.addObserver(this); // 锁屏/前后台切换写入语音日志
    _compass.start();
    _loadIcons();
    _initVoice();
    // 阶段 N：导航逻辑由数据驱动（recorder 变更 + 1s 兜底），不依赖出帧
    _recorder.addListener(_onNavTick);
    _navTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _onNavTick();
    });
  }

  /// 生命周期日志（任务书 2.3：锁屏语音问题凭日志还原时间线）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    VoiceLog.instance.log(
      VoiceLogKind.lifecycle,
      'run',
      detail: '${state.name} started=$_started fgs=${ForegroundRunService.running}',
    );
  }

  Future<void> _initVoice() async {
    await NavSettings.instance.load();
    if (!mounted) return;
    await _tts.configure(
      rate: NavSettings.instance.speechRate,
      volume: NavSettings.instance.volume,
    );
    if (!mounted) return;
    if (NavSettings.instance.voiceNavEnabled) {
      final TtsDiagnostic d = await _tts.diagnose();
      if (mounted && !d.ok) {
        setState(() => _ttsProblem = d.guidance); // 明确指引，不静默
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _navTickTimer?.cancel(); // 阶段 N：导航 tick 随页面消亡
    _recorder.removeListener(_onNavTick);
    _toastTimer?.cancel();
    _rerouteRetryTimer?.cancel();
    _camTimer?.cancel(); // 相机定时器随页面消亡，无残留
    _compass.dispose();
    if (_started) {
      _announcer.onEnd(); // 结束语音立即停止并清空队列
      if (!_ending) _recorder.end();
      unawaited(ForegroundRunService.stop()); // 释放前台服务/通知
    }
    _recorder.dispose();
    unawaited(_tts.dispose()); // 单例共享引擎：仅停止播报，不销毁
    unawaited(VoiceLog.instance.saveSession()); // 锁屏会话日志留档
    _controller = null;
    super.dispose();
  }

  Future<void> _loadIcons() async {
    try {
      final BitmapDescriptor runner =
          await createRunnerIcon(const Color(0xFF1565C0));
      final BitmapDescriptor start = await createStartIcon();
      final BitmapDescriptor dot =
          await createPositionDotIcon(const Color(0xFF1565C0));
      // 阶段 N：导航页方向箭头 + 真实转弯标记
      final BitmapDescriptor arrow =
          await createArrowIcon(RouteStyle.arrowOutColor);
      final BitmapDescriptor tl =
          await createTurnMarkerIcon(Icons.turn_left, const Color(0xFF0D47A1));
      final BitmapDescriptor tr =
          await createTurnMarkerIcon(Icons.turn_right, const Color(0xFF0D47A1));
      final BitmapDescriptor tu =
          await createTurnMarkerIcon(Icons.u_turn_left, const Color(0xFFB71C1C));
      if (mounted) {
        setState(() {
          _runnerIcon = runner;
          _startIcon = start;
          _dotIcon = dot;
          _arrowIcon = arrow;
          _turnLeftIcon = tl;
          _turnRightIcon = tr;
          _turnUTurnIcon = tu;
        });
      }
    } catch (_) {
      // 图标失败时退化为系统默认标记。
    }
  }

  // ---------- 倒计时（模块 C） ----------

  /// GO 时刻：跑步计时从这里开始（规范 4.2#2），倒计时不计入成绩。
  /// 同时相机从「预览构图」切换到「实时导航构图」（规范二.B：自动放大、
  /// 跑者居中、前进方向朝上）。
  void _onCountdownGo() {
    if (_started) return;
    _started = true;
    _recorder.start();
    _announcer.attach(widget.plannedRoute?.steps ?? const <RouteStep>[]);
    unawaited(_startForeground());
    _beginNavCamera();
  }

  Future<void> _startForeground() async {
    try {
      // Android 13+：通知权限（无权限时 FGS 仍运行，只是通知不可见）。
      await Permission.notification.request();
    } catch (_) {
      // 权限失败不阻断跑步。
    }
    final bool ok = await ForegroundRunService.start();
    VoiceLog.instance.log(VoiceLogKind.fgs, 'run',
        detail: ok ? '前台服务已启动（location 型 + WakeLock）' : '前台服务启动失败！锁屏后可能被系统冻结');
  }

  void _onCountdownCancel() {
    // 未开始 → 无任何记录产生，直接退出（规范 4.2#4/5）。
    Navigator.pop(context);
  }

  // ---------- 相机与方向（模块 D，阶段 L2 重构） ----------
  //
  // 架构：目标位姿 1Hz 更新（_onMatched → FollowCamera.setGoal），
  // 渲染位姿 20Hz 插值（_camTimer → FollowCamera.tick → moveCamera 非动画）。
  // 方向 = HeadingController 仲裁（GPS course → 路线切线 → 静止时磁力计辅助
  // → 冻结）；地图 bearing = 平滑航向 ⇒ 前进方向永远在屏幕正上方；
  // 跑者 = 屏幕中央固定箭头（RunnerArrow），不用会随地图旋转的 Marker。

  /// 基础缩放：用户捏合过 → 采纳值；否则用设置页档位（默认 18.5）。
  double get _baseZoom => _zoomOverride ?? NavSettings.instance.mapZoom;

  /// 目标缩放：临近转弯自动放大一档，看清路口（规范二.B「结合下一个
  /// 路口的距离合理调整」）；远离转弯回到基础档。
  double _zoomGoalFor(double? nextTurnDistM) {
    double bonus = 0;
    if (nextTurnDistM != null) {
      if (nextTurnDistM < 80) {
        bonus = 0.4;
      } else if (nextTurnDistM < 250) {
        bonus = 0.2;
      }
    }
    return (_baseZoom + bonus).clamp(16.5, 20.0);
  }

  /// GO 瞬间：一次 800ms 动画从预览构图飞到导航构图（自动放大 + 对齐
  /// 出发方向），随后启动 20Hz 跟随定时器。
  void _beginNavCamera() {
    final RoutePath? path = _plannedPath;
    double initialBearing = _heading.heading ?? 0;
    if (_heading.heading == null && path != null && path.total > 5) {
      // 尚无 GPS 航向：先用路线出发方向的切线，起步即对齐（体验细节）
      initialBearing = path.at(0).bearing;
    }
    final List<TrackPoint> pts = _recorder.points;
    final LatLng target = pts.isNotEmpty
        ? LatLng(pts.last.latitude, pts.last.longitude)
        : (_plannedPts.isNotEmpty ? _plannedPts.first : const LatLng(30.536395, 114.087279));
    final double zoom = _zoomGoalFor(null);
    final double bearing =
        _orientation == MapOrientation.headingUp ? initialBearing : 0;

    _cam.snap(target: target, bearing: bearing, zoom: zoom);
    _issueCamera(target, bearing, zoom, animated: true, duration: 800);

    // 等 GO 动画基本结束再启动逐帧跟随，避免两种移动互相打架。
    _camTimer?.cancel();
    _camTimer = Timer(const Duration(milliseconds: 850), () {
      if (!mounted || !_started || _ending) return;
      _camTimer = Timer.periodic(
          const Duration(milliseconds: 50), (_) => _camTick());
    });
  }

  void _issueCamera(LatLng target, double bearing, double zoom,
      {required bool animated, int duration = 250}) {
    _lastCommandedTarget = target;
    _lastCommandedZoom = zoom;
    if (animated) {
      _animUntilMs = DateTime.now().millisecondsSinceEpoch + duration + 250;
    }
    _controller?.moveCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: zoom, bearing: bearing, tilt: 0),
      ),
      animated: animated,
      duration: duration,
    );
  }

  /// 20Hz 渲染帧：向目标位姿指数逼近；死区内 tick 返回 null → 不下发。
  /// 手势期间让位（不与用户手指抢相机）。
  void _camTick() {
    if (!mounted) return;
    if (_controller == null || !_started || !_followCamera) return;
    if (_gestureHold) return;
    final FollowCameraStep? s = _cam.tick(0.05);
    if (s == null) return;
    _issueCamera(s.position, s.bearing, s.zoom, animated: false);
  }

  /// 相机移动中回调：区分「自己的动画/下发」与「用户手势」。
  /// 手势判定：不在程序动画窗口内，且事件位姿明显偏离最近下发值。
  void _onCameraMove(CameraPosition pos) {
    if (!_started || !_followCamera || _gestureHold) return;
    final double nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    if (nowMs < _animUntilMs) return; // GO 过渡/回中动画进行中
    final LatLng? cmdT = _lastCommandedTarget;
    final double? cmdZ = _lastCommandedZoom;
    final bool farTarget = cmdT != null && haversineMeters(pos.target, cmdT) > 8;
    final bool zoomDelta = cmdZ != null && (pos.zoom - cmdZ).abs() > 0.25;
    if (farTarget || zoomDelta) {
      _gestureHold = true; // 用户正在拖动/捏合：暂停下发，等 MoveEnd 决策
    }
  }

  /// 相机移动结束回调：区分「用户手势」与「程序下发」。
  /// - 目标点远离程序下发值 >25m ⇒ 用户平移 → 解除跟随，出现回中按钮；
  /// - 缩放差 >0.25 ⇒ 用户捏合 → 采纳为新基础级别（跟随不解除）；
  /// - 其余（含自己每帧下发的移动）忽略。
  void _onCameraMoveEnd(CameraPosition pos) {
    _gestureHold = false;
    if (!_started || !_followCamera) return;
    final LatLng? cmdT = _lastCommandedTarget;
    if (cmdT != null && haversineMeters(pos.target, cmdT) > 25) {
      if (mounted) setState(() => _followCamera = false);
      return;
    }
    final double? cmdZ = _lastCommandedZoom;
    if (cmdZ != null && (pos.zoom - cmdZ).abs() > 0.25) {
      _zoomOverride = pos.zoom.clamp(16.5, 20.0);
      _cam.snap(zoom: pos.zoom); // 插值模型与真实相机对齐，防「回拉打架」
    }
    // 双指旋转已禁用（rotateGesturesEnabled=false），朝向只由模式切换控制。
  }

  /// 回中：立即吸附到跑者 + 短动画归位（规范 5.2#6「一键恢复跟随」）。
  void _recenter() {
    setState(() => _followCamera = true);
    _gestureHold = false;
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final LatLng t = LatLng(pts.last.latitude, pts.last.longitude);
    final double b = _orientation == MapOrientation.headingUp
        ? (_heading.heading ?? _cam.bearing ?? 0)
        : 0;
    final double z = _cam.zoom ?? _zoomGoalFor(null);
    _cam.snap(target: t, bearing: b, zoom: z);
    _issueCamera(t, b, z, animated: true, duration: 400);
  }

  /// 切换「行进方向朝上 / 正北朝上」：地图一次短动画转到新朝向，
  /// 插值模型同步吸附（避免 20Hz 逼近走长弧）。
  void _toggleOrientation() {
    setState(() {
      _orientation = _orientation == MapOrientation.headingUp
          ? MapOrientation.northUp
          : MapOrientation.headingUp;
    });
    if (!_started || !_followCamera) return; // 预览阶段仅切换箭头渲染
    _gestureHold = false;
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final LatLng t = LatLng(pts.last.latitude, pts.last.longitude);
    final double b = _orientation == MapOrientation.headingUp
        ? (_heading.heading ?? _cam.bearing ?? 0)
        : 0;
    final double z = _cam.zoom ?? _zoomGoalFor(null);
    _cam.snap(target: t, bearing: b, zoom: z);
    _issueCamera(t, b, z, animated: true, duration: 400);
  }

  // ---------- 暂停 / 继续 / 结束 ----------

  void _pause() {
    VoiceLog.instance.log(VoiceLogKind.system, 'run', detail: '暂停跑步');
    _announcer.onPause(); // 先停语音（规范 2.4#5 / 任务书 2.2#7）
    _recorder.pause();
  }

  void _resume() {
    VoiceLog.instance.log(VoiceLogKind.system, 'run', detail: '继续跑步');
    _recorder.resume();
    _announcer.onResume(alongM: _lastAlong ?? _alongForDraw);
  }

  Future<void> _end() async {
    VoiceLog.instance.log(VoiceLogKind.system, 'run', detail: '结束运动');
    _announcer.onEnd(); // 立即停止并清空语音（规范 2.4#7）
    await ForegroundRunService.stop(); // 释放前台服务、通知、WakeLock
    await VoiceLog.instance.saveSession(); // 本次会话日志留档（诊断页可回看）
    final RunRecord? record = _recorder.end();
    if (!mounted) return;
    if (record == null) {
      Navigator.pop(context);
      return;
    }
    setState(() => _ending = true);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(
        builder: (_) => RunSummaryScreen(
          record: record,
          plannedRoute: widget.plannedRoute,
        ),
      ),
    );
  }

  // ---------- 地图匹配（沿线进度 / 偏航） ----------

  RouteProjection? _mapMatch(LatLng p) {
    final RoutePath? path = _activePath;
    if (path == null) return null;
    RouteProjection proj = path.projectNear(p, _lastAlong, _matchWindowM);
    if (proj.offsetM > _offRouteMeters) {
      // 窗口内找不到（可能抄近路跳到前方）：退回全局投影重新锚定
      final RouteProjection global = path.project(p);
      if (global.offsetM < proj.offsetM) proj = global;
    }
    if (proj.offsetM <= _offRouteMeters) {
      _lastAlong = proj.alongM; // 仅在路线上时更新提示，偏航期间保持锚点
    }
    return proj;
  }

  /// 阶段 N：数据驱动的导航 tick（锁屏/后台照常执行）。
  ///
  /// 事件循环（定位流回调、定时器）不依赖 Flutter 出帧，因此在
  /// `AppLifecycleState.paused` 下仍会运行——这正是锁屏后语音能继续的前提。
  /// 每 30s 写一条心跳日志（含点数/公里/FGS 状态），真机可据此证明
  /// 锁屏期间逻辑仍在跑（VoiceLog「tick 心跳」条目）。
  void _onNavTick() {
    if (!mounted) return;
    final DateTime now = DateTime.now();
    if (_lastNavTickAt != null &&
        now.difference(_lastNavTickAt!).inMilliseconds < 250) {
      return; // 同一轮事件里 recorder 通知与兜底定时器重复触发：去抖
    }
    _lastNavTickAt = now;
    _heartbeatSec++;
    if (_started && _heartbeatSec % 30 == 0) {
      VoiceLog.instance.log(VoiceLogKind.fgs, 'tick',
          detail: '心跳 n=${_recorder.pointCount} '
              'km=${(_recorder.distanceMeters / 1000).toStringAsFixed(2)} '
              'fgs=${ForegroundRunService.running} '
              'status=${_navState.status.name}');
    }
    if (!_started || _activePath == null) return;
    final List<TrackPoint> pts = _recorder.points;
    if (pts.isEmpty) return;
    final TrackPoint last = pts.last;
    final RouteProjection? proj =
        _mapMatch(LatLng(last.latitude, last.longitude));
    _lastProj = proj;
    // 偏航状态机（精度自适应阈值 + 连续点数 + 持续时间 + 方向不匹配）
    _updateNavState(proj, pts);
    _lastOffRoute = _navState.isOffRoute;
    _onMatched(proj, pts, _lastOffRoute);
    if (mounted) setState(() {});
  }

  /// 每帧匹配驱动：方向平滑（模块 D）+ 语音播报（模块 A）+ 公里提示（模块 B）。
  /// 全部幂等：重复执行不会重复播报/抖动。
  void _onMatched(RouteProjection? proj, List<TrackPoint> pts, bool offRoute) {
    if (proj != null && !offRoute) {
      _hasFix = true;
      _alongForDraw = proj.alongM;
    }
    if (!_started || pts.isEmpty) return;

    // ---- 方向：GPS course 优先 → 路线切线兜底 → 静止时磁力计辅助 → 冻结 ----
    final TrackPoint last = pts.last;
    final double nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final double dt = _lastHeadingAtMs == null
        ? 1.0
        : ((nowMs - _lastHeadingAtMs!) / 1000.0).clamp(0.05, 5.0);
    _lastHeadingAtMs = nowMs;
    final RoutePath? path = _activePath;
    _heading.update(
      speed: last.speed,
      accuracy: last.accuracy,
      gpsBearing: last.bearing,
      routeBearing: (path != null && proj != null && !offRoute)
          ? path.at(proj.alongM).bearing
          : null,
      // 偏航时不给路线方向：地图按真实运动方向转，绝不强制拉回路线视角
      compassBearing: _compass.heading,
      dtSeconds: dt,
    );

    // ---- 相机目标位姿（20Hz 定时器负责平滑跟随，此处只设目标） ----
    if (_followCamera) {
      final double camBearing = _orientation == MapOrientation.headingUp
          ? (_heading.heading ?? _cam.bearing ?? 0)
          : 0;
      final double? turnDist = (proj != null && !offRoute)
          ? _nextTurnHint(proj.alongM)?.distM
          : null;
      _cam.setGoal(
        target: LatLng(last.latitude, last.longitude), // GPS 真实坐标
        bearing: camBearing,
        zoom: _zoomGoalFor(turnDist),
      );
    }

    // ---- 语音导航 ----
    _announcer.onPosition(
      alongM: proj?.alongM ?? _alongForDraw,
      offRoute: offRoute,
    );

    // ---- 重规划接回确认（5.8）：新路径上越过连接段终点 = 接回原路线 ----
    if (_rejoinAlongActive != null &&
        !_rejoinAnnounced &&
        !offRoute &&
        proj != null &&
        proj.alongM >= _rejoinAlongActive!) {
      _rejoinAnnounced = true;
      VoiceLog.instance.log(VoiceLogKind.system, 'reroute',
          detail: '已重新接回原定路线（along=${proj.alongM.round()}m）');
      unawaited(_tts.speak('已重新接回原定路线', flush: false));
    }

    // ---- 公里完成检测（completedKm 变大 = 刚跨过 1000m 边界） ----
    if (_recorder.completedKm > _lastCompletedKm) {
      _lastCompletedKm = _recorder.completedKm;
      final Iterable<KmSplit> full =
          _recorder.kmSplits.where((KmSplit s) => !s.isPartial);
      if (full.isNotEmpty) {
        final KmSplit split = full.last;
        _announcer.onKmSplit(split);
        _toastSplit = split;
        _toastTimer?.cancel();
        _toastTimer = Timer(const Duration(seconds: 4), () {
          if (mounted) setState(() => _toastSplit = null);
        });
      }
    }

    _checkGoal();
  }

  // ---------- 目标距离完成（阶段 M-C，任务书 4.2/4.3） ----------

  /// GPS 有效累计距离达到用户设定目标 → 一次性事件：
  /// 播报「N公里跑步目标已完成…」（排在本公里配速播报之后），
  /// 屏幕出现「继续跑步 / 结束运动」卡片，绝不自动结束。
  void _checkGoal() {
    final double? target = widget.targetM;
    if (_goalReached || target == null || target <= 0) return;
    if (_recorder.distanceMeters < target) return;
    _goalReached = true;
    final double km = target / 1000;
    final String kmLabel = (km - km.roundToDouble()).abs() < 0.01
        ? '${km.round()}'
        : km.toStringAsFixed(1);
    final String text =
        '$kmLabel公里跑步目标已完成，您可以选择继续跑步或结束本次运动。';
    VoiceLog.instance.log(VoiceLogKind.system, 'goal', text: text);
    // flush:false（QUEUE_ADD）：若目标公里恰逢整公里分段，配速播报先入队，
    // 目标完成提示紧随其后——两种事件都播、顺序正确（任务书 4.2 示例）。
    unawaited(_tts.speak(text, flush: false));
    if (mounted) setState(() {});
  }

  // ---------- 动态重规划编排（阶段 M-D/E，任务书 5.2–5.8） ----------

  /// 每帧把匹配结果喂给状态机；迁移边沿驱动副作用（语音/请求）。
  /// 检测是多因子的：精度自适应阈值 + 连续点数 + 持续时间 + 方向不匹配
  ///（NavStateMachine/DeviationConfig），绝不是一刀切的固定距离布尔值。
  void _updateNavState(RouteProjection? proj, List<TrackPoint> pts) {
    if (!_started || proj == null || pts.isEmpty) return;
    final TrackPoint last = pts.last;
    // 同一 GPS 点只投一票：builder 可能因其他 setState 重跑多次
    if (last.timestamp == _lastNavSampleAt) return;
    _lastNavSampleAt = last.timestamp;
    final RoutePath? path = _activePath;
    final double? routeBearing =
        (path != null && proj.offsetM < _matchWindowM)
            ? path.at(proj.alongM).bearing
            : null;
    final NavStatus before = _navState.status;
    final bool changed = _navState.update(
      offsetM: proj.offsetM,
      accuracyM: last.accuracy,
      headingDeg: _heading.heading,
      routeBearingDeg: routeBearing,
      now: DateTime.now(),
    );
    if (!changed) return;
    if (_navState.status == NavStatus.offRoute) {
      _onDeviationConfirmed(proj.offsetM);
    } else if (_navState.status == NavStatus.onRoute &&
        (before == NavStatus.offRoute ||
            before == NavStatus.rerouting ||
            before == NavStatus.rerouteFailed)) {
      _onBackOnRoute();
    }
  }

  /// 偏航确认（5.3）：旧步骤播报立即停止、待发语音队列清空、
  /// 显示「正在重新规划」、发起真实重规划请求。GPS 采集与轨迹绝不中断。
  void _onDeviationConfirmed(double offsetM) {
    VoiceLog.instance.log(VoiceLogKind.system, 'reroute',
        detail: '偏航确认 offset=${offsetM.round()}m，停播旧提示并发起重规划');
    _announcer.suspendForReroute(); // 5.3#1/#2/#5
    _rerouteAutoAttempts = 0; // 新的偏航事件重置自动重试计数（5.7#5）
    _tryReroute(auto: true); // 同步段完成锁检查与状态迁移
    if (_navState.status != NavStatus.rerouting && mounted) {
      // 冷却期/自动次数用尽：如实提示，保留手动重试入口
      unawaited(_tts.speak('路线已偏离，请返回原定路线', flush: true));
    }
  }

  /// 自然跑回原路线（未接入重规划结果）：恢复播报。
  void _onBackOnRoute() {
    VoiceLog.instance.log(VoiceLogKind.system, 'reroute',
        detail: '已自行回到原路线（status→onRoute）');
    _announcer.onResume(alongM: _lastAlong ?? _alongForDraw);
    unawaited(_tts.speak('已回到规划路线', flush: false));
    _rerouteAutoAttempts = 0;
    if (mounted) setState(() {});
  }

  /// 发起重规划请求（5.7：在飞锁 + 请求 ID + 冷却 + 自动次数上限）。
  /// 手动重试（auto=false）不受冷却与次数限制，但仍受状态机锁约束。
  Future<void> _tryReroute({required bool auto}) async {
    if (_rerouteInFlight) return; // 5.7#6：移动中已有在飞请求，不重复发起
    final RoutePath? path = _activePath;
    final List<TrackPoint> pts = _recorder.points;
    if (path == null || pts.isEmpty || path.points.length < 2) return;
    final DateTime now = DateTime.now();
    if (auto) {
      if (_rerouteCooldownUntil != null &&
          now.isBefore(_rerouteCooldownUntil!)) {
        return;
      }
      if (_rerouteAutoAttempts >= _maxAutoRerouteAttempts) return;
    }
    if (!_navState.beginReroute()) return; // 状态机锁：仅 offRoute/rerouteFailed 可进入
    final int reqId = ++_rerouteReqId;
    _rerouteInFlight = true;
    if (auto) _rerouteAutoAttempts++;
    unawaited(_tts.speak('路线偏离，正在重新规划', flush: true)); // 5.3#4
    if (mounted) setState(() {});

    final TrackPoint last = pts.last;
    final double target = widget.targetM ?? _plannedPath?.total ?? 0;
    try {
      final ReroutePlan plan = await _rerouteClient.request(
        lng: last.longitude,
        lat: last.latitude,
        headingDeg: _heading.heading,
        polyline: path.points
            .map((LatLng p) => <double>[p.longitude, p.latitude])
            .toList(),
        alongM: _lastAlong ?? 0,
        targetM: target,
        completedM: _recorder.distanceMeters,
      );
      if (!mounted || reqId != _rerouteReqId) return; // 过期结果直接丢弃
      if (_navState.status != NavStatus.rerouting) {
        // 在飞期间用户已自然跑回 → 结果作废（5.7#6），状态已是 onRoute
        VoiceLog.instance.log(VoiceLogKind.system, 'reroute',
            detail: '请求返回时已回到原路线，丢弃结果 ${plan.rerouteId}');
        return;
      }
      _navState.rerouteSucceeded(); // rerouting → rerouted
      _applyReroute(plan); // 原子接入 → acceptNewRoute() → onRoute
    } catch (e) {
      if (!mounted || reqId != _rerouteReqId) return;
      _navState.rerouteFailure(); // rerouting → rerouteFailed
      _rerouteCooldownUntil = DateTime.now().add(_rerouteCooldown);
      VoiceLog.instance.log(VoiceLogKind.error, 'reroute',
          detail: '重规划失败: $e');
      // 5.7#9：断网/后端不可用——语音如实提示，运动继续记录，绝不结束
      unawaited(_tts.speak('暂时无法重新规划路线，将继续记录本次运动', flush: true));
      // 冷却期后自动再试一次（受自动次数上限约束）；手动按钮始终可用
      _rerouteRetryTimer?.cancel();
      _rerouteRetryTimer = Timer(_rerouteCooldown, () {
        if (mounted && _navState.status == NavStatus.rerouteFailed) {
          _tryReroute(auto: true);
        }
      });
      if (mounted) setState(() {});
    } finally {
      if (reqId == _rerouteReqId) _rerouteInFlight = false;
    }
  }

  /// 5.4#8–#11：新路线版本原子接入。
  /// 原路线已跑部分与 GPS 轨迹绝不修改——只切换导航基准与播报 steps。
  void _applyReroute(ReroutePlan plan) {
    final List<LatLng> merged = plan.mergedRemainingPolyline
        .map((List<double> p) => LatLng(p[1], p[0]))
        .toList();
    if (merged.length < 2) {
      _navState.rerouteFailure();
      return;
    }
    final List<RouteStep> newSteps = _rebaseSteps(plan);
    final List<LatLng> connector = plan.connectorPolyline
        .map((List<double> p) => LatLng(p[1], p[0]))
        .toList();
    setState(() {
      _activePath = RoutePath.fromPoints(merged);
      _activePts = merged;
      _activeSteps = newSteps;
      _connectorPts = connector.length >= 2 ? connector : null;
      _rejoinAlongActive = plan.connectorM; // 越过它 = 接回原剩余路线
      _rejoinAnnounced = false;
      _lastAlong = null; // 新路径首帧全局投影重锚定
      _alongForDraw = 0;
      _hasFix = false; // 「active 已跑段」重新起算；GPS 轨迹独立不受影响
      // M-G：路线代数 +1 → 切片/连接段/canonical 缓存全部失效重建
      _routeGen++;
      _slicedGen = -1;
      _routeLineCache = <Polyline>{};
      _connectorLineCache = <Polyline>{};
      _canonicalRefLine = null;
      if (plan.withinTolerance) {
        _rerouteWarning = null;
      } else {
        // 5.5：超出目标容差时如实展示新预计总里程，绝不伪装达标
        final double overKm = (plan.estimatedTotalM - plan.targetM) / 1000;
        _rerouteWarning = '新路线预计总里程 '
            '${(plan.estimatedTotalM / 1000).toStringAsFixed(1)} 公里'
            '（比原目标多 ${overKm.toStringAsFixed(1)} 公里）';
      }
    });
    VoiceLog.instance.log(VoiceLogKind.system, 'reroute',
        detail: '接入新路线 ${plan.rerouteId}: 连接段=${plan.connectorM.round()}m '
            '接回点@${plan.rejoinAlongM.round()}m 跳过=${plan.skippedM.round()}m '
            '新剩余=${plan.remainingM.round()}m 预计总=${plan.estimatedTotalM.round()}m '
            'within=${plan.withinTolerance} api=${plan.apiCalls} '
            '耗时=${plan.elapsedS}s');
    // 5.8：旧步骤 ID 与队列全部作废，语音在新 steps 上重建
    _announcer.rebind(
      newSteps,
      announcement: plan.withinTolerance
          ? '路线已经重新规划，请沿当前道路继续前进'
          : '路线已经重新规划，新路线比原目标略长，请沿当前道路继续前进',
    );
    _navState.acceptNewRoute(); // rerouted → onRoute（接入完成）
  }

  /// 原剩余 steps 重定基到新路径：接回点之前的步骤作废（连同被跳过的
  /// 路段），其余平移 `connectorM - rejoinAlongM`。连接段 steps 在前。
  List<RouteStep> _rebaseSteps(ReroutePlan plan) {
    final List<RouteStep> out = List<RouteStep>.of(plan.connectorSteps);
    for (final RouteStep s in _activeSteps) {
      if (s.cumulativeM < plan.rejoinAlongM - 1) continue;
      out.add(RouteStep(
        instruction: s.instruction,
        road: s.road,
        distanceM: s.distanceM,
        cumulativeM: plan.connectorM + (s.cumulativeM - plan.rejoinAlongM),
        action: s.action,
        orientation: s.orientation,
        polyline: s.polyline,
      ));
    }
    return out;
  }

  // ---------- 覆盖物（稳定 id，插件按 id 原地增量更新） ----------

  /// 视觉融合（模块 E）：导航基准线拆成「已跑（低权重蓝灰）」+「剩余（渐变
  /// 主线）」，GPS 实际轨迹（橙 + 白描边）压在最上——三者数据各自独立，
  /// 展示层合成。偏航时橙色轨迹离开蓝色剩余线，真实偏离清晰可见，绝不被
  /// 遮盖。阶段 M-D：基准线 = _activePath（重规划后为合并路线），连接段
  /// 以琥珀色单独绘制（6.3：rerouteSegment 与原路线明显区分）。
  /// M-G：轨迹 LatLng 增量同步——只换算 recorder 新增的点。
  /// 旧实现每次重建都 `pts.map(...).toList()` 全表重映射（O(N) 拷贝，
  /// 长跑 2 小时 ≈7200 点 ×每秒 1–2 次重建）；现在均摊 O(新增)。
  List<LatLng> _syncTrackLatLngs(List<TrackPoint> pts) {
    if (pts.length < _trackPtsSeen) {
      // recorder.start() 清空重开：缓存整体重置（新一次运动）
      _trackLatLngs.clear();
      _trackPtsSeen = 0;
      _trackPolyAt = null;
      _trackLineCache = <Polyline>{};
    }
    for (int i = _trackPtsSeen; i < pts.length; i++) {
      final TrackPoint p = pts[i];
      _trackLatLngs.add(LatLng(p.latitude, p.longitude));
    }
    _trackPtsSeen = pts.length;
    return _trackLatLngs;
  }

  Set<Polyline> _buildPolylines(List<LatLng> trackPts) {
    final Set<Polyline> lines = <Polyline>{};
    // ---- 6.3 canonicalRoute 参考层：重规划后原规划路线保留为最淡参考线。
    // 已跑部分由 GPS 轨迹诚实呈现、绝不被覆盖；对象缓存——每个路线代数
    // 只构建一次（M-G）。
    if (_connectorPts != null && _plannedPts.length >= 2) {
      _canonicalRefLine ??= Polyline(
        points: _plannedPts,
        color: RouteStyle.canonicalRefColor,
        width: RouteStyle.canonicalRefWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCanonicalRef,
      )..setIdForCopy('canonical-ref');
      lines.add(_canonicalRefLine!);
    }
    // ---- 规划线三层（已完成/描边/主线）：切片缓存，along 前进 ≥5m
    // 或路线代数变化才重切；其余时间复用同一组 Polyline 对象（M-G）。
    final RoutePath? path = _activePath;
    if (path != null && _activePts.length >= 2) {
      final double along =
          (_hasFix && _started) ? _alongForDraw.clamp(0.0, path.total) : -1;
      final bool needSlice = _slicedGen != _routeGen ||
          (along < 0) != (_slicedAlong < 0) ||
          (along >= 0 && (along - _slicedAlong).abs() >= 5.0);
      if (needSlice) {
        List<LatLng> remaining = _activePts;
        List<LatLng>? completed;
        if (along >= 0) {
          completed = path.upTo(along);
          remaining = path.fromDistance(along);
        }
        _routeLineCache = _buildRouteLines(completed, remaining);
        _slicedRemaining = remaining;
        _slicedAlong = along;
        _slicedGen = _routeGen;
      }
      lines.addAll(_routeLineCache);
      // ---- 阶段 N：去返程并排双轨（任务书 6.3 硬性要求）----
      // 折返段（同一物理道路的双向行程）先按中心线遮断，再把去/返两段
      // 分别垂线偏移绘制，得到两条清晰分开、各带方向的轨道。
      // 偏移仅用于显示：canonical 折线与 GPS 记录一个点都不改。
      if (_slicedRemaining.length >= 8 && !_lastOffRoute) {
        final List<FoldPass> folds = findFoldPasses(_slicedRemaining);
        if (folds.isNotEmpty) {
          final double mpp = metersPerPixel(
              _cam.zoom ?? _zoomGoalFor(null), _slicedRemaining.first.latitude);
          for (final FoldPass f in folds) {
            lines.add(Polyline(
              points: _slicedRemaining.sublist(f.outStart, f.backEnd + 1),
              color: RouteStyle.casingColor,
              width: RouteStyle.dualTrackEraseWidth,
              capType: CapType.round,
              joinType: JoinType.round,
              zIndex: RouteStyle.zDualErase,
            )..setIdForCopy('dual-erase-${f.outStart}'));
          }
          final List<DisplayTrack> tracks = buildDisplayTracks(
              _slicedRemaining, folds,
              metersPerPx: mpp, offsetPx: RouteStyle.dualTrackOffsetPx);
          int ti = 0;
          for (final DisplayTrack t in tracks) {
            if (t.points.length < 2) continue;
            lines.add(Polyline(
              points: t.points,
              color: RouteStyle.casingColor,
              width: RouteStyle.casingWidth,
              capType: CapType.round,
              joinType: JoinType.round,
              zIndex: RouteStyle.zDualCasing,
            )..setIdForCopy('dual-casing-$ti'));
            lines.add(Polyline(
              points: t.points,
              gradient: true,
              colorList: RouteStyle.plannedGradient,
              color: RouteStyle.plannedGradient.first,
              width: RouteStyle.coreWidth,
              capType: CapType.round,
              joinType: JoinType.round,
              zIndex: RouteStyle.zDualCore,
            )..setIdForCopy('dual-core-$ti'));
            ti++;
          }
        }
      }
    }
    // ---- 重规划连接段（琥珀色，真实步行道路，5.6 connector 折线）----
    final List<LatLng>? connector = _connectorPts;
    if (connector != null && connector.length >= 2) {
      if (_connectorLineCache.isEmpty) {
        _connectorLineCache = <Polyline>{
          Polyline(
            points: connector,
            color: RouteStyle.casingColor,
            width: RouteStyle.rerouteCasingWidth,
            capType: CapType.round,
            joinType: JoinType.round,
            zIndex: RouteStyle.zRerouteCasing,
          )..setIdForCopy('reroute-casing'),
          Polyline(
            points: connector,
            color: RouteStyle.rerouteColor,
            width: RouteStyle.rerouteCoreWidth,
            capType: CapType.round,
            joinType: JoinType.round,
            zIndex: RouteStyle.zReroute,
          )..setIdForCopy('reroute-core'),
        };
      }
      lines.addAll(_connectorLineCache);
    }
    // ---- GPS 真实轨迹：原生更新按 2s 节流（M-G）。
    // recorder 记录完全不受影响——只是显示层刷新频率从每帧降到 0.5Hz，
    // 轨迹线追平延迟 ≤2s，跑者位置本身由 20Hz 相机与箭头实时表达。
    final DateTime now = DateTime.now();
    final bool stale = _trackPolyAt == null ||
        now.difference(_trackPolyAt!) >= _trackPolyInterval;
    if (trackPts.length >= 2 && (_trackLineCache.isEmpty || stale)) {
      final List<LatLng> snapshot = List<LatLng>.of(trackPts);
      _trackLineCache = <Polyline>{
        Polyline(
          points: snapshot,
          color: RouteStyle.trackCasingColor,
          width: RouteStyle.trackCasingWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zTrackCasing,
        )..setIdForCopy('track-casing'),
        Polyline(
          points: snapshot,
          color: RouteStyle.trackColor,
          width: RouteStyle.trackCoreWidth,
          capType: CapType.round,
          joinType: JoinType.round,
          zIndex: RouteStyle.zTrack,
        )..setIdForCopy('track-core'),
      };
      _trackPolyAt = now;
    }
    lines.addAll(_trackLineCache);
    return lines;
  }

  /// 规划线三层 Polyline 构建（从 _buildPolylines 拆出，供切片缓存复用）。
  Set<Polyline> _buildRouteLines(List<LatLng>? completed, List<LatLng> remaining) {
    final Set<Polyline> out = <Polyline>{};
    if (completed != null && completed.length >= 2) {
      out.add(Polyline(
        points: completed,
        color: RouteStyle.completedColor,
        width: RouteStyle.completedWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCompleted,
      )..setIdForCopy('planned-done'));
    }
    if (remaining.length >= 2) {
      out.add(Polyline(
        points: remaining,
        color: RouteStyle.casingColor,
        width: RouteStyle.casingWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCasing,
      )..setIdForCopy('planned-casing'));
      out.add(Polyline(
        points: remaining,
        gradient: true,
        colorList: RouteStyle.plannedGradient,
        color: RouteStyle.plannedGradient.first,
        width: RouteStyle.coreWidth,
        capType: CapType.round,
        joinType: JoinType.round,
        zIndex: RouteStyle.zCore,
      )..setIdForCopy('planned-core'));
    }
    return out;
  }

  Set<Marker> _buildMarkers(List<LatLng> trackPts) {
    final Set<Marker> markers = <Marker>{};
    if (_plannedPts.isNotEmpty) {
      markers.add(Marker(
        position: _plannedPts.first,
        icon: _startIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        infoWindow: const InfoWindow(title: '起点 / 终点'),
        zIndex: 200,
      )..setIdForCopy('run-start'));
    }
    if (trackPts.isNotEmpty && !_followCamera) {
      // 仅在「平移浏览」模式显示地图上的位置圆点（无方向语义——真机证实
      // 高德 Marker 随地图旋转，方向不可保证；跟随模式方向由屏幕固定
      // 箭头表达，且相机中心=GPS 坐标，圆点与箭头位置天然一致）。
      markers.add(Marker(
        position: trackPts.last,
        icon: _dotIcon ?? _runnerIcon ?? BitmapDescriptor.defaultMarker,
        anchor: const Offset(0.5, 0.5),
        zIndex: 300,
      )..setIdForCopy('run-pos'));
    }
    // ---- 阶段 N：方向箭头（6.2）+ 真实转弯标记（6.4）----
    if (_started && !_lastOffRoute && _activePath != null && _lastProj != null) {
      final RoutePath path = _activePath!;
      final double zoom = _cam.zoom ?? _zoomGoalFor(null);
      // 箭头间距随缩放自适应：放大看清方向、缩小不拥挤
      final double spacing = zoom >= 18 ? 220.0 : (zoom >= 16.5 ? 400.0 : 700.0);
      if (_arrowIcon != null) {
        double d = (_lastProj!.alongM / spacing).ceil() * spacing;
        int i = 0;
        while (d < path.total - 15 && i < 12) {
          final RoutePosition rp = path.at(d);
          markers.add(Marker(
            position: rp.point,
            rotation: rp.bearing,
            icon: _arrowIcon!,
            anchor: const Offset(0.5, 0.5),
            zIndex: RouteStyle.zArrowMarker,
          )..setIdForCopy('run-arrow-$i'));
          i++;
          d += spacing;
        }
      }
      // 只标最近 3 个真实转弯（6.7 信息层级：不把地图贴满标签）
      int t = 0;
      for (final RouteStep s in _activeSteps) {
        if (s.cumulativeM <= _lastProj!.alongM + 5 ||
            s.cumulativeM > path.total - 10) {
          continue;
        }
        final BitmapDescriptor? icon = switch (s.action) {
          'left' => _turnLeftIcon,
          'right' => _turnRightIcon,
          'uturn' => _turnUTurnIcon,
          _ => null,
        };
        if (icon == null) continue;
        markers.add(Marker(
          position: path.at(s.cumulativeM).point,
          icon: icon,
          anchor: const Offset(0.5, 0.5),
          infoWindow: InfoWindow(
              title: _turnNames[s.action] ?? '', snippet: s.road),
          zIndex: RouteStyle.zTurnAnnotation,
        )..setIdForCopy('run-turn-$t'));
        t++;
        if (t >= 3) break;
      }
    }
    return markers;
  }

  void _onMapCreated(AMapController controller) {
    _controller = controller;
    if (_plannedPts.length >= 2) {
      final List<double> lngs = _plannedPts.map((p) => p.longitude).toList()..sort();
      final List<double> lats = _plannedPts.map((p) => p.latitude).toList()..sort();
      // 预览构图：整条路线 + 北朝上（倒计时覆盖层就在其上方）。
      controller.moveCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(lats.first, lngs.first),
            northeast: LatLng(lats.last, lngs.last),
          ),
          40,
        ),
        animated: false,
      );
    } else {
      final List<TrackPoint> pts = _recorder.points;
      if (pts.isNotEmpty) {
        controller.moveCamera(
          CameraUpdate.newCameraPosition(
            CameraPosition(
              target: LatLng(pts.last.latitude, pts.last.longitude),
              zoom: NavSettings.instance.mapZoom,
            ),
          ),
          animated: false,
        );
      }
    }
  }

  // ---------- 导航提示（顶部面板数据） ----------

  /// 下一转弯：规划 steps 中首个在当前位置前方的转向动作（真实高德步骤）。
  _TurnHint? _nextTurnHint(double alongM) {
    final List<RouteStep> steps = _activeSteps;
    for (final RouteStep s in steps) {
      if (s.cumulativeM <= alongM + 20) continue;
      final IconData? icon = _turnIcons[s.action];
      if (icon == null) continue;
      return _TurnHint(
        icon: icon,
        distM: s.cumulativeM - alongM,
        name: _turnNames[s.action]!,
        road: s.road,
      );
    }
    return null;
  }

  static const Map<String, IconData> _turnIcons = <String, IconData>{
    'left': Icons.turn_left,
    'right': Icons.turn_right,
    'uturn': Icons.u_turn_left,
  };
  static const Map<String, String> _turnNames = <String, String>{
    'left': '左转',
    'right': '右转',
    'uturn': '掉头',
  };

  static String _fmtDist(double m) =>
      m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

  // ---------- UI（模块 F 布局） ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('跑步中'),
        automaticallyImplyLeading: false,
        actions: <Widget>[
          IconButton(
            tooltip: _orientation == MapOrientation.headingUp
                ? '切换为正北朝上'
                : '切换为前进方向朝上',
            icon: Icon(_orientation == MapOrientation.headingUp
                ? Icons.navigation
                : Icons.explore),
            onPressed: _toggleOrientation,
          ),
          IconButton(
            tooltip: _followCamera ? '关闭相机跟随' : '回到跑者位置',
            icon: Icon(_followCamera ? Icons.my_location : Icons.location_searching),
            onPressed: _followCamera
                ? () => setState(() => _followCamera = false)
                : _recenter,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _recorder,
        builder: (BuildContext context, _) {
          final RunState state = _recorder.state;
          final List<TrackPoint> pts = _recorder.points;
          // M-G：增量缓存——只换算新增点，不再每帧全表重映射。
          final List<LatLng> trackPts = _syncTrackLatLngs(pts);

          // 阶段 N：build 只消费 _onNavTick 已算好的结果——不再在 build 里
          // 驱动地图匹配/偏航状态机/语音播报（锁屏不出帧时 build 不执行，
          // 会造成「GPS 在记录但完全没有语音」，这是阶段 M 的锁屏根因）。
          final RouteProjection? proj = _lastProj;
          final bool offRoute = _lastOffRoute;
          final NavStatus navStatus = _navState.status;

          final _TurnHint? hint =
              (proj != null && !offRoute) ? _nextTurnHint(proj.alongM) : null;

          final double? targetM = widget.targetM;
          final double progress = (targetM != null && targetM > 0)
              ? (_recorder.distanceMeters / targetM).clamp(0.0, 1.0)
              : 0.0;
          final double? remainPlannedM =
              (proj != null && _activePath != null && !offRoute)
                  ? (_activePath!.total - proj.alongM)
                  : null;

          return Stack(
            children: <Widget>[
              Column(
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: Stack(
                      children: <Widget>[
                        AMapWidget(
                          apiKey: const AMapApiKey(
                            androidKey: AppConfig.amapAndroidKey,
                            iosKey: AppConfig.amapIosKey,
                          ),
                          privacyStatement: const AMapPrivacyStatement(
                            hasContains: true,
                            hasShow: true,
                            hasAgree: true,
                          ),
                          initialCameraPosition: const CameraPosition(
                            target: LatLng(30.536395, 114.087279),
                            zoom: 15,
                          ),
                          rotateGesturesEnabled: false, // 朝向由模式切换按钮控制，避免手势与跟随打架
                          polylines: _buildPolylines(trackPts),
                          markers: _buildMarkers(trackPts),
                          onMapCreated: _onMapCreated,
                          onCameraMove: _onCameraMove,
                          onCameraMoveEnd: _onCameraMoveEnd,
                        ),
                        // ---- 屏幕固定的居中导航箭头（阶段 L2 规范三）----
                        // 跟随模式：相机中心=GPS 坐标，箭头钉在地图区正中央，
                        // 永远指屏幕正上方（heading-up）或平滑航向（north-up）；
                        // 绝不使用会随地图旋转的 Marker 表达方向。
                        if (_started && _followCamera)
                          Align(
                            alignment: Alignment.center,
                            child: IgnorePointer(
                              child: RunnerArrow(
                                screenRotationDegrees:
                                    _orientation == MapOrientation.northUp
                                        ? (_heading.heading ?? 0)
                                        : 0,
                                showDirection:
                                    _orientation == MapOrientation.headingUp ||
                                        _heading.heading != null,
                              ),
                            ),
                          ),
                        // ---- 顶部：偏航/重规划横幅 / 下一转弯大卡片 / 语音故障提示 ----
                        if (offRoute)
                          Positioned(
                            top: 10,
                            left: 12,
                            right: 12,
                            child: _RerouteBanner(
                              status: navStatus,
                              offsetM: proj?.offsetM ?? 0,
                              onRetry: _rerouteInFlight
                                  ? null
                                  : () => _tryReroute(auto: false),
                            ),
                          )
                        else if (hint != null)
                          Positioned(
                            top: 10,
                            left: 12,
                            right: 12,
                            child: _TurnCard(hint: hint),
                          ),
                        // ---- 容差告警（5.5：新总里程超出原目标时如实展示） ----
                        if (_rerouteWarning != null)
                          Positioned(
                            top: offRoute
                                ? 64
                                : (hint != null ? 96 : 10),
                            left: 12,
                            right: 12,
                            child: _Banner(
                              icon: Icons.info_outline,
                              color: Colors.teal,
                              text: _rerouteWarning!,
                              onDismiss: () =>
                                  setState(() => _rerouteWarning = null),
                            ),
                          ),
                        if (_ttsProblem != null && NavSettings.instance.voiceNavEnabled)
                          Positioned(
                            top: hint != null && !offRoute ? 96 : 10,
                            left: 12,
                            right: 12,
                            child: _Banner(
                              icon: Icons.volume_off,
                              color: Colors.blueGrey,
                              text: _ttsProblem!,
                            ),
                          ),
                        // ---- 公里完成轻提示（不遮挡地图中部） ----
                        if (_toastSplit != null)
                          Positioned(
                            bottom: (_goalReached && !_goalDismissed) ? 150 : 16,
                            left: 0,
                            right: 0,
                            child: Center(child: _KmToast(split: _toastSplit!)),
                          ),
                        // ---- 目标完成卡片（任务书 4.3：不自动结束，
                        //      「继续跑步 / 结束运动」由用户选择） ----
                        if (_goalReached && !_goalDismissed)
                          Positioned(
                            bottom: 16,
                            left: 12,
                            right: 12,
                            child: _GoalCard(
                              distanceMeters: _recorder.distanceMeters,
                              onContinue: () =>
                                  setState(() => _goalDismissed = true),
                              onEnd: _end,
                            ),
                          ),
                        // ---- 手动平移后的回中按钮 ----
                        if (!_followCamera)
                          Positioned(
                            right: 12,
                            bottom: 16,
                            child: FloatingActionButton.small(
                              heroTag: 'run-recenter',
                              onPressed: _recenter,
                              child: const Icon(Icons.my_location),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // ---- 底部数据面板（模块 F：距离/配速/时长/剩余 + 按钮） ----
                  Expanded(
                    flex: 2,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.baseline,
                          textBaseline: TextBaseline.alphabetic,
                          children: <Widget>[
                            Text(formatKm(_recorder.distanceMeters),
                                style: const TextStyle(
                                    fontSize: 56, fontWeight: FontWeight.bold, height: 1.1)),
                            const Padding(
                              padding: EdgeInsets.only(left: 6),
                              child: Text('公里', style: TextStyle(fontSize: 16)),
                            ),
                          ],
                        ),
                        if (targetM != null && targetM > 0) ...<Widget>[
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 36),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 8,
                                backgroundColor: Colors.grey.shade200,
                                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2979FF)),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            _Metric(label: '当前配速', value: formatPace(_recorder.currentPaceSecondsPerKm), big: true),
                            _Metric(label: '平均配速', value: formatPace(_recorder.avgPaceSecondsPerKm)),
                            _Metric(label: '时长', value: formatDuration(_recorder.durationSeconds), big: true),
                            _Metric(
                              label: '剩余(规划)',
                              value: remainPlannedM != null
                                  ? _fmtDist(remainPlannedM)
                                  : (targetM != null && targetM > 0
                                      ? _fmtDist((targetM - _recorder.distanceMeters).clamp(0, double.infinity))
                                      : '--'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: <Widget>[
                            if (state == RunState.running)
                              FilledButton.tonalIcon(
                                onPressed: _pause,
                                icon: const Icon(Icons.pause),
                                label: const Text('暂停'),
                              )
                            else if (state == RunState.paused)
                              FilledButton.tonalIcon(
                                onPressed: _resume,
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('继续'),
                              ),
                            if (_started)
                              FilledButton.icon(
                                onPressed: _end,
                                icon: const Icon(Icons.stop),
                                label: const Text('结束'),
                              ),
                          ],
                        ),
                        if (state == RunState.paused)
                          const Padding(
                            padding: EdgeInsets.only(top: 8),
                            child: Text('已暂停：计时冻结，语音播报停止',
                                style: TextStyle(fontSize: 12, color: Colors.grey)),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              // ---- 三秒环形倒计时（模块 C；阶段 M-B 语音倒计时）----
              // engine 受语音导航总开关控制：关闭或引擎不可用时纯视觉倒计时。
              if (_showCountdown)
                CountdownOverlay(
                  onGo: _onCountdownGo,
                  onCancelled: _onCountdownCancel,
                  engine: NavSettings.instance.voiceNavEnabled ? _tts : null,
                  onComplete: () {
                    if (mounted) setState(() => _showCountdown = false);
                  },
                ),
            ],
          );
        },
      ),
    );
  }
}

/// NavSettings → NavAnnouncer 的适配（保持播报引擎可单测）。
class _SettingsVoiceConfig implements NavVoiceConfig {
  @override
  bool get voiceNav => NavSettings.instance.voiceNavEnabled;

  @override
  bool get kmPace => NavSettings.instance.kmPaceEnabled;

  @override
  double get announceM => NavSettings.instance.announceDistanceM;
}

class _TurnHint {
  const _TurnHint({
    required this.icon,
    required this.distM,
    required this.name,
    required this.road,
  });
  final IconData icon;
  final double distM;
  final String name;
  final String road;
}

/// 顶部转弯大卡片（模块 F：户外可读，转弯图标 + 距离大字 + 动作/道路）。
class _TurnCard extends StatelessWidget {
  const _TurnCard({required this.hint});

  final _TurnHint hint;

  @override
  Widget build(BuildContext context) {
    final bool km = hint.distM >= 1000;
    final String distText =
        km ? (hint.distM / 1000).toStringAsFixed(1) : '${(hint.distM / 10).round() * 10}';
    return Material(
      color: const Color(0xF01565C0),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(hint.icon, color: Colors.white, size: 40),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  distText,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 30, fontWeight: FontWeight.w800, height: 1),
                ),
                Text(km ? '公里后' : '米后',
                    style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    hint.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 20, fontWeight: FontWeight.w700),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (hint.road.isNotEmpty)
                    Text(
                      '进入 ${hint.road}',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 公里完成轻提示（模块 B/F：小卡片，不遮挡地图，4 秒自动消失）。
class _KmToast extends StatelessWidget {
  const _KmToast({required this.split});

  final KmSplit split;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE637474F),
      borderRadius: BorderRadius.circular(20),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.flag, color: Color(0xFF69F0AE), size: 18),
            const SizedBox(width: 8),
            Text(
              '第 ${split.index} 公里 · 配速 ${formatPace(split.paceSecondsPerKm)}',
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// 目标完成卡片（阶段 M-C，任务书 4.3）：语音已提醒，屏幕常驻显示，
/// 「继续跑步」收起卡片继续累计，「结束运动」走正常结束流程进总结页。
/// 绝不自动结束、绝不要求语音应答。
class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.distanceMeters,
    required this.onContinue,
    required this.onEnd,
  });

  final double distanceMeters;
  final VoidCallback onContinue;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xF2103A20),
      borderRadius: BorderRadius.circular(14),
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.emoji_events, color: Color(0xFFFFD54F), size: 26),
                const SizedBox(width: 10),
                const Text('目标已完成！',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w700)),
                const Spacer(),
                Text('已跑 ${formatKm(distanceMeters)} km',
                    style: const TextStyle(
                        color: Color(0xFFA5D6A7), fontSize: 13)),
              ],
            ),
            const SizedBox(height: 4),
            const Text('您可以选择继续跑步，或结束本次运动',
                style: TextStyle(color: Colors.white70, fontSize: 12.5)),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton(
                    onPressed: onContinue,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white54),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('继续跑步'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: onEnd,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF66BB6A),
                      foregroundColor: const Color(0xFF0B2A14),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('结束运动'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 地图顶部提示横幅（偏航告警 / 语音故障 / 容差告警，可带关闭按钮）。
class _Banner extends StatelessWidget {
  const _Banner(
      {required this.icon, required this.color, required this.text, this.onDismiss});

  final IconData icon;
  final Color color;
  final String text;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withAlpha(235),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          children: <Widget>[
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
            ),
            if (onDismiss != null)
              InkWell(
                onTap: onDismiss,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, color: Colors.white70, size: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 偏航/重规划状态横幅（阶段 M-D，任务书 5.3#4 / 5.7#9）：
/// - offRoute：已确认偏离（自动请求被冷却/次数限制时给手动入口）；
/// - rerouting：「路线偏离，正在重新规划」+ 转圈；
/// - rerouteFailed：无法重规划（断网/后端不可用）——运动继续记录，
///   提供「重试」按钮；绝不自动结束运动。
class _RerouteBanner extends StatelessWidget {
  const _RerouteBanner({
    required this.status,
    required this.offsetM,
    this.onRetry,
  });

  final NavStatus status;
  final double offsetM;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    late final IconData icon;
    late final Color color;
    late final String text;
    switch (status) {
      case NavStatus.rerouting:
        icon = Icons.gps_not_fixed;
        color = Colors.deepOrange;
        text = '路线偏离（约 ${offsetM.round()} 米），正在重新规划…';
      case NavStatus.rerouteFailed:
        icon = Icons.cloud_off;
        color = Colors.red;
        text = '暂时无法重新规划 · 运动仍在正常记录';
      default:
        icon = Icons.warning_amber_rounded;
        color = Colors.deepOrange;
        text = '已偏离规划路线约 ${offsetM.round()} 米，请返回蓝色路线';
    }
    return Material(
      color: color.withAlpha(235),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 6, 9),
        child: Row(
          children: <Widget>[
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ),
            if (status == NavStatus.rerouting)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                ),
              )
            else if (onRetry != null)
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.big = false});

  final String label;
  final String value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        Text(value,
            style: TextStyle(
                fontSize: big ? 24 : 20,
                fontWeight: big ? FontWeight.w700 : FontWeight.w600)),
        const SizedBox(height: 4),
        Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 12)),
      ],
    );
  }
}
