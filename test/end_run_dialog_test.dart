import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:runloop/widgets/end_run_dialog.dart';

void main() {
  late Future<bool?> Function() result;
  Widget harness() {
    result = () async => null;
    return MaterialApp(
      home: Builder(
        builder: (BuildContext ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async {
                final bool r = await showEndRunConfirmDialog(ctx);
                result = () async => r;
              },
              child: const Text('结束'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('弹窗标题/正文/两个按钮符合任务书', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    expect(find.text('确认结束本次跑步？'), findsOneWidget);
    expect(find.text('结束后将停止本次运动记录，并保存本次运动数据。确定结束吗？'),
        findsOneWidget);
    expect(find.text('继续跑步'), findsOneWidget);
    expect(find.text('确认结束'), findsOneWidget);
  });

  testWidgets('继续跑步 → false，不结束', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('继续跑步'));
    await tester.pumpAndSettle();
    expect(find.text('确认结束本次跑步？'), findsNothing);
    expect(await result(), isFalse);
  });

  testWidgets('确认结束 → true', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认结束'));
    await tester.pumpAndSettle();
    expect(find.text('确认结束本次跑步？'), findsNothing);
    expect(await result(), isTrue);
  });

  testWidgets('点击弹窗外部 → false，不结束', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('结束'));
    await tester.pumpAndSettle();
    // 弹窗外的屏幕左上角
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.text('确认结束本次跑步？'), findsNothing);
    expect(await result(), isFalse);
  });
}
