import 'package:amap_flutter_base/amap_flutter_base.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/services/nav/follow_camera.dart';

void main() {
  const LatLng a = LatLng(31.0, 121.0);
  const LatLng b = LatLng(31.00009, 121.0); // ≈10m 正北

  group('FollowCamera 位姿分离（阶段 L2 规范一/二）', () {
    test('首帧直接落位到目标（GO 后不做飞行动画，过渡动画由调用方单独下发）', () {
      final FollowCamera cam = FollowCamera();
      cam.setGoal(target: a, bearing: 90, zoom: 18.5);
      final FollowCameraStep? s = cam.tick(0.05);
      expect(s, isNotNull);
      expect(s!.position.latitude, a.latitude);
      expect(s.position.longitude, a.longitude);
      expect(s.bearing, 90);
      expect(s.zoom, 18.5);
    });

    test('死区：目标未变且已收敛 → tick 返回 null（不下发 moveCamera）', () {
      final FollowCamera cam = FollowCamera();
      cam.setGoal(target: a, bearing: 90, zoom: 18.5);
      cam.tick(0.05);
      for (int i = 0; i < 400; i++) {
        cam.tick(0.05); // 收敛
      }
      expect(cam.tick(0.05), isNull);
      expect(cam.tick(0.05), isNull);
    });

    test('位置平滑收敛：10m 外的目标，帧帧逼近且不越过', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 0, zoom: 18.5);
      cam.setGoal(target: b);
      double? prevDist = 10;
      for (int i = 0; i < 60; i++) {
        final FollowCameraStep? s = cam.tick(0.05);
        if (s == null) break;
        final double d = FollowCamera.haversine(s.position, b);
        expect(d <= prevDist! + 1e-9, isTrue, reason: '不得越过目标');
        prevDist = d;
      }
      expect(prevDist! < 0.2, isTrue, reason: '3s 内应收敛到 0.2m 内');
      expect(cam.position!.latitude, closeTo(b.latitude, 1e-7));
    });

    test('朝向最短弧：350° → 10° 走 +20°，绝不绕 340° 长弧', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 350, zoom: 18.5);
      cam.setGoal(target: a, bearing: 10);
      final FollowCameraStep? s1 = cam.tick(0.05);
      expect(s1, isNotNull);
      // 第一帧应从 350 向上（350→360/0 方向）小步移动
      final double d = s1!.bearing - 350;
      expect(d > 0 && d < 5, isTrue, reason: '实际 delta=$d');
      for (int i = 0; i < 400; i++) {
        cam.tick(0.05);
      }
      expect(cam.bearing, closeTo(10, 1e-9)); // 吸附到精确目标
    });

    test('用户左转场景（规范一.3）：北行(0°)→西行(270°)，bearing 走 -90° 短弧，'
        '即地图内容顺时针转 90°、西方来到屏幕上方', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 0, zoom: 18.5); // 向北跑
      cam.setGoal(target: a, bearing: 270); // 左转后向西跑
      final FollowCameraStep? s1 = cam.tick(0.05);
      // 短弧方向：bearing 应从 0 向 359/343…（即 -90 方向）走，而非 +270 长弧
      expect(s1!.bearing > 300 && s1.bearing < 360, isTrue,
          reason: '实际 bearing=${s1.bearing}，应走负向短弧');
      for (int i = 0; i < 600; i++) {
        cam.tick(0.05);
      }
      expect(cam.bearing, closeTo(270, 1e-9));
      expect(cam.bearing! >= 0 && cam.bearing! < 360, isTrue);
    });

    test('缩放平滑：17 → 18.5 逐帧过渡并最终吸附', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 0, zoom: 17.0);
      cam.setGoal(target: a, zoom: 18.5);
      final FollowCameraStep? s1 = cam.tick(0.05);
      expect(s1!.zoom > 17.0 && s1.zoom < 17.2, isTrue); // 慢时间常数：小步
      for (int i = 0; i < 600; i++) {
        cam.tick(0.05);
      }
      expect(cam.zoom, 18.5);
    });

    test('目标中途改变：立即转向新目标收敛', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 0, zoom: 18.5);
      cam.setGoal(target: b, bearing: 90);
      cam.tick(0.05);
      cam.setGoal(target: a, bearing: 180); // 掉头
      for (int i = 0; i < 600; i++) {
        cam.tick(0.05);
      }
      expect(FollowCamera.haversine(cam.position!, a) < 0.2, isTrue);
      expect(cam.bearing, closeTo(180, 1e-9));
    });

    test('bearing 始终归一化在 [0,360)', () {
      final FollowCamera cam = FollowCamera();
      cam.snap(target: a, bearing: 359.9, zoom: 18.5);
      for (final double g in <double>[0.4, 359.6, 180, 0]) {
        cam.setGoal(target: a, bearing: g);
        for (int i = 0; i < 600; i++) {
          cam.tick(0.05);
        }
        expect(cam.bearing! >= 0 && cam.bearing! < 360, isTrue);
        expect(cam.bearing, closeTo(g, 1e-9));
      }
    });

    test('setGoal 负角/越界角归一化；snap 只改传入分量', () {
      final FollowCamera cam = FollowCamera();
      cam.setGoal(target: a, bearing: -90, zoom: 19);
      cam.tick(0.05);
      expect(cam.bearing, closeTo(270, 1e-9));
      cam.snap(zoom: 18.0);
      expect(cam.zoom, 18.0);
      expect(cam.bearing, closeTo(270, 1e-9)); // 未传分量保持
      expect(cam.position, isNotNull);
    });
  });
}
