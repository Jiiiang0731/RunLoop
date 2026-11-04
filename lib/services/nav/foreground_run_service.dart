import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务任务入口（必须是顶级函数 + vm:entry-point，release 下保留）。
@pragma('vm:entry-point')
void runForegroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_RunTaskHandler());
}

/// 最小 TaskHandler：本 App 的后台工作（GPS/计时/语音）都在主 isolate 里，
/// 前台服务只负责「保活进程 + 常驻通知 + WakeLock」，不需要独立任务逻辑。
class _RunTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// 跑步前台服务（阶段 L 模块 8：Android 14+ 后台合规）。
///
/// - `foregroundServiceType="location"`（Manifest 已声明）+ 运行时
///   ACCESS_FINE_LOCATION 已授权 → 满足 Android 14 对 location 型 FGS 的
///   运行时要求；锁屏后 GPS、计时、语音播报随进程存活继续工作；
/// - WakeLock 开启：锁屏 CPU 不休眠（GPS 回调与 TTS 不被冻结）；
/// - 不开 WifiLock（户外 GPS 不依赖 Wi-Fi）；不开 autoRunOnBoot /
///   allowAutoRestart：进程被系统回收后不自动重启服务——避免产生重复记录
///   （规范 8 回归第 10 条）；恢复语义 = 用户重新进入 App 查看历史；
/// - 通知渠道 LOW 重要性：不响铃、不横幅打扰。
class ForegroundRunService {
  ForegroundRunService._();

  static bool _inited = false;
  static bool _running = false;

  /// 当前是否（本 App 认为）在运行。
  static bool get running => _running;

  static void _init() {
    if (_inited) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'runloop_run_service',
        channelName: '跑步记录服务',
        channelDescription: '跑步期间保持定位、计时与语音导航在后台运行',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: false,
        allowAutoRestart: false,
      ),
    );
    _inited = true;
  }

  /// 开始跑步（倒计时 GO 时刻，前台可见）时调用。返回是否成功。
  static Future<bool> start() async {
    try {
      _init();
      if (await FlutterForegroundTask.isRunningService) {
        _running = true;
        return true;
      }
      final ServiceRequestResult res = await FlutterForegroundTask.startService(
        serviceId: 9101,
        serviceTypes: <ForegroundServiceTypes>[ForegroundServiceTypes.location],
        notificationTitle: '环跑正在记录',
        notificationText: '定位、计时与语音导航运行中 · 点击返回应用',
        notificationInitialRoute: '/',
        callback: runForegroundTaskCallback,
      );
      _running = res is ServiceRequestSuccess;
      if (!_running) {
        debugPrint('FGS start failed: ${(res as ServiceRequestFailure).error}');
      }
      return _running;
    } catch (e) {
      debugPrint('FGS start error: $e');
      _running = false;
      return false;
    }
  }

  /// 结束跑步 / 页面销毁时调用：立即释放前台服务与通知。
  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (e) {
      debugPrint('FGS stop error: $e');
    }
    _running = false;
  }
}
