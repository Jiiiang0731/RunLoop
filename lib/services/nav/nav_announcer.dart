import '../../models/km_split.dart';
import '../../models/planned_route.dart';
import 'tts_service.dart';

/// 播报器所需的最小设置视图（NavSettings 实现之；单测用假实现）。
abstract class NavVoiceConfig {
  bool get voiceNav;
  bool get kmPace;
  double get announceM;
}

/// 普通话转弯播报状态机（P0 重写）。
///
/// 数据源铁律：只消费服务端统一 [RouteTurn]（真实折线累计里程 + 高德
/// action + 几何交叉验证）。绝不根据地图箭头/屏幕方向/地图旋转再算左右。
///
/// P0 关键修正：
/// - **进度基准统一**：`atM` 是地图实际绘制折线的累计里程，与 RoutePath
///   投影同一基准，不再出现「步骤里程 1076m / 折线 991m」导致的滞后；
/// - **动态提前量**：`lead = max(用户设定, 实时配速 × 10s)`，上限 150m，
///   跑得越快越早提示；
/// - **错过即作废**：越过转弯点 >30m 后不再补播过期指令；
/// - **两阶段**：提前播报 + 到位确认（越过前 8m），各自最多一次；
/// - **低置信度降级**：方向冲突/接缝伪转弯时改为一般方向提醒，不编造左右；
/// - 偏航、暂停、连续转弯、公里配速的既有语义保持不变。
class NavAnnouncer {
  NavAnnouncer({
    required SpeechEngine engine,
    required NavVoiceConfig config,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _engine = engine;
    _config = config;
  }

  late final SpeechEngine _engine;
  late final NavVoiceConfig _config;
  final DateTime Function() _clock;

  /// 连续转弯合并窗口（米）。
  static const double combineWindowM = 80;

  /// 到位确认触发线（米）：距转弯点 ≤8m 视为到达。
  static const double arrivalWindowM = 8;

  /// 错过判定（米）：越过转弯点超过该距离即作废，绝不再补播。
  static const double missedWindowM = 30;

  /// 动态提前量：按配速预留的秒数。
  static const double leadSeconds = 10;

  /// 提前量上下限（米）。
  static const double minLeadM = 25;
  static const double maxLeadM = 150;

  /// 公里配速排队过期时间：超过即丢弃（不允许过期语音积压）。
  static const Duration kmExpiry = Duration(seconds: 15);

  /// 转弯播报后的公里配速静默期（避免 cancel 回调竞态插播）。
  static const Duration turnGuard = Duration(seconds: 3);

  static const Map<String, String> _actionText = <String, String>{
    'left': '左转',
    'right': '右转',
    'uturn': '掉头',
  };

  List<RouteTurn> _turns = const <RouteTurn>[];
  final Set<String> _announced = <String>{};
  bool _offRoute = false;
  bool _paused = false;
  String? _pendingKmText;
  DateTime? _pendingKmAt;
  DateTime? _lastTurnAt;

  bool get offRoute => _offRoute;

  /// 当前使用的统一转弯事件（只读，供调试/诊断）。
  List<RouteTurn> get turns => List<RouteTurn>.unmodifiable(_turns);

  /// 绑定路线 steps（开始跑步时调用）。旧调用兼容：由结构化 action 派生
  /// RouteTurn；新代码应优先调用 [attachTurns]。
  void attach(List<RouteStep> steps) {
    attachTurns(deriveTurnsFromSteps(steps), steps: steps);
  }

  /// 绑定统一 TurnEvent（P0 主路径）。
  void attachTurns(List<RouteTurn> turns, {List<RouteStep>? steps}) {
    _turns = List<RouteTurn>.of(turns)
      ..sort((RouteTurn a, RouteTurn b) => a.atM.compareTo(b.atM));
    _announced.clear();
    _offRoute = false;
    _paused = false;
    _pendingKmText = null;
    _lastTurnAt = null;
    _engine.onIdle = _onEngineIdle;
    if (!_config.voiceNav) return;
    String firstRoad = '';
    if (steps != null) {
      firstRoad = steps
          .map((RouteStep s) => s.road)
          .firstWhere((String r) => r.isNotEmpty, orElse: () => '');
    } else {
      firstRoad = _turns
          .map((RouteTurn t) => t.roadFrom)
          .firstWhere((String r) => r.isNotEmpty, orElse: () => '');
    }
    // 「开始跑步」由倒计时播报；这里只排队出发方向，避免重复。
    _speak(firstRoad.isEmpty ? '出发' : '沿$firstRoad前进', flush: false);
  }

  /// 每次定位/匹配 tick 调用（约 1Hz）。
  ///
  /// [speedMps] 为当前 GPS 速度（米/秒）；有有效值时按「配速 × 10s」动态
  /// 提前提示，无有效值时使用用户设定的固定提前量。
  void onPosition({
    required double alongM,
    required bool offRoute,
    double? speedMps,
  }) {
    if (_paused) return;

    // ---- 偏航边沿 ----
    if (offRoute && !_offRoute) {
      _offRoute = true;
      _pendingKmText = null;
      if (_config.voiceNav) {
        _speakTurn('已偏离规划路线，请返回蓝色路线');
      }
    } else if (!offRoute && _offRoute) {
      _offRoute = false;
      if (_config.voiceNav) _speak('已回到规划路线', flush: false);
    }

    if (!_config.voiceNav) return;

    if (offRoute) {
      // 偏航期间静默，但把已经越过的转弯标记为已播——回归后不补播旧指令。
      for (final RouteTurn t in _turns) {
        if (t.atM <= alongM + missedWindowM) {
          _announced.add('pre-${t.id}');
          _announced.add('now-${t.id}');
        }
      }
      return;
    }

    final double lead = _leadM(speedMps);
    bool spokeThisTick = false;

    // ---- 先处理已越过/到位，避免 GPS 跳点后补播过期指令 ----
    for (final RouteTurn t in _turns) {
      if (spokeThisTick) break;
      if (t.kind == 'end') {
        final double d = t.atM - alongM;
        if (d <= 20 && d > -5 && _announced.add('end-${t.id}')) {
          _speakTurn('已到达路线终点');
          spokeThisTick = true;
        }
        continue;
      }
      if (!t.announce) continue;
      final double remaining = t.atM - alongM;
      if (t.isTurn) {
        // 错过：越过 >30m，永久作废（绝不把过期路口当未来转弯）。
        if (remaining < -missedWindowM) {
          _announced.add('pre-${t.id}');
          _announced.add('now-${t.id}');
          continue;
        }
        if (remaining <= arrivalWindowM) {
          if (!_announced.contains('now-${t.id}')) {
            _announced.add('pre-${t.id}');
            _announced.add('now-${t.id}');
            final String? text = _nowText(t);
            if (text != null) {
              _speakTurn(text);
              spokeThisTick = true;
            }
          }
          continue;
        }
      } else if (t.kind == 'straight') {
        if (remaining < -missedWindowM) {
          _announced.add('pre-${t.id}');
          continue;
        }
        if (remaining <= lead && remaining > -missedWindowM) {
          if (_announced.add('pre-${t.id}')) {
            final String road = t.roadTo.isNotEmpty ? t.roadTo : t.roadFrom;
            if (road.isNotEmpty) {
              _speakTurn('沿$road继续直行');
              spokeThisTick = true;
            }
          }
        }
        continue;
      }
    }

    // ---- 提前播报：窗口内最近的一条未播转弯（每 tick 至多一条）----
    if (spokeThisTick) return;
    for (int i = 0; i < _turns.length; i++) {
      final RouteTurn t = _turns[i];
      if (!t.announce || !t.isTurn) continue;
      final double remaining = t.atM - alongM;
      if (remaining <= arrivalWindowM) continue; // 已到位/已过
      if (remaining > lead) break; // 按里程升序，后面更远
      if (_announced.contains('pre-${t.id}')) continue;
      _announced.add('pre-${t.id}');

      // 连续转弯合并：紧随其后的转弯 ≤80m 且置信度足够 → 一句话说完。
      RouteTurn? next;
      for (int k = i + 1; k < _turns.length; k++) {
        if (!_turns[k].isTurn || !_turns[k].announce) continue;
        if (_turns[k].atM - t.atM <= combineWindowM) {
          next = _turns[k];
        }
        break;
      }

      if (t.confidence == 'low') {
        // 方向不可靠：降级为一般提醒，绝不编造左右。
        _speakTurn('前方有路口，请按地图路线方向行进');
        return;
      }
      final String act = _actionText[t.kind]!;
      final String road = t.roadTo.isNotEmpty ? t.roadTo : t.roadFrom;
      final String roadPart = road.isNotEmpty ? '进入$road' : '';
      if (next != null &&
          next.confidence != 'low' &&
          next.kind != 'uturn' &&
          !_announced.contains('pre-${next.id}')) {
        final double d2 = next.atM - t.atM;
        final String act2 = _actionText[next.kind]!;
        final String road2 =
            next.roadTo.isNotEmpty ? next.roadTo : next.roadFrom;
        final String roadPart2 = road2.isNotEmpty ? '进入$road2' : '';
        _announced.add('pre-${next.id}');
        _speakTurn('前方 ${_sayDist(remaining)}米$act$roadPart，'
            '随后约 ${_sayDist(d2)}米$act2$roadPart2');
      } else {
        _speakTurn('前方 ${_sayDist(remaining)}米$act$roadPart');
      }
      return;
    }
  }

  /// 完成一公里（模块 B 事件）：排队播报，不插队、不积压。
  void onKmSplit(KmSplit split) {
    if (!_config.voiceNav || !_config.kmPace || _paused) return;
    final String text = split.announcement();
    if (_engine.isSpeaking) {
      _pendingKmText = text;
      _pendingKmAt = _clock();
    } else {
      _speak(text, flush: false);
    }
  }

  /// 暂停：立即停止一切播报。
  void onPause() {
    _paused = true;
    _pendingKmText = null;
    _engine.stop();
  }

  /// 继续：重新武装下一条转弯，恢复正确进度。
  void onResume({required double alongM}) {
    _paused = false;
    for (final RouteTurn t in _turns) {
      if (!t.isTurn) continue;
      if (t.atM - alongM > arrivalWindowM) {
        // 暂停期间可能错过了窗口内播报 → 只重新武装“提前提醒”，
        // “到位确认”仍由越线逻辑负责，避免恢复瞬间重复喊两条。
        _announced.remove('pre-${t.id}');
        break;
      }
    }
  }

  /// 结束跑步：立即停止并清空。
  void onEnd() {
    _pendingKmText = null;
    _pendingKmAt = null;
    _engine.onIdle = null;
    _engine.stop();
  }

  // ---------- 动态重规划衔接（阶段 M-D/E） ----------

  /// 偏航确认：立即停播旧路线的一切语音并清空待发队列。
  void suspendForReroute() {
    _paused = true;
    _pendingKmText = null;
    _pendingKmAt = null;
    _engine.onIdle = null;
    _engine.stop();
  }

  /// 重规划成功后原子绑定新版本 turns（旧事件/已播集合/待发队列全部作废）。
  void rebindTurns(List<RouteTurn> turns, {String? announcement}) {
    _turns = List<RouteTurn>.of(turns)
      ..sort((RouteTurn a, RouteTurn b) => a.atM.compareTo(b.atM));
    _announced.clear();
    _offRoute = false;
    _paused = false;
    _pendingKmText = null;
    _pendingKmAt = null;
    _lastTurnAt = null;
    _engine.onIdle = _onEngineIdle;
    if (!_config.voiceNav) return;
    if (announcement != null && announcement.isNotEmpty) {
      _speak(announcement, flush: true);
    }
  }

  /// 旧调用兼容：由 steps 派生后重绑。
  void rebind(List<RouteStep> steps, {String? announcement}) {
    rebindTurns(deriveTurnsFromSteps(steps), announcement: announcement);
  }

  // ---------- 内部 ----------

  /// 动态提前量：无有效配速时使用用户设定；有配速时至少预留 10 秒。
  double _leadM(double? speedMps) {
    final double user = _config.announceM.clamp(minLeadM, maxLeadM);
    if (speedMps == null || speedMps.isNaN || speedMps <= 0.3) {
      return user;
    }
    final double bySpeed = speedMps * leadSeconds;
    return bySpeed.clamp(user, maxLeadM);
  }

  String? _nowText(RouteTurn t) {
    if (t.confidence == 'low') return '现在通过路口，请按地图路线行进';
    final String? act = _actionText[t.kind];
    return act == null ? null : '现在$act';
  }

  void _speakTurn(String text) {
    _lastTurnAt = _clock();
    _speak(text, flush: true);
  }

  void _speak(String text, {required bool flush}) {
    _engine.speak(text, flush: flush);
  }

  void _onEngineIdle() {
    final String? pending = _pendingKmText;
    final DateTime? at = _pendingKmAt;
    _pendingKmText = null;
    _pendingKmAt = null;
    if (pending == null || at == null || _paused) return;
    final DateTime now = _clock();
    if (now.difference(at) > kmExpiry) return; // 过期丢弃
    final DateTime? turn = _lastTurnAt;
    if (turn != null && now.difference(turn) < turnGuard) return; // 转弯静默期
    _speak(pending, flush: false);
  }

  /// 播报距离取整：≥100m 按 10m 取整，<100m 按 5m 取整（口语自然）。
  static int _sayDist(double m) =>
      m >= 100 ? (m / 10).round() * 10 : (m / 5).round() * 5;
}
