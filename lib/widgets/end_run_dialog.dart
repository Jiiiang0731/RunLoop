import 'package:flutter/material.dart';

/// P0：结束跑步二次确认。
///
/// 返回 true 仅当用户明确点击「确认结束」。返回键、点击弹窗外部、
/// 「继续跑步」都返回 false——绝不结束运动、不提前停止 GPS/计时/语音。
Future<bool> showEndRunConfirmDialog(BuildContext context) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('确认结束本次跑步？'),
      content: const Text('结束后将停止本次运动记录，并保存本次运动数据。确定结束吗？'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('继续跑步'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('确认结束'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
