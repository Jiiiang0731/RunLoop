import '../../models/km_split.dart';
import '../../models/planned_route.dart';
import 'tts_service.dart';

/// 播报器所需的最小设置视图（NavSettings 实现之；单测用假实现）。
abstract class NavVoiceConfig {
  bool get voiceNav;
  bool get kmPace;
  double get announceM;
}

/// 普通话转弯播报状态机（阶段 L 模块 A，规范 2.2–2.4）。
///
/// 数据源铁律：只使用服务端真实高德 steps（action/road/cumulativeM）与
/// 窗口化地图匹配得到的沿路线里程 [alongM]，绝不根据地图箭头/视觉层猜测。
///
/// 规则：
/// - 提前播报：距转弯 ≤ [NavVoiceConfig.announceM]（默认 50m）时一次；
/// - 到位确认：越过转弯点前 8m 时「现在右转」一次；
/// - 连续转弯合并：两转弯沿路间距 ≤ 80m → 单条「前方 X 米右转，随后约 Y 米左转」；
/// - 直行步骤默认不打扰；仅当路名变化时播「沿 XX 路继续直行」（规范 2.3）；
/// - 每步唯一标识（步骤下标 + 类型），正常只播一次；GPS 抖动（里程回跳）
///   不会重复触发（集合去重 + 越界检测用上一里程）；
/// - 偏航：进入时打断播报「已偏离规划路线」，期间静默并把越过的步骤标记为
///   已播（回到路线不刷屏），回归时提示「已回到规划路线」；
/// - 暂停即停、继续时重新武装下一条、结束立即清空；
/// - 公里配速：排队不插队（转弯优先），过期（>15s）自动丢弃不积压。
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

  /// 到位确认触发线（米）：越过 cumulativeM - 8 即视为到达转弯点。
  static const double arrivalWindowM = 8;

  /// 公里配速排队过期时间：超过即丢弃（不允许过期语音积压）。
  static const Duration kmExpiry = Duration(seconds: 15);

  /// 转弯播报后的公里配速静默期（避免 cancel 回调竞态插播）。
  static const Duration turnGuard = Duration(seconds: 3);

  static const Map<String, String> _actionText = <String, String>{
    'left': '左转',
    'right': '右转',
    'uturn': '掉头',
  };

  List<RouteStep> _steps = const <RouteStep>[];
  final Set<String> _announced = <String>{};
  bool _offRoute = false;
  bool _paused = false;
  double? _prevAlong;
  String? _pendingKmText;
  DateTime? _pendingKmAt;
  DateTime? _lastTurnAt;
  String? _lastRoad;

  bool get offRoute => _offRoute;

  /// 绑定路线 steps（开始跑步时调用）。
  void attach(List<RouteStep> steps) {
    _steps = steps;
    _announced.clear();
    _offRoute = false;
    _paused = false;
    _prevAlong = null;
    _pendingKmText = null;
    _lastTurnAt = null;
    _lastRoad = null;
    _engine.onIdle = _onEngineIdle;
    if (!_config.voiceNav) return;
    final String firstRoad =
        steps.map((RouteStep s) => s.road).firstWhere((String r) => r.isNotEmpty, orElse: () => '');
    _speak(firstRoad.isEmpty ? '开始跑步' : '开始跑步，沿$firstRoad前进', flush: false);
  }

  /// 每次定位/匹配 tick 调用（约 1Hz）。
  void onPosition({required double alongM, required bool offRoute}) {
    final double prev = _prevAlong ?? alongM;
    _prevAlong = alongM;

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
      // 偏航期间静默，但把已越过的步骤标记为已播——回归后不刷屏。
      for (int i = 0; i < _steps.length; i++) {
        if (_steps[i].cumulativeM <= alongM) {
          _announced.add('pre-$i');
          _announced.add('now-$i');
        }
      }
      return;
    }

    // ---- 到位确认（越线检测，防 GPS 回跳重复触发） ----
    for (int i = 0; i < _steps.length; i++) {
      final RouteStep s = _steps[i];
      final String? act = _actionText[s.action];
      if (act == null) continue;
      final double trigger = s.cumulativeM - arrivalWindowM;
      if (prev < trigger && alongM >= trigger) {
        if (_announced.add('now-$i')) _speakTurn('现在$act');
      }
    }

    // ---- 终点提示 ----
    for (int i = 0; i < _steps.length; i++) {
      if (_steps[i].action != 'end') continue;
      final double d = _steps[i].cumulativeM - alongM;
      if (d <= 20 && d > -5 && _announced.add('end-$i')) {
        _speakTurn('已到达路线终点');
      }
    }

    // ---- 提前播报（窗口内第一条未播步骤；每 tick 至多一条转弯语音） ----
    for (int i = 0; i < _steps.length; i++) {
      final RouteStep s = _steps[i];
      final double remaining = s.cumulativeM - alongM;
      if (remaining <= arrivalWindowM) continue; // 已到位/已过
      if (remaining > _config.announceM) break; // steps 按里程升序，后面更远
      if (_announced.contains('pre-$i')) continue; // 已处理，查窗口内下一条

      final String? act = _actionText[s.action];
      if (act != null) {
        // 检查紧随其后的第二转弯 → 合并播报
        int? j;
        for (int k = i + 1; k < _steps.length; k++) {
          if (_actionText[_steps[k].action] == null) continue;
          if (_steps[k].cumulativeM - s.cumulativeM <= combineWindowM) j = k;
          break;
        }
        final String roadPart = s.road.isNotEmpty ? '进入${s.road}' : '';
        if (j != null) {
          final RouteStep s2 = _steps[j];
          final double d2 = s2.cumulativeM - s.cumulativeM;
          final String road2 = s2.road.isNotEmpty ? '进入${s2.road}' : '';
          _speakTurn('前方 ${_sayDist(remaining)}米$act$roadPart，'
              '随后约 ${_sayDist(d2)}米${_actionText[s2.action]}$road2');
          _announced.add('pre-$j');
        } else {
          _speakTurn('前方 ${_sayDist(remaining)}米$act$roadPart');
        }
        _announced.add('pre-$i');
        break; // 本 tick 已播一条转弯语音
      }

      if (s.action == 'straight') {
        // 直行只在路名变化时提示一次（规范 2.3：不反复打扰）。
        if (s.road.isNotEmpty && s.road != _lastRoad) {
          _speakTurn('沿${s.road}继续直行');
          _lastRoad = s.road;
        }
        _announced.add('pre-$i'); // 静默场景也标记，防每 tick 重查
        continue; // 窗口内若还有转弯，继续检查
      }
      _announced.add('pre-$i'); // end 等：不在提前窗口播报
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

  /// 暂停：立即停止一切播报（规范 2.4#5）。
  void onPause() {
    _paused = true;
    _pendingKmText = null;
    _engine.stop();
  }

  /// 继续：重新武装下一条转弯，恢复正确进度（规范 2.4#6）。
  void onResume({required double alongM}) {
    _paused = false;
    for (int i = 0; i < _steps.length; i++) {
      if (_steps[i].cumulativeM - alongM > arrivalWindowM) {
        _announced.remove('pre-$i'); // 暂停期间可能错过了窗口内播报
        break;
      }
    }
  }

  /// 结束跑步：立即停止并清空（规范 2.4#7）。
  void onEnd() {
    _pendingKmText = null;
    _engine.onIdle = null;
    _engine.stop();
  }

  // ---------- 内部 ----------

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
