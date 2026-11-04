import 'package:flutter/material.dart';

import '../models/km_split.dart';
import '../utils/geo.dart';

/// 每公里分段表格（阶段 L 模块 B，规范 3.3）。
///
/// 列：公里数 / 本公里用时 / 本公里配速。全部为真实结算值
/// （1000m 边界插值、排除暂停），绝不造假；末段不足 1 公里单独标注。
class KmSplitsTable extends StatelessWidget {
  const KmSplitsTable({super.key, required this.splits});

  final List<KmSplit> splits;

  @override
  Widget build(BuildContext context) {
    if (splits.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('本次跑步不足 30 米或为旧版本记录，无公里分段数据。',
            style: TextStyle(color: Colors.grey)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
          child: Row(
            children: <Widget>[
              Expanded(child: Text('公里数', style: _headStyle)),
              Expanded(child: Text('本公里用时', style: _headStyle)),
              Expanded(child: Text('本公里配速', style: _headStyle, textAlign: TextAlign.right)),
            ],
          ),
        ),
        for (int i = 0; i < splits.length; i++) ...<Widget>[
          if (i > 0) const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    splits[i].isPartial
                        ? '第 ${splits[i].index} 公里（${(splits[i].distanceM / 1000).toStringAsFixed(2)} km）'
                        : '第 ${splits[i].index} 公里',
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                Expanded(child: Text(formatDuration(splits[i].seconds.round()), style: const TextStyle(fontSize: 14))),
                Expanded(
                  child: Text(
                    formatPace(splits[i].paceSecondsPerKm),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static const TextStyle _headStyle = TextStyle(
    fontSize: 12,
    color: Colors.grey,
    fontWeight: FontWeight.w600,
  );
}
