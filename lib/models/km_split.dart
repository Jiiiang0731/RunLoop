/// 单个公里分段（阶段 L 模块 B）。
///
/// 语义：
/// - [index] 从 1 开始；完整公里 distanceM=1000，跑动结束时的末段
///   不足 1 公里也单独记录（distanceM<1000）；
/// - [seconds] 为本分段**实际运动时长**（排除暂停，与 RunRecorder 的
///   durationSeconds 同一时钟），由 1000m 边界处的距离/时间线性插值得到；
/// - [paceSecondsPerKm] = seconds / (distanceM/1000)，展示与播报均用此值。
class KmSplit {
  final int index;
  final double distanceM;
  final double seconds;

  const KmSplit({
    required this.index,
    required this.distanceM,
    required this.seconds,
  });

  /// 本公里配速（秒/公里）；距离过短时返回 null（避免放大噪声）。
  double? get paceSecondsPerKm =>
      distanceM >= 50 ? seconds / (distanceM / 1000) : null;

  bool get isPartial => distanceM < 999.5;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'i': index,
        'd': distanceM,
        's': seconds,
      };

  factory KmSplit.fromJson(Map<String, dynamic> json) => KmSplit(
        index: (json['i'] as num?)?.toInt() ?? 0,
        distanceM: (json['d'] as num?)?.toDouble() ?? 0,
        seconds: (json['s'] as num?)?.toDouble() ?? 0,
      );

  /// 播报文案：「第 N 公里完成，本公里配速 X 分 Y 秒」。
  /// 中文 TTS 对阿拉伯数字按普通话读法朗读（6分32秒 → 六分三十二秒）。
  String announcement() {
    final double? pace = paceSecondsPerKm;
    if (pace == null) return '第$index公里完成';
    final int total = pace.round();
    final int m = total ~/ 60;
    final int s = total % 60;
    final String paceText = s == 0 ? '$m 分整' : '$m 分 $s 秒';
    return '第 $index 公里完成，本公里配速 $paceText';
  }
}
