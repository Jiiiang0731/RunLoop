import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/nav_state.dart';

/// 偏航/重规划状态机单测（阶段 M-D，任务书 5.1/5.2/5.7）。
///
/// 核心断言：偏航确认绝不来自单点或固定 120m 布尔阈值——必须
/// 「精度自适应阈值 + 连续点数 + 持续时间」多因子一致才迁移；
/// 坏精度点不投票；重规划生命周期迁移全部显式且带锁。
void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 8, 0, 0);

  DateTime at(int secs) => t0.add(Duration(seconds: secs));

  group('偏航检测（5.2 多因子）', () {
    test('初始 onRoute；精度好的正常点不改变状态', () {
      final NavStateMachine m = NavStateMachine();
      expect(m.status, NavStatus.onRoute);
      m.update(offsetM: 5, accuracyM: 8, now: at(0));
      m.update(offsetM: 12, accuracyM: 10, now: at(1));
      expect(m.status, NavStatus.onRoute);
      expect(m.isOffRoute, isFalse);
    });

    test('单点大偏移只到 possibleDeviation，绝不直接 offRoute', () {
      final NavStateMachine m = NavStateMachine();
      m.update(offsetM: 200, accuracyM: 10, now: at(0));
      expect(m.status, NavStatus.possibleDeviation);
      expect(m.isOffRoute, isFalse, reason: '疑似态不算已确认偏航');
    });

    test('持续偏移但未满 8 秒：不确认（持续时间因子）', () {
      final NavStateMachine m = NavStateMachine();
      for (int s = 0; s <= 5; s++) {
        m.update(offsetM: 80, accuracyM: 10, now: at(s));
      }
      expect(m.status, NavStatus.possibleDeviation);
    });

    test('连续 3+ 点且持续 8 秒：确认 offRoute', () {
      final NavStateMachine m = NavStateMachine();
      for (int s = 0; s <= 9; s++) {
        m.update(offsetM: 80, accuracyM: 10, now: at(s));
      }
      expect(m.status, NavStatus.offRoute);
      expect(m.isOffRoute, isTrue);
    });

    test('中途回到阈值内：票数清零回 onRoute（GPS 抖动不误报）', () {
      final NavStateMachine m = NavStateMachine();
      m.update(offsetM: 80, accuracyM: 10, now: at(0));
      m.update(offsetM: 80, accuracyM: 10, now: at(1));
      expect(m.status, NavStatus.possibleDeviation);
      m.update(offsetM: 5, accuracyM: 10, now: at(2));
      expect(m.status, NavStatus.onRoute);
      // 重新偏移必须从头累计（点数 + 时长都要重新满足）
      m.update(offsetM: 80, accuracyM: 10, now: at(3));
      m.update(offsetM: 80, accuracyM: 10, now: at(10));
      expect(m.status, NavStatus.possibleDeviation,
          reason: '只有 2 票，不足 confirmPoints=3');
      m.update(offsetM: 80, accuracyM: 10, now: at(11));
      expect(m.status, NavStatus.offRoute);
    });

    test('坏精度点（>60m）不投票也不清票（5.7#1 跳点保护）', () {
      final NavStateMachine m = NavStateMachine();
      m.update(offsetM: 300, accuracyM: 120, now: at(0));
      m.update(offsetM: 300, accuracyM: 120, now: at(1));
      m.update(offsetM: 300, accuracyM: 120, now: at(2));
      m.update(offsetM: 300, accuracyM: 90, now: at(10));
      expect(m.status, NavStatus.onRoute, reason: '不可信点绝不触发偏航');
      // 已有票时坏点也不清票
      m.update(offsetM: 80, accuracyM: 10, now: at(20));
      expect(m.status, NavStatus.possibleDeviation);
      m.update(offsetM: 999, accuracyM: 200, now: at(21));
      expect(m.status, NavStatus.possibleDeviation);
    });

    test('阈值随精度自适应：精度差时放宽（防漂移误报）', () {
      final NavStateMachine m = NavStateMachine();
      // accuracy=25 → 阈值 50m；偏移 45m 不算偏离
      m.update(offsetM: 45, accuracyM: 25, now: at(0));
      expect(m.status, NavStatus.onRoute);
      // accuracy=10 → 阈值 25m（下限）；同样 30m 偏移即偏离
      m.update(offsetM: 30, accuracyM: 10, now: at(1));
      expect(m.status, NavStatus.possibleDeviation);
    });

    test('阈值封顶 60m：不再沿用旧的 120m 迟钝判定', () {
      const DeviationConfig cfg = DeviationConfig();
      expect(cfg.thresholdFor(100), 60);
      expect(cfg.thresholdFor(10), 25); // 10×2=20 → 夹到下限 25
      expect(cfg.thresholdFor(20), 40);
    });

    test('方向不匹配置信度：走反方向时偏移门槛降低', () {
      // 无方向证据：18m < 25m 阈值 → 不投票
      final NavStateMachine a = NavStateMachine();
      a.update(offsetM: 18, accuracyM: 10, headingDeg: 90, routeBearingDeg: 95, now: at(0));
      expect(a.status, NavStatus.onRoute);
      // 方向相反（夹角 180° > 60°）：18m > 25×0.6=15m → 投票
      final NavStateMachine b = NavStateMachine();
      b.update(offsetM: 18, accuracyM: 10, headingDeg: 90, routeBearingDeg: 270, now: at(0));
      expect(b.status, NavStatus.possibleDeviation);
    });
  });

  group('重规划生命周期（5.7#5/#6 锁与迁移）', () {
    NavStateMachine confirmed() {
      final NavStateMachine m = NavStateMachine();
      for (int s = 0; s <= 9; s++) {
        m.update(offsetM: 80, accuracyM: 10, now: at(s));
      }
      expect(m.status, NavStatus.offRoute);
      return m;
    }

    test('beginReroute 只允许 offRoute / rerouteFailed 进入 rerouting', () {
      expect(NavStateMachine().beginReroute(), isFalse);
      final NavStateMachine m = confirmed();
      expect(m.beginReroute(), isTrue);
      expect(m.status, NavStatus.rerouting);
      expect(m.beginReroute(), isFalse, reason: 'rerouting 中重复发起必须被拒');
    });

    test('成功链：rerouting → rerouted → onRoute（原子接入完成）', () {
      final NavStateMachine m = confirmed();
      m.beginReroute();
      expect(m.rerouteSucceeded(), isTrue);
      expect(m.status, NavStatus.rerouted);
      expect(m.acceptNewRoute(), isTrue);
      expect(m.status, NavStatus.onRoute);
      expect(m.isOffRoute, isFalse);
    });

    test('失败链：rerouting → rerouteFailed，可再次 beginReroute 重试', () {
      final NavStateMachine m = confirmed();
      m.beginReroute();
      expect(m.rerouteFailure(), isTrue);
      expect(m.status, NavStatus.rerouteFailed);
      expect(m.isOffRoute, isTrue);
      expect(m.beginReroute(), isTrue, reason: '失败后允许手动/自动重试');
      expect(m.status, NavStatus.rerouting);
    });

    test('非法迁移全部被拒（状态机带锁，绝不死锁或跳态）', () {
      final NavStateMachine m = NavStateMachine();
      expect(m.rerouteSucceeded(), isFalse);
      expect(m.rerouteFailure(), isFalse);
      expect(m.acceptNewRoute(), isFalse);
    });

    test('rerouting 中自然跑回 → onRoute（在飞结果应被调用方丢弃）', () {
      final NavStateMachine m = confirmed();
      m.beginReroute();
      final bool changed = m.update(offsetM: 4, accuracyM: 8, now: at(30));
      expect(changed, isTrue);
      expect(m.status, NavStatus.onRoute);
      // 回到 onRoute 后成功回调不能再改状态
      expect(m.rerouteSucceeded(), isFalse);
    });

    test('rerouteFailed 中自然跑回 → onRoute', () {
      final NavStateMachine m = confirmed();
      m.beginReroute();
      m.rerouteFailure();
      m.update(offsetM: 3, accuracyM: 8, now: at(40));
      expect(m.status, NavStatus.onRoute);
    });

    test('确认偏航后继续远离：状态保持，不重复触发确认', () {
      final NavStateMachine m = confirmed();
      bool changed = m.update(offsetM: 150, accuracyM: 10, now: at(20));
      expect(changed, isFalse);
      changed = m.update(offsetM: 220, accuracyM: 10, now: at(21));
      expect(changed, isFalse);
      expect(m.status, NavStatus.offRoute);
    });
  });

  group('配置可变（5.2：阈值/点数/时长可调）', () {
    test('copyWith 覆盖点数与时长后确认节奏随之变化', () {
      const DeviationConfig strict = DeviationConfig(
          confirmPoints: 2, confirmDuration: Duration(seconds: 2));
      final NavStateMachine m = NavStateMachine(config: strict);
      m.update(offsetM: 80, accuracyM: 10, now: at(0));
      m.update(offsetM: 80, accuracyM: 10, now: at(3));
      expect(m.status, NavStatus.offRoute);
    });
  });
}
